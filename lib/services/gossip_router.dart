import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';

const _kDefaultTtl = 7;          // максимум прыжков
const _kSeenCacheTtl = Duration(minutes: 30); // храним seen IDs
const _kMaxPayloadBytes = 512;    // ограничение BLE MTU

/// Gossip-пакет — минимальная единица, летящая по BLE
class GossipPacket {
  final String id;           // UUID v4 — уникальный ID пакета
  final String type;         // 'msg' | 'ack' | 'ping'
  final int ttl;             // уменьшается на каждом прыжке
  final int timestamp;       // Unix ms — для фильтрации старых пакетов
  final String? recipientId; // публичный ключ получателя (null = broadcast)
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
        id:          j['id']          as String,
        type:        j['t']           as String,
        ttl:         j['ttl']         as int,
        timestamp:   j['ts']          as int,
        recipientId: j['rid']         as String?,
        payload:     j['p']           as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => {
        'id':  id,
        't':   type,
        'ttl': ttl,
        'ts':  timestamp,
        if (recipientId != null) 'rid': recipientId,
        'p':   payload,
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

  /// Возвращает новый пакет с TTL - 1
  GossipPacket decremented() => GossipPacket(
        id: id, type: type, ttl: ttl - 1,
        timestamp: timestamp, recipientId: recipientId, payload: payload,
      );

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch - timestamp > 3600 * 1000;
}

/// Тип для callback'а — что делать когда пришло сообщение ДЛЯ НАС
typedef OnMessageReceived = void Function(String fromId, EncryptedMessage msg);

/// Тип для callback'а — что передать соседям (BLE layer вызывает нас)
typedef OnForwardPacket = Future<void> Function(GossipPacket packet);

class GossipRouter {
  GossipRouter._();
  static final GossipRouter instance = GossipRouter._();

  final _uuid = const Uuid();

  // seen ID → время получения (для очистки)
  final Map<String, DateTime> _seenIds = {};

  // Периодическая очистка кеша
  Timer? _cleanupTimer;

  OnMessageReceived? onMessageReceived;
  OnForwardPacket?   onForwardPacket;

  void init({
    required OnMessageReceived onMessage,
    required OnForwardPacket   onForward,
  }) {
    onMessageReceived = onMessage;
    onForwardPacket   = onForward;

    _cleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) => _cleanup());
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _seenIds.clear();
  }

  // ─── Отправка сообщения ───────────────────────────────────

  /// Создаём и инжектируем пакет в сеть (broadcast + forward)
  Future<GossipPacket> sendMessage({
    required EncryptedMessage encrypted,
    required String recipientId,
  }) async {
    final packet = GossipPacket(
      id:          _uuid.v4(),
      type:        'msg',
      ttl:         _kDefaultTtl,
      timestamp:   DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload:     encrypted.toJson(),
    );

    // Помечаем как увиденный, чтобы не пересылать самим себе
    _markSeen(packet.id);

    // Форвардим соседям
    await _forward(packet);
    return packet;
  }

  // ─── Получение пакета от соседа ──────────────────────────

  /// Вызывается BLE-слоем когда пришли байты от соседнего устройства
  Future<void> onPacketReceived(Uint8List rawBytes) async {
    final packet = GossipPacket.decode(rawBytes);
    if (packet == null) return;

    // Дедупликация
    if (_hasSeen(packet.id)) return;
    _markSeen(packet.id);

    // Фильтр старых пакетов
    if (packet.isExpired) return;

    // TTL исчерпан — дропаем
    if (packet.ttl <= 0) return;

    // Проверяем — это нам?
    final myId = CryptoService.instance.publicKeyHex;
    if (packet.recipientId == myId || packet.recipientId == null) {
      await _handleIncoming(packet);
    }

    // Forward дальше (с декрементом TTL) если не broadcast уже мёртв
    if (packet.ttl > 1) {
      await _forward(packet.decremented());
    }
  }

  // ─── Приватные методы ─────────────────────────────────────

  Future<void> _handleIncoming(GossipPacket packet) async {
    if (packet.type != 'msg') return;

    try {
      final encrypted = EncryptedMessage.fromJson(packet.payload);
      onMessageReceived?.call(encrypted.senderPublicKey, encrypted);
    } catch (e) {
      debugPrint('[Gossip] Failed to parse message payload: $e');
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
    debugPrint('[Gossip] Cache cleanup: ${_seenIds.length} IDs retained');
  }
}
