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
      version: 1,
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
            fileName   TEXT,
            status     INTEGER NOT NULL DEFAULT 0,
            retryCount INTEGER NOT NULL DEFAULT 0,
            createdAt  INTEGER NOT NULL
          )
        ''');
      },
    );
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

    // Track if the relay reported the recipient as offline during this upload.
    bool recipientOffline = false;
    void onDeliveryFailed(String key) {
      if (key == task.recipientKey) recipientOffline = true;
    }
    RelayService.instance.onDeliveryFailed = onDeliveryFailed;

    try {
      final bytes = await File(task.filePath).readAsBytes();
      final compressed = ImageService.instance.compress(bytes);

      if (compressed.length <= _kMaxBlobBytes) {
        // ── Single blob send ──────────────────────────────────────
        await RelayService.instance.sendBlob(
          recipientKey: task.recipientKey,
          fromId: task.fromId,
          msgId: task.msgId,
          compressedData: compressed,
          isVoice: task.isVoice,
          isVideo: task.isVideo,
          isSquare: task.isSquare,
          isFile: task.isFile,
          fileName: task.fileName,
        );
        // Brief wait so a delivery_status:offline can arrive before we mark done
        await Future.delayed(const Duration(milliseconds: 200));
        if (recipientOffline) {
          throw Exception('Recipient offline — will retry when they reconnect');
        }
        _setProgress(task.msgId, 1.0);
      } else {
        // ── Chunked send for large files ──────────────────────────
        final total = (compressed.length / _kRelayChunkBytes).ceil();
        debugPrint('[UploadQueue] Large file: $total chunks for ${task.msgId}');
        for (var i = 0; i < total; i++) {
          if (!RelayService.instance.isConnected) {
            // Relay gone — requeue and stop
            await db.update(
              'upload_queue',
              {'status': UploadStatus.pending.index},
              where: 'id = ?',
              whereArgs: [task.id],
            );
            _setProgress(task.msgId, 0);
            return;
          }
          if (recipientOffline) {
            throw Exception('Recipient offline — will retry when they reconnect');
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
            fileName: task.fileName,
          );
          _setProgress(task.msgId, (i + 1) / total);
          await Future.delayed(const Duration(milliseconds: 20));
        }
        _setProgress(task.msgId, 1.0);
      }

      // ── Mark done ─────────────────────────────────────────────
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
      // Clear per-task delivery-fail listener
      if (RelayService.instance.onDeliveryFailed == onDeliveryFailed) {
        RelayService.instance.onDeliveryFailed = null;
      }
    }
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
