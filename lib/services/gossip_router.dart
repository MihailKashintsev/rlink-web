import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';

const _kDefaultTtl = 7;
const _kProfileTtl = 4; // Профили распространяются на 4 хопа для лучшего discovery
const _kSeenCacheTtl = Duration(minutes: 30);
const _kMaxPayloadBytes = 512;
const _kMaxImgPayloadBytes = 285; // img_meta ≈ 233 б, img_chunk ≈ 274 б < BLE MTU 290

class GossipPacket {
  final String id;
  final String type;
  final int ttl;
  final int timestamp;
  final String? recipientId;
  final Map<String, dynamic> payload;

  const GossipPacket({
    required this.id,
    required this.type,
    required this.ttl,
    required this.timestamp,
    required this.payload,
    this.recipientId,
  });

  factory GossipPacket.fromJson(Map<String, dynamic> j) => GossipPacket(
        id: j['id'] as String,
        type: j['t'] as String,
        ttl: j['ttl'] as int,
        timestamp: j['ts'] as int,
        recipientId: j['rid'] as String?,
        payload: j['p'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        't': type,
        'ttl': ttl,
        'ts': timestamp,
        if (recipientId != null) 'rid': recipientId,
        'p': payload,
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static GossipPacket? decode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return GossipPacket.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  GossipPacket decremented() => GossipPacket(
        id: id,
        type: type,
        ttl: ttl - 1,
        timestamp: timestamp,
        recipientId: recipientId,
        payload: payload,
      );

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch - timestamp > 3600 * 1000;
}

typedef OnMessageReceived = Future<void> Function(
  String fromId,
  EncryptedMessage msg,
  String messageId,
  String? replyToMessageId,
);
typedef OnAckReceived = void Function(String fromId, String messageId);
typedef OnForwardPacket = Future<void> Function(GossipPacket packet);
// bleId — BLE device ID источника (для маппинга), publicKey — Ed25519 ключ
typedef OnProfileReceived = void Function(
    String bleId, String publicKey, String nick, int color, String emoji);

typedef OnEditReceived = Future<void> Function(
  String fromId,
  String messageId,
  String newText,
);
typedef OnDeleteReceived = Future<void> Function(String fromId, String messageId);

/// Вызывается при получении img_meta (начало передачи изображения).
typedef OnImgMeta = void Function(
  String fromId,
  String msgId,
  int totalChunks,
  bool isAvatar, // true — аватар, false — чат-изображение
);

/// Вызывается при получении очередного img_chunk.
typedef OnImgChunk = void Function(
  String fromId,
  String msgId,
  int totalChunks,
  int index,
  String base64Data,
);

class GossipRouter {
  // Публичный ключ этого устройства — устанавливается при инициализации
  String? myPublicKey;
  GossipRouter._();
  static final GossipRouter instance = GossipRouter._();

  final _uuid = const Uuid();
  final Map<String, DateTime> _seenIds = {};
  Timer? _cleanupTimer;

  OnMessageReceived? onMessageReceived;
  OnAckReceived? onAckReceived;
  OnForwardPacket? onForwardPacket;
  OnProfileReceived? onProfileReceived;
  OnEditReceived? onEditReceived;
  OnDeleteReceived? onDeleteReceived;
  OnImgMeta? onImgMeta;
  OnImgChunk? onImgChunk;

  void init({
    String? myKey,
    required OnMessageReceived onMessage,
    OnAckReceived? onAck,
    required OnForwardPacket onForward,
    OnProfileReceived? onProfile,
    OnEditReceived? onEdit,
    OnDeleteReceived? onDelete,
    OnImgMeta? onImgMetaReceived,
    OnImgChunk? onImgChunkReceived,
  }) {
    myPublicKey = myKey;
    onMessageReceived = onMessage;
    onAckReceived = onAck;
    onForwardPacket = onForward;
    onProfileReceived = onProfile;
    onEditReceived = onEdit;
    onDeleteReceived = onDelete;
    onImgMeta = onImgMetaReceived;
    onImgChunk = onImgChunkReceived;
    _cleanupTimer =
        Timer.periodic(const Duration(minutes: 10), (_) => _cleanup());
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _seenIds.clear();
  }

  Future<GossipPacket> sendRawMessage({
    required String text,
    required String senderId,
    String? recipientId,
    String? messageId,
    String? replyToMessageId,
  }) async {
    final packet = GossipPacket(
      id: messageId ?? _uuid.v4(),
      type: 'raw',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {
        'text': text,
        'from': senderId,
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
    return packet;
  }

  Future<void> sendAck({
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(), // ACK packet id must be different (seen-cache dedup)
      type: 'ack',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {'messageId': messageId, 'from': senderId},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendEditMessage({
    required String messageId,
    required String newText,
    required String senderId,
    required String recipientId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(), // separate packet id for dedup
      type: 'edit',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {
        'messageId': messageId,
        'text': newText,
        'from': senderId,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendDeleteMessage({
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(), // separate packet id for dedup
      type: 'delete',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {'messageId': messageId, 'from': senderId},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  /// Отправляет метаданные изображения получателю (или broadcast для аватара).
  /// img_meta ≈ 233 байт (без rid): id36 + type + ttl + ts + msgId36 + chunks + from64 + avatar
  Future<void> sendImgMeta({
    required String msgId,
    required int totalChunks,
    required String fromId,
    String? recipientId, // не используется в пакете — не помещается в BLE MTU 290
    bool isAvatar = false,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'img_meta',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      // recipientId намеренно не передаётся — добавляет 70 байт и превышает MTU
      payload: {
        'msgId': msgId,
        'chunks': totalChunks,
        'from': fromId,
        'avatar': isAvatar,
      },
    );
    _markSeen(packet.id);
    await _forwardImg(packet);
  }

  /// img_chunk ≈ 154 + base64(90 байт) = 274 байт < BLE MTU 290 байт.
  /// rid и from исключены из пакета — получатель берёт fromId из img_meta.
  Future<void> sendImgChunk({
    required String msgId,
    required int index,
    required String base64Data,
    required String fromId, // используется только для img_meta; здесь для API симметрии
    String? recipientId,    // не используется — не помещается в MTU
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'img_chunk',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      // recipientId и from намеренно исключены — вместе добавляют ~142 байта
      payload: {
        'msgId': msgId,
        'idx': index,
        'data': base64Data,
      },
    );
    _markSeen(packet.id);
    await _forwardImg(packet);
  }

  Future<void> broadcastProfile({
    required String id,
    required String nick,
    required int color,
    required String emoji,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'profile',
      ttl: _kProfileTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {'id': id, 'nick': nick, 'color': color, 'emoji': emoji},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  // sourceId — BLE device ID пира, который прислал эти байты напрямую
  Future<void> onPacketReceived(Uint8List rawBytes, {String? sourceId}) async {
    final packet = GossipPacket.decode(rawBytes);
    if (packet == null) return;

    if (_hasSeen(packet.id)) return;
    _markSeen(packet.id);

    if (packet.isExpired) return;
    if (packet.ttl <= 0) return;

    await _handleIncoming(packet, sourceId: sourceId);

    if (packet.ttl > 1) {
      await _forward(packet.decremented());
    }
  }

  Future<void> _handleIncoming(GossipPacket packet, {String? sourceId}) async {
    try {
      // Point-to-point filtering for packets that include recipientId.
      final rid = packet.recipientId;
      if (rid != null &&
          rid.isNotEmpty &&
          myPublicKey != null &&
          rid != myPublicKey) {
        debugPrint('[Gossip] Message for $rid — not for us, skip');
        return;
      }

      if (packet.type == 'raw') {
        final text = packet.payload['text'] as String?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        final replyToMessageId =
            packet.payload['replyToMessageId'] as String?;

        debugPrint(
            '[Gossip] Raw message from=$from text=${text?.substring(0, text.length > 20 ? 20 : text.length)}');
        if (text != null) {
          final handler = onMessageReceived;
          if (handler != null) {
            await handler(
              from,
              EncryptedMessage(
                senderPublicKey: from,
                ephemeralPublicKey: '',
                nonce: '',
                cipherText: text,
                mac: '',
                signature: '',
              ),
              packet.id,
              replyToMessageId,
            );
          }
        }
        return;
      }

      if (packet.type == 'ack') {
        final ackMessageId = packet.payload['messageId'] as String?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        if (ackMessageId != null) {
          onAckReceived?.call(from, ackMessageId);
        }
        return;
      }

      if (packet.type == 'edit') {
        final messageId = packet.payload['messageId'] as String?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        final text = packet.payload['text'] as String?;
        if (messageId != null && text != null) {
          final handler = onEditReceived;
          if (handler != null) {
            await handler(from, messageId, text);
          }
        }
        return;
      }

      if (packet.type == 'delete') {
        final messageId = packet.payload['messageId'] as String?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        if (messageId != null) {
          final handler = onDeleteReceived;
          if (handler != null) {
            await handler(from, messageId);
          }
        }
        return;
      }

      if (packet.type == 'profile') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String?;
        final color = packet.payload['color'] as int?;
        final emoji = packet.payload['emoji'] as String? ?? '';

        if (publicKey != null && nick != null && color != null) {
          // sourceId — BLE ID пира, который прислал пакет напрямую
          // Используем его для маппинга BLE ID → publicKey
          final bleId = sourceId ?? publicKey;
          onProfileReceived?.call(bleId, publicKey, nick, color, emoji);
        }
        return;
      }

      if (packet.type == 'msg') {
        final encrypted = EncryptedMessage.fromJson(packet.payload);
        final handler = onMessageReceived;
        if (handler != null) {
          await handler(
            encrypted.senderPublicKey,
            encrypted,
            packet.id,
            null,
          );
        }
        return;
      }

      if (packet.type == 'img_meta') {
        final msgId      = packet.payload['msgId']   as String?;
        final totalChunks= packet.payload['chunks']  as int?;
        final from       = packet.payload['from']    as String? ?? 'unknown';
        final isAvatar   = (packet.payload['avatar'] as bool?) ?? false;
        if (msgId != null && totalChunks != null) {
          onImgMeta?.call(from, msgId, totalChunks, isAvatar);
        }
        return;
      }

      if (packet.type == 'img_chunk') {
        final msgId      = packet.payload['msgId'] as String?;
        final index      = packet.payload['idx']   as int?;
        final data       = packet.payload['data']  as String?;
        final from       = packet.payload['from']  as String? ?? 'unknown';
        // totalChunks не хранится в chunk-пакете — передаём 0 как sentinel;
        // ImageService уже знает totalChunks из img_meta.
        if (msgId != null && index != null && data != null) {
          onImgChunk?.call(from, msgId, 0, index, data);
        }
        return;
      }
    } catch (e) {
      debugPrint('[Gossip] Failed to parse payload: $e');
    }
  }

  Future<void> _forward(GossipPacket packet) async {
    if (onForwardPacket == null) return;
    final bytes = packet.encode();
    if (bytes.length > _kMaxPayloadBytes) {
      debugPrint('[Gossip] Packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      debugPrint('[Gossip] Forward failed: $e');
    }
  }

  /// Для img_meta/img_chunk используем увеличенный лимит.
  Future<void> _forwardImg(GossipPacket packet) async {
    if (onForwardPacket == null) return;
    final bytes = packet.encode();
    if (bytes.length > _kMaxImgPayloadBytes) {
      debugPrint('[Gossip] Img packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      debugPrint('[Gossip] Img forward failed: $e');
    }
  }

  bool _hasSeen(String id) => _seenIds.containsKey(id);
  void _markSeen(String id) => _seenIds[id] = DateTime.now();

  void _cleanup() {
    final cutoff = DateTime.now().subtract(_kSeenCacheTtl);
    _seenIds.removeWhere((_, time) => time.isBefore(cutoff));
  }
}
