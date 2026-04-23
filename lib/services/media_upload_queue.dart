import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'image_service.dart';
import 'relay_service.dart';

/// Status of an upload task.
enum UploadStatus { pending, uploading, done, failed }

/// A single media upload task.
class UploadTask {
  final String id;
  final String msgId;
  final String filePath;
  final String recipientKey;
  final String fromId;
  final bool isVoice;
  final bool isVideo;
  final bool isSquare;
  final bool isFile;
  final bool isSticker;
  final String? fileName;
  UploadStatus status;
  int retryCount;

  UploadTask({
    required this.id,
    required this.msgId,
    required this.filePath,
    required this.recipientKey,
    required this.fromId,
    this.isVoice = false,
    this.isVideo = false,
    this.isSquare = false,
    this.isFile = false,
    this.isSticker = false,
    this.fileName,
    this.status = UploadStatus.pending,
    this.retryCount = 0,
  });
}

/// SQLite-backed background media upload queue.
///
/// • Enqueue any media file for relay delivery.
/// • Queue is persisted across app restarts.
/// • Resumes automatically when relay reconnects.
/// • Progress tracked via [progressMap] ValueNotifier.
class MediaUploadQueue {
  MediaUploadQueue._();
  static final MediaUploadQueue instance = MediaUploadQueue._();

  Database? _db;
  bool _processing = false;

  /// Per-msgId upload progress (0.0 – 1.0). Key is removed when upload completes.
  final ValueNotifier<Map<String, double>> progressMap =
      ValueNotifier(<String, double>{});

  /// Called when a task completes successfully. Use to update message status in UI.
  void Function(String msgId)? onTaskCompleted;

  /// iOS Dynamic Island: прогресс при отправке «крупного» медиа (см. порог ниже).
  void Function(String label, double progress)? onLiveActivityMediaProgress;

  /// Порог размера **сжатых** данных для показа Live Activity (~250 KB).
  static const kLiveActivityMinCompressedBytes = 250 * 1024;

  /// Max blob size for single relay message (~800 KB compressed).
  static const _kMaxBlobBytes = 800 * 1024;

  /// Relay chunk size for large media.
  /// 200 KB per chunk — sent as relay `blob` type (single base64, ~267 KB on wire),
  /// safely under the relay server's 10 MB raw-message limit.
  /// A 13 MB file becomes ~66 chunks @ 20 ms = ~1.3 s.
  static const _kRelayChunkBytes = 200 * 1024;

  /// Max retry attempts before marking a task failed.
  static const _kMaxRetries = 5;

  Future<void> init() async {
    final dbDir = await getDatabasesPath();
    final dbPath = p.join(dbDir, 'rlink_upload_queue.db');
    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE upload_queue (
            id         TEXT    PRIMARY KEY,
            msgId      TEXT    NOT NULL,
            filePath   TEXT    NOT NULL,
            recipientKey TEXT  NOT NULL,
            fromId     TEXT    NOT NULL,
            isVoice    INTEGER NOT NULL DEFAULT 0,
            isVideo    INTEGER NOT NULL DEFAULT 0,
            isSquare   INTEGER NOT NULL DEFAULT 0,
            isFile     INTEGER NOT NULL DEFAULT 0,
            isSticker  INTEGER NOT NULL DEFAULT 0,
            fileName   TEXT,
            status     INTEGER NOT NULL DEFAULT 0,
            retryCount INTEGER NOT NULL DEFAULT 0,
            createdAt  INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(
              'ALTER TABLE upload_queue ADD COLUMN isSticker INTEGER NOT NULL DEFAULT 0',
            );
          } catch (e) {
            debugPrint('[UploadQueue] migrate isSticker: $e');
          }
        }
      },
    );
    // Сброс залипших задач от прошлой версии: всё, что висит uploading или
    // упёрлось в retry-лимит, сбрасываем в pending с retryCount=0, чтобы
    // фикс race-condition-а смог их доставить с чистого листа.
    try {
      final reset = await _db!.rawUpdate(
        'UPDATE upload_queue SET status = ?, retryCount = 0 '
        'WHERE status = ? OR (status = ? AND retryCount >= ?)',
        [
          UploadStatus.pending.index,
          UploadStatus.uploading.index,
          UploadStatus.failed.index,
          _kMaxRetries,
        ],
      );
      if (reset > 0) {
        debugPrint('[UploadQueue] Reset $reset stuck/failed tasks to pending');
      }
    } catch (e) {
      debugPrint('[UploadQueue] Reset stuck tasks failed: $e');
    }
    debugPrint('[UploadQueue] Initialized');
  }

  /// Add a media file to the upload queue.
  /// The file must already exist at [filePath] before calling this.
  Future<void> enqueue({
    required String msgId,
    required String filePath,
    required String recipientKey,
    required String fromId,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    bool isSticker = false,
    String? fileName,
  }) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'upload_queue',
      {
        'id': const Uuid().v4(),
        'msgId': msgId,
        'filePath': filePath,
        'recipientKey': recipientKey,
        'fromId': fromId,
        'isVoice': isVoice ? 1 : 0,
        'isVideo': isVideo ? 1 : 0,
        'isSquare': isSquare ? 1 : 0,
        'isFile': isFile ? 1 : 0,
        'isSticker': isSticker ? 1 : 0,
        'fileName': fileName,
        'status': UploadStatus.pending.index,
        'retryCount': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    debugPrint('[UploadQueue] Enqueued msgId=$msgId for ${recipientKey.substring(0, 8)}');
    // Start processing immediately if relay is ready
    unawaited(processQueue());
  }

  /// Process all pending tasks. Safe to call multiple times — debounced via [_processing].
  /// Loops until no more pending tasks so tasks enqueued during processing are also handled.
  Future<void> processQueue() async {
    if (_processing) return;
    if (!RelayService.instance.isConnected) return;
    _processing = true;
    try {
      final db = _db;
      if (db == null) return;

      // Loop until no pending tasks remain — handles tasks added while we were running.
      while (RelayService.instance.isConnected) {
        final rows = await db.query(
          'upload_queue',
          where: 'status IN (?, ?) AND retryCount < ?',
          whereArgs: [
            UploadStatus.pending.index,
            UploadStatus.failed.index,
            _kMaxRetries,
          ],
          orderBy: 'createdAt ASC',
        );
        if (rows.isEmpty) break;

        debugPrint('[UploadQueue] Processing ${rows.length} pending tasks');
        for (final row in rows) {
          if (!RelayService.instance.isConnected) break;
          await _processTask(_taskFromRow(row));
        }
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _processTask(UploadTask task) async {
    final db = _db;
    if (db == null) return;

    final label = _liveActivityLabel(task);
    var showIsland = false;

    // Skip if file no longer exists
    if (!File(task.filePath).existsSync()) {
      debugPrint('[UploadQueue] File missing for ${task.msgId}, marking failed');
      await db.update(
        'upload_queue',
        {'status': UploadStatus.failed.index},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      return;
    }

    // Mark uploading
    await db.update(
      'upload_queue',
      {'status': UploadStatus.uploading.index},
      where: 'id = ?',
      whereArgs: [task.id],
    );
    _setProgress(task.msgId, 0.01);

    // Per-task offline detector — устанавливаем ПОСЛЕ sendBlob, чтобы
    // не ловить «протухшие» delivery_status:offline события от предыдущих
    // задач или presence-пингов. Иначе блоб ложно помечается как failed
    // и retry-ится бесконечно.
    bool recipientOffline = false;
    void onDeliveryFailed(String key) {
      if (key == task.recipientKey) recipientOffline = true;
    }

    try {
      final bytes = await File(task.filePath).readAsBytes();
      final compressed = ImageService.instance.compress(bytes);
      showIsland = compressed.length >= kLiveActivityMinCompressedBytes;
      if (showIsland) {
        onLiveActivityMediaProgress?.call(label, 0.06);
      }

      if (compressed.length <= _kMaxBlobBytes) {
        // ── Single blob send ──────────────────────────────────────
        if (showIsland) {
          onLiveActivityMediaProgress?.call(label, 0.12);
        }
        await RelayService.instance.sendBlob(
          recipientKey: task.recipientKey,
          fromId: task.fromId,
          msgId: task.msgId,
          compressedData: compressed,
          isVoice: task.isVoice,
          isVideo: task.isVideo,
          isSquare: task.isSquare,
          isFile: task.isFile,
          isSticker: task.isSticker,
          fileName: task.fileName,
        );
        // Только теперь начинаем слушать offline-события для этого получателя.
        RelayService.instance.onDeliveryFailed = onDeliveryFailed;
        await Future.delayed(const Duration(milliseconds: 300));
        // Считаем доставкой по умолчанию — если получатель оффлайн, релей
        // выкинет блоб, но retry на нашей стороне ничего не даст: блоб не
        // буферизуется на сервере. Лучше пометить done и положиться на
        // прикладной ack от получателя (если он подцепится позже).
        if (showIsland) {
          onLiveActivityMediaProgress?.call(label, 0.9);
        }
        _setProgress(task.msgId, 1.0);
      } else {
        // ── Chunked send for large files ──────────────────────────
        final total = (compressed.length / _kRelayChunkBytes).ceil();
        debugPrint('[UploadQueue] Large file: $total chunks for ${task.msgId}');
        for (var i = 0; i < total; i++) {
          if (!RelayService.instance.isConnected) {
            // Relay gone — requeue and stop (resume on reconnect).
            await db.update(
              'upload_queue',
              {'status': UploadStatus.pending.index},
              where: 'id = ?',
              whereArgs: [task.id],
            );
            _setProgress(task.msgId, 0);
            return;
          }
          final offset = i * _kRelayChunkBytes;
          final end = (offset + _kRelayChunkBytes).clamp(0, compressed.length);
          final chunk = Uint8List.sublistView(compressed, offset, end);
          await RelayService.instance.sendBlobChunk(
            recipientKey: task.recipientKey,
            fromId: task.fromId,
            msgId: task.msgId,
            chunkIdx: i,
            chunkTotal: total,
            chunkData: chunk,
            isVoice: task.isVoice,
            isVideo: task.isVideo,
            isSquare: task.isSquare,
            isFile: task.isFile,
            isSticker: task.isSticker,
            fileName: task.fileName,
          );
          final frac = (i + 1) / total;
          _setProgress(task.msgId, frac);
          if (showIsland) {
            onLiveActivityMediaProgress?.call(label, frac);
          }
          await Future.delayed(const Duration(milliseconds: 20));
        }
        // Подключаем listener только после всех чанков.
        RelayService.instance.onDeliveryFailed = onDeliveryFailed;
        await Future.delayed(const Duration(milliseconds: 300));
        _setProgress(task.msgId, 1.0);
      }

      // ── Mark done ─────────────────────────────────────────────
      // Логируем, если релей всё-таки сообщил об оффлайн — для диагностики,
      // но задачу всё равно закрываем (см. комментарий выше).
      if (recipientOffline) {
        debugPrint('[UploadQueue] Note: ${task.recipientKey.substring(0, 8)} '
            'reported offline — blob may be lost, ack will confirm');
      }
      await db.update(
        'upload_queue',
        {'status': UploadStatus.done.index},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      debugPrint('[UploadQueue] Done: ${task.msgId}');
      onTaskCompleted?.call(task.msgId);
    } catch (e) {
      debugPrint('[UploadQueue] Task ${task.msgId} failed: $e');
      await db.update(
        'upload_queue',
        {
          'status': UploadStatus.pending.index,
          'retryCount': task.retryCount + 1,
        },
        where: 'id = ?',
        whereArgs: [task.id],
      );
      _setProgress(task.msgId, 0);
    } finally {
      if (showIsland) {
        onLiveActivityMediaProgress?.call(label, 1.0);
      }
      // Clear per-task delivery-fail listener
      if (RelayService.instance.onDeliveryFailed == onDeliveryFailed) {
        RelayService.instance.onDeliveryFailed = null;
      }
    }
  }

  String _liveActivityLabel(UploadTask t) {
    if (t.isVideo) return t.isSquare ? 'Видео' : 'Видео';
    if (t.isVoice) return 'Голосовое';
    if (t.isFile) {
      final n = t.fileName;
      if (n != null && n.isNotEmpty) {
        return n.length > 28 ? '${n.substring(0, 28)}…' : n;
      }
      return 'Файл';
    }
    return 'Фото';
  }

  void _setProgress(String msgId, double progress) {
    final map = Map<String, double>.from(progressMap.value);
    if (progress >= 1.0) {
      map.remove(msgId);
    } else {
      map[msgId] = progress;
    }
    progressMap.value = map;
  }

  UploadTask _taskFromRow(Map<String, dynamic> row) => UploadTask(
        id: row['id'] as String,
        msgId: row['msgId'] as String,
        filePath: row['filePath'] as String,
        recipientKey: row['recipientKey'] as String,
        fromId: row['fromId'] as String,
        isVoice: (row['isVoice'] as int) == 1,
        isVideo: (row['isVideo'] as int) == 1,
        isSquare: (row['isSquare'] as int) == 1,
        isFile: (row['isFile'] as int) == 1,
        isSticker: (row['isSticker'] as int?) == 1,
        fileName: row['fileName'] as String?,
        status: UploadStatus.values[row['status'] as int],
        retryCount: row['retryCount'] as int,
      );

  /// Current progress for a given msgId (0.0 – 1.0, or 0.0 if not uploading).
  double progressFor(String msgId) => progressMap.value[msgId] ?? 0;

  /// True while this msgId is being uploaded.
  bool isUploading(String msgId) => progressMap.value.containsKey(msgId);

  /// Remove completed tasks older than [maxAge].
  Future<void> cleanUp({Duration maxAge = const Duration(days: 7)}) async {
    final db = _db;
    if (db == null) return;
    final cutoff =
        DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final deleted = await db.delete(
      'upload_queue',
      where: 'status = ? AND createdAt < ?',
      whereArgs: [UploadStatus.done.index, cutoff],
    );
    if (deleted > 0) {
      debugPrint('[UploadQueue] Cleaned up $deleted completed tasks');
    }
  }

  /// Removes all queued tasks (used on full app reset).
  Future<void> clearAll() async {
    final db = _db;
    if (db == null) return;
    await db.delete('upload_queue');
    progressMap.value = {};
    debugPrint('[UploadQueue] Cleared all tasks');
  }

  /// All pending task count (for UI badges).
  Future<int> pendingCount() async {
    final db = _db;
    if (db == null) return 0;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM upload_queue WHERE status IN (?, ?)',
      [UploadStatus.pending.index, UploadStatus.uploading.index],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }
}
