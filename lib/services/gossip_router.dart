import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';

const _kDefaultTtl = 7;
const _kSeenCacheTtl = Duration(minutes: 30);
const _kMaxPayloadBytes = 512;

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

typedef OnMessageReceived = void Function(String fromId, EncryptedMessage msg);
typedef OnForwardPacket = Future<void> Function(GossipPacket packet);
// bleId — BLE device ID источника (для маппинга), publicKey — Ed25519 ключ
typedef OnProfileReceived = void Function(
    String bleId, String publicKey, String nick, int color, String emoji);

class GossipRouter {
  GossipRouter._();
  static final GossipRouter instance = GossipRouter._();

  final _uuid = const Uuid();
  final Map<String, DateTime> _seenIds = {};
  Timer? _cleanupTimer;

  OnMessageReceived? onMessageReceived;
  OnForwardPacket? onForwardPacket;
  OnProfileReceived? onProfileReceived;

  void init({
    required OnMessageReceived onMessage,
    required OnForwardPacket onForward,
    OnProfileReceived? onProfile,
  }) {
    onMessageReceived = onMessage;
    onForwardPacket = onForward;
    onProfileReceived = onProfile;
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
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'raw',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {'text': text, 'from': senderId},
    );
    _markSeen(packet.id);
    await _forward(packet);
    return packet;
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
      ttl: 2,
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
      if (packet.type == 'raw') {
        final text = packet.payload['text'] as String?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        debugPrint(
            '[Gossip] Raw message from=$from text=${text?.substring(0, text.length > 20 ? 20 : text.length)}');
        if (text != null) {
          onMessageReceived?.call(
              from,
              EncryptedMessage(
                senderPublicKey: from,
                ephemeralPublicKey: '',
                nonce: '',
                cipherText: text,
                mac: '',
                signature: '',
              ));
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
        onMessageReceived?.call(encrypted.senderPublicKey, encrypted);
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

  bool _hasSeen(String id) => _seenIds.containsKey(id);
  void _markSeen(String id) => _seenIds[id] = DateTime.now();

  void _cleanup() {
    final cutoff = DateTime.now().subtract(_kSeenCacheTtl);
    _seenIds.removeWhere((_, time) => time.isBefore(cutoff));
  }
}
