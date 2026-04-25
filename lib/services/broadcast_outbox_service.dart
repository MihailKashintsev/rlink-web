import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'app_settings.dart';
import 'ble_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';
import 'wifi_direct_service.dart';

/// Персистентная очередь для broadcast-пакетов (channel_post, channel_comment,
/// group_message, реакции react_ext). При отсутствии сети — ретраим каждые
/// 15 секунд; при появлении пира/relay — сразу. Каждый получатель дедупает
/// по внутреннему id (postId/messageId/commentId).
///
/// Это вторая часть «гарантированной доставки» — первая (`OutboxService`)
/// делает это для личных сообщений.
class BroadcastOutboxService {
  BroadcastOutboxService._();
  static final BroadcastOutboxService instance = BroadcastOutboxService._();

  Database? _db;
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  final Set<String> _inflight = <String>{};
  final _uuid = const Uuid();

  VoidCallback? _relayListener;
  VoidCallback? _presenceListener;
  VoidCallback? _bleListener;
  VoidCallback? _wifiListener;

  /// Ретраим раз в 15 секунд.
  static const _tick = Duration(seconds: 15);

  /// Через сколько отказываемся: 72 часа. Этого хватает на «телефон разряжен,
  /// пользователь ушёл в поход на 3 дня» и тд — наш типичный сценарий BLE-мeshа.
  static const _maxAge = Duration(hours: 72);

  Future<void> init() async {
    if (_disposed) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'outbox_broadcast.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE outbox_broadcast (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_attempt_at INTEGER DEFAULT 0,
            attempts INTEGER DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_outbox_created ON outbox_broadcast(created_at)');
      },
    );

    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _pump());

    _relayListener = () => _pump();
    _presenceListener = () => _pump();
    _bleListener = () => _pump();
    _wifiListener = () => _pump();
    RelayService.instance.state.addListener(_relayListener!);
    RelayService.instance.presenceVersion.addListener(_presenceListener!);
    BleService.instance.peersCount.addListener(_bleListener!);
    WifiDirectService.instance.peersCount.addListener(_wifiListener!);

    unawaited(_pump());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_relayListener != null) {
      RelayService.instance.state.removeListener(_relayListener!);
    }
    if (_presenceListener != null) {
      RelayService.instance.presenceVersion.removeListener(_presenceListener!);
    }
    if (_bleListener != null) {
      BleService.instance.peersCount.removeListener(_bleListener!);
    }
    if (_wifiListener != null) {
      WifiDirectService.instance.peersCount.removeListener(_wifiListener!);
    }
  }

  // ── Enqueue helpers ───────────────────────────────────────────

  /// Ставит в очередь пост канала. Возвращает сразу (первая попытка
  /// делается внутри _pump).
  Future<void> enqueueChannelPost({
    required String channelId,
    required String postId,
    required String authorId,
    String? text,
    int? timestamp,
    String? reactionsJson,
    bool hasImage = false,
    bool hasVideo = false,
    bool hasVoice = false,
    bool hasFile = false,
    bool isSticker = false,
    String? fileName,
    String? pollJson,
    String? staffLabel,
  }) async {
    await _enqueue('channel_post', {
      'channelId': channelId,
      'postId': postId,
      'authorId': authorId,
      if (text != null) 'text': text,
      if (timestamp != null) 'timestamp': timestamp,
      if (reactionsJson != null) 'reactionsJson': reactionsJson,
      if (hasImage) 'hasImage': true,
      if (hasVideo) 'hasVideo': true,
      if (hasVoice) 'hasVoice': true,
      if (hasFile) 'hasFile': true,
      if (isSticker) 'isSticker': true,
      if (fileName != null) 'fileName': fileName,
      if (pollJson != null && pollJson.isNotEmpty) 'pollJson': pollJson,
      if (staffLabel != null && staffLabel.isNotEmpty) 'staffLabel': staffLabel,
    });
    unawaited(_pump());
  }

  Future<void> enqueueChannelComment({
    required String postId,
    required String commentId,
    required String authorId,
    required String text,
    int? timestamp,
    String? reactionsJson,
    bool hasImage = false,
    bool hasVideo = false,
    bool hasVoice = false,
    bool hasFile = false,
    String? fileName,
  }) async {
    await _enqueue('channel_comment', {
      'postId': postId,
      'commentId': commentId,
      'authorId': authorId,
      'text': text,
      if (timestamp != null) 'timestamp': timestamp,
      if (reactionsJson != null) 'reactionsJson': reactionsJson,
      if (hasImage) 'hasImage': true,
      if (hasVideo) 'hasVideo': true,
      if (hasVoice) 'hasVoice': true,
      if (hasFile) 'hasFile': true,
      if (fileName != null) 'fileName': fileName,
    });
    unawaited(_pump());
  }

  Future<void> enqueueGroupMessage({
    required String groupId,
    required String senderId,
    required String text,
    required String messageId,
    int? timestamp,
    double? latitude,
    double? longitude,
    String? reactionsJson,
    bool hasImage = false,
    bool hasVideo = false,
    bool hasFile = false,
    String? fileName,
    String? pollJson,
    String? forwardFromId,
    String? forwardFromNick,
  }) async {
    await _enqueue('group_message', {
      'groupId': groupId,
      'senderId': senderId,
      'text': text,
      'messageId': messageId,
      if (timestamp != null) 'timestamp': timestamp,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (reactionsJson != null) 'reactionsJson': reactionsJson,
      if (hasImage) 'hasImage': true,
      if (hasVideo) 'hasVideo': true,
      if (hasFile) 'hasFile': true,
      if (fileName != null) 'fileName': fileName,
      if (pollJson != null && pollJson.isNotEmpty) 'pollJson': pollJson,
      if (forwardFromId != null && forwardFromId.isNotEmpty)
        'ffid': forwardFromId,
      if (forwardFromNick != null && forwardFromNick.isNotEmpty)
        'ffn': forwardFromNick,
    });
    unawaited(_pump());
  }

  Future<void> enqueuePollVote({
    required String kind,
    required String targetId,
    required String voterId,
    required List<int> choiceIndices,
  }) async {
    await _enqueue('poll_vote', {
      'kind': kind,
      'targetId': targetId,
      'voterId': voterId,
      'choiceIndices': choiceIndices,
    });
    unawaited(_pump());
  }

  Future<void> enqueueReactionExt({
    required String kind,
    required String targetId,
    required String emoji,
    required String fromId,
  }) async {
    await _enqueue('react_ext', {
      'kind': kind,
      'targetId': targetId,
      'emoji': emoji,
      'from': fromId,
    });
    unawaited(_pump());
  }

  // ── Internals ─────────────────────────────────────────────────

  Future<void> _enqueue(String kind, Map<String, dynamic> payload) async {
    if (_db == null) return;
    final id = _uuid.v4();
    await _db!.insert('outbox_broadcast', {
      'id': id,
      'kind': kind,
      'payload_json': jsonEncode(payload),
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'last_attempt_at': 0,
      'attempts': 0,
    });
  }

  bool _hasTransport() {
    final hasRelay = RelayService.instance.isConnected;
    final mode = AppSettings.instance.connectionMode;
    final allowBle = mode != 1;
    final hasBlePeers = allowBle && BleService.instance.peersCount.value > 0;
    final hasWifiPeers = mode == 2 &&
        !kIsWeb &&
        Platform.isAndroid &&
        WifiDirectService.instance.peersCount.value > 0;
    return hasRelay || hasBlePeers || hasWifiPeers;
  }

  Future<void> _pump() async {
    if (_disposed || _running) return;
    if (_db == null) return;
    if (!_hasTransport()) return;
    _running = true;
    try {
      // Выбираем до 20 старейших записей.
      final rows = await _db!.query(
        'outbox_broadcast',
        orderBy: 'created_at ASC',
        limit: 20,
      );
      if (rows.isEmpty) return;

      final now = DateTime.now();
      for (final row in rows) {
        if (_disposed) return;
        final id = row['id'] as String;
        if (_inflight.contains(id)) continue;
        final createdAt = row['created_at'] as int;
        final age =
            now.difference(DateTime.fromMillisecondsSinceEpoch(createdAt));
        if (age > _maxAge) {
          await _db!
              .delete('outbox_broadcast', where: 'id = ?', whereArgs: [id]);
          continue;
        }
        _inflight.add(id);
        unawaited(_sendOne(row).whenComplete(() => _inflight.remove(id)));
      }
    } catch (e) {
      debugPrint('[RLINK][BOutbox] Pump error: $e');
    } finally {
      _running = false;
    }
  }

  Future<void> _sendOne(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final kind = row['kind'] as String;
    final raw = row['payload_json'] as String;
    final attempts = (row['attempts'] as int?) ?? 0;
    final lastAttempt = (row['last_attempt_at'] as int?) ?? 0;

    // Back-off: не чаще чем раз в (15s * 2^attempts) — до 10 минут.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final backoff = (15 * (1 << attempts.clamp(0, 6))) * 1000;
    final cappedBackoff = backoff > 600000 ? 600000 : backoff;
    if (lastAttempt > 0 && nowMs - lastAttempt < cappedBackoff) return;

    final payload = jsonDecode(raw) as Map<String, dynamic>;

    try {
      switch (kind) {
        case 'channel_post':
          await GossipRouter.instance.sendChannelPost(
            channelId: payload['channelId'] as String,
            postId: payload['postId'] as String,
            authorId: payload['authorId'] as String,
            text: payload['text'] as String?,
            timestamp: payload['timestamp'] as int?,
            reactionsJson: payload['reactionsJson'] as String?,
            hasImage: payload['hasImage'] as bool? ?? false,
            hasVideo: payload['hasVideo'] as bool? ?? false,
            hasVoice: payload['hasVoice'] as bool? ?? false,
            hasFile: payload['hasFile'] as bool? ?? false,
            isSticker: payload['isSticker'] as bool? ?? false,
            fileName: payload['fileName'] as String?,
            pollJson: payload['pollJson'] as String?,
            staffLabel: payload['staffLabel'] as String?,
          );
          break;
        case 'channel_comment':
          await GossipRouter.instance.sendChannelComment(
            postId: payload['postId'] as String,
            commentId: payload['commentId'] as String,
            authorId: payload['authorId'] as String,
            text: payload['text'] as String,
            timestamp: payload['timestamp'] as int?,
            reactionsJson: payload['reactionsJson'] as String?,
            hasImage: payload['hasImage'] as bool? ?? false,
            hasVideo: payload['hasVideo'] as bool? ?? false,
            hasVoice: payload['hasVoice'] as bool? ?? false,
            hasFile: payload['hasFile'] as bool? ?? false,
            fileName: payload['fileName'] as String?,
          );
          break;
        case 'group_message':
          await GossipRouter.instance.sendGroupMessage(
            groupId: payload['groupId'] as String,
            senderId: payload['senderId'] as String,
            text: payload['text'] as String,
            messageId: payload['messageId'] as String,
            timestamp: payload['timestamp'] as int?,
            latitude: (payload['latitude'] as num?)?.toDouble(),
            longitude: (payload['longitude'] as num?)?.toDouble(),
            reactionsJson: payload['reactionsJson'] as String?,
            hasImage: payload['hasImage'] as bool? ?? false,
            hasVideo: payload['hasVideo'] as bool? ?? false,
            hasFile: payload['hasFile'] as bool? ?? false,
            fileName: payload['fileName'] as String?,
            pollJson: payload['pollJson'] as String?,
            forwardFromId: payload['ffid'] as String?,
            forwardFromNick: payload['ffn'] as String?,
          );
          break;
        case 'poll_vote':
          final raw = payload['choiceIndices'] as List<dynamic>?;
          final choices = raw?.map((e) => (e as num).toInt()).toList() ?? [];
          await GossipRouter.instance.sendPollVote(
            kind: payload['kind'] as String,
            targetId: payload['targetId'] as String,
            voterId: payload['voterId'] as String,
            choiceIndices: choices,
          );
          break;
        case 'react_ext':
          await GossipRouter.instance.sendReactionExt(
            kind: payload['kind'] as String,
            targetId: payload['targetId'] as String,
            emoji: payload['emoji'] as String,
            fromId: payload['from'] as String,
          );
          break;
        default:
          await _db!
              .delete('outbox_broadcast', where: 'id = ?', whereArgs: [id]);
          return;
      }

      // Broadcast-пакеты не ACK-ятся напрямую. Считаем доставленным после
      // N успешных ретрансляций: 1-я попытка и ещё 2 подтверждения (~минута).
      final newAttempts = attempts + 1;
      if (newAttempts >= 3) {
        await _db!.delete('outbox_broadcast', where: 'id = ?', whereArgs: [id]);
      } else {
        await _db!.update(
          'outbox_broadcast',
          {
            'attempts': newAttempts,
            'last_attempt_at': nowMs,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    } catch (e) {
      debugPrint('[RLINK][BOutbox] Send $kind failed: $e');
      // Не удаляем — попробуем на следующем тике.
      await _db!.update(
        'outbox_broadcast',
        {'attempts': attempts + 1, 'last_attempt_at': nowMs},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }
}
