import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';

const _kDefaultTtl = 7;
const _kProfileTtl =
    4; // Профили распространяются на 4 хопа для лучшего discovery
const _kSeenCacheTtl = Duration(minutes: 30);
const _kMaxPayloadBytes =
    288; // hard limit: iOS ATT MTU ≈ 290, leave 2 bytes margin
const _kMaxImgPayloadBytes =
    285; // img_meta ≈ 233 б, img_chunk ≈ 274 б < BLE MTU 290
const _kMaxEncPayloadBytes =
    490; // зашифрованные 'msg' пакеты ≈ 380-420 б < согласованный MTU 512

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

  factory GossipPacket.fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final type = j['t'];
    final ttl = j['ttl'];
    final ts = j['ts'];
    if (id is! String || id.isEmpty ||
        type is! String || type.isEmpty ||
        ttl is! int ||
        ts is! int) {
      throw FormatException('Invalid GossipPacket fields: id=$id t=$type ttl=$ttl ts=$ts');
    }
    return GossipPacket(
      id: id,
      type: type,
      ttl: ttl,
      timestamp: ts,
      recipientId: j['rid'] as String?,
      payload: (j['p'] as Map?)?.cast<String, dynamic>() ?? {},
    );
  }

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
// bleId — BLE device ID источника (для маппинга), publicKey — Ed25519 ключ,
// x25519Key — X25519 ключ base64 для E2E шифрования (пустая строка если нет)
typedef OnProfileReceived = void Function(
    String bleId, String publicKey, String nick, int color, String emoji,
    String x25519Key);

typedef OnEditReceived = Future<void> Function(
  String fromId,
  String messageId,
  String newText,
);
typedef OnDeleteReceived = Future<void> Function(
    String fromId, String messageId);
typedef OnReactReceived = Future<void> Function(
    String fromId, String messageId, String emoji);

/// Вызывается при получении img_meta (начало передачи изображения/голоса).
typedef OnImgMeta = void Function(
  String fromId,
  String msgId,
  int totalChunks,
  bool isAvatar, // true — аватар
  bool isVoice, // true — голосовое сообщение
  bool isVideo, // true — видеосообщение
  bool isSquare, // true — квадратное видео (аналог видеокружков)
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
  OnReactReceived? onReactReceived;
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
    OnReactReceived? onReact,
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
    onReactReceived = onReact;
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
    // Безопасность: включаем 8-символьный префикс публичного ключа получателя
    // как поле 'r' в payload. Это позволяет другим узлам отфильтровать пакеты,
    // предназначенные не им (экономим 56 байт по сравнению с полным rid в пакете).
    // Вероятность коллизии 8 hex = 4 байта = 1/2^32 ≈ незначительна.
    final rid8 = (recipientId?.length ?? 0) >= 8
        ? recipientId!.substring(0, 8)
        : null;

    final packetId = messageId ?? _uuid.v4();

    // Строим payload, условно включая контекст ответа если умещается в MTU.
    // Используем компактный ключ 'rt' вместо 'replyToMessageId' для экономии байт.
    final payload = <String, dynamic>{
      'text': text,
      'from': senderId,
      if (rid8 != null) 'r': rid8,
    };

    // Пробуем включить reply-контекст — пропускаем если пакет не уместится в MTU
    if (replyToMessageId != null) {
      final testPacket = GossipPacket(
        id: packetId,
        type: 'raw',
        ttl: _kDefaultTtl,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {...payload, 'rt': replyToMessageId},
      );
      if (testPacket.encode().length <= _kMaxPayloadBytes) {
        payload['rt'] = replyToMessageId;
      }
    }

    final packet = GossipPacket(
      id: packetId,
      type: 'raw',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    _markSeen(packet.id);
    await _forward(packet);
    return packet;
  }

  /// Отправляет зашифрованное сообщение тип 'msg' (ChaCha20-Poly1305 + X25519 ECDH).
  /// Размер пакета ~380-420 байт — укладывается в согласованный BLE MTU 512.
  Future<void> sendEncryptedMessage({
    required EncryptedMessage encrypted,
    required String senderId,
    required String recipientId,
    required String messageId,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;

    final payload = <String, dynamic>{
      ...encrypted.toJson(),
      if (rid8 != null) 'r': rid8,
    };

    final packet = GossipPacket(
      id: messageId,
      type: 'msg',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    _markSeen(packet.id);
    await _forwardEncrypted(packet);
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
    // rid and from omitted — saves ~146 bytes, keeping packet under BLE MTU.
    // onEdit callback ignores fromId anyway; mesh broadcast reaches the right peer.
    final packet = GossipPacket(
      id: _uuid.v4(), // separate packet id for dedup
      type: 'edit',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'messageId': messageId,
        'text': newText,
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
    // rid and from omitted — saves ~146 bytes, keeping packet under BLE MTU.
    // onDelete callback ignores fromId anyway.
    final packet = GossipPacket(
      id: _uuid.v4(), // separate packet id for dedup
      type: 'delete',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {'messageId': messageId},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  /// Отправляет метаданные изображения получателю (или broadcast для аватара).
  /// img_meta ≈ 247 байт (с rid8): добавляем 8-символьный префикс получателя
  /// для фильтрации на промежуточных узлах — только +14 байт, укладывается в MTU 285.
  Future<void> sendImgMeta({
    required String msgId,
    required int totalChunks,
    required String fromId,
    String? recipientId,
    bool isAvatar = false,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
  }) async {
    // rid8 для не-аватаров: фильтрует на промежуточных узлах, +14 байт ≤ MTU 285
    final rid8 = (!isAvatar && (recipientId?.length ?? 0) >= 8)
        ? recipientId!.substring(0, 8)
        : null;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'img_meta',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'msgId': msgId,
        'chunks': totalChunks,
        'from': fromId,
        'avatar': isAvatar,
        if (isVoice) 'voice': true,
        if (isVideo) 'video': true,
        if (isSquare) 'sq': true,
        if (rid8 != null) 'r': rid8,
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
    required String
        fromId, // используется только для img_meta; здесь для API симметрии
    String? recipientId, // не используется — не помещается в MTU
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

  Future<void> sendReaction({
    required String messageId,
    required String emoji,
    required String fromId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'react',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {'messageId': messageId, 'emoji': emoji, 'from': fromId},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> broadcastProfile({
    required String id,
    required String nick,
    required int color,
    required String emoji,
    String x25519Key = '', // X25519 публичный ключ base64 для E2E шифрования
  }) async {
    final payload = <String, dynamic>{
      'id': id,
      'nick': nick,
      'color': color,
      'emoji': emoji,
      if (x25519Key.isNotEmpty) 'x': x25519Key,
    };
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'profile',
      ttl: _kProfileTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
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
      // Зашифрованные 'msg' пакеты (~380-420 байт) пересылаем с увеличенным лимитом.
      // Обычные пакеты (сообщения, ack, profile) — стандартный 288-байтный лимит.
      if (packet.type == 'msg') {
        await _forwardEncrypted(packet.decremented());
      } else {
        await _forward(packet.decremented());
      }
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
        final rid8 = packet.payload['r'] as String?;
        // Поддерживаем оба формата: новый компактный 'rt' и старый 'replyToMessageId'
        final replyToMessageId =
            (packet.payload['rt'] ?? packet.payload['replyToMessageId'])
                as String?;

        // Фильтрация по префиксу получателя: если 'r' задан и не совпадает с нашим ключом
        // значит сообщение предназначено другому пользователю — пропускаем
        final myKey = myPublicKey;
        if (rid8 != null &&
            myKey != null &&
            !myKey.startsWith(rid8)) {
          debugPrint('[Gossip] Raw message not for us (rid prefix mismatch)');
          return;
        }

        debugPrint(
            '[Gossip] Raw message from=$from text=${text?.substring(0, text == null ? 0 : (text.length > 20 ? 20 : text.length))}');
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

      if (packet.type == 'react') {
        final messageId = packet.payload['messageId'] as String?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        final emoji = packet.payload['emoji'] as String?;
        if (messageId != null && emoji != null) {
          final handler = onReactReceived;
          if (handler != null) {
            await handler(from, messageId, emoji);
          }
        }
        return;
      }

      if (packet.type == 'profile') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String?;
        final color = packet.payload['color'] as int?;
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';

        // Валидация: публичный ключ Ed25519 = 64 hex символа
        final isValidKey = publicKey != null &&
            publicKey.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey);

        if (isValidKey && nick != null && nick.isNotEmpty && color != null) {
          // sourceId — BLE ID пира, который прислал пакет напрямую.
          // onProfile в main.dart проверит isDirectBleId(bleId) перед регистрацией маппинга.
          final bleId = sourceId ?? publicKey;
          onProfileReceived?.call(bleId, publicKey, nick, color, emoji, x25519Key);
        } else {
          debugPrint('[Gossip] Invalid profile packet: key=$publicKey nick=$nick');
        }
        return;
      }

      if (packet.type == 'msg') {
        // Фильтрация по 8-символьному префиксу получателя
        final rid8 = packet.payload['r'] as String?;
        final myKey = myPublicKey;
        if (rid8 != null && myKey != null && !myKey.startsWith(rid8)) {
          // Не нам — пакет будет переслан в onPacketReceived
          return;
        }
        final encrypted = EncryptedMessage.fromJson(packet.payload);
        // Drop malformed encrypted messages — prevents ciphertext leaking as plaintext
        if (encrypted.ephemeralPublicKey.isEmpty ||
            encrypted.nonce.isEmpty ||
            encrypted.cipherText.isEmpty ||
            encrypted.mac.isEmpty) {
          debugPrint('[Gossip] Dropping malformed msg packet (missing fields)');
          return;
        }
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
        final msgId = packet.payload['msgId'] as String?;
        final totalChunks = packet.payload['chunks'] as int?;
        final from = packet.payload['from'] as String? ?? 'unknown';
        final isAvatar = (packet.payload['avatar'] as bool?) ?? false;
        final isVoice = (packet.payload['voice'] as bool?) ?? false;
        final isVideo = (packet.payload['video'] as bool?) ?? false;
        final isSquare = (packet.payload['sq'] as bool?) ?? false;
        // Фильтрация по rid8: не-аватарные пакеты, адресованные другому получателю, игнорируем
        final rid8 = packet.payload['r'] as String?;
        if (!isAvatar && rid8 != null && myPublicKey != null &&
            !myPublicKey!.startsWith(rid8)) {
          debugPrint('[Gossip] img_meta not for us (rid8 mismatch), skip');
          return;
        }
        if (msgId != null && totalChunks != null) {
          onImgMeta?.call(from, msgId, totalChunks, isAvatar, isVoice, isVideo, isSquare);
        }
        return;
      }

      if (packet.type == 'img_chunk') {
        final msgId = packet.payload['msgId'] as String?;
        final index = packet.payload['idx'] as int?;
        final data = packet.payload['data'] as String?;
        // 'from' отсутствует в chunk-пакетах (только в img_meta для экономии MTU).
        // ImageService получит fromId из img_meta через initAssembly.
        // totalChunks = 0 как sentinel — ImageService уже знает totalChunks из img_meta.
        if (msgId != null && msgId.isNotEmpty && index != null && index >= 0 &&
            data != null && data.isNotEmpty) {
          onImgChunk?.call('', msgId, 0, index, data);
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

  /// Для зашифрованных 'msg' пакетов используем увеличенный лимит (MTU 512).
  Future<void> _forwardEncrypted(GossipPacket packet) async {
    if (onForwardPacket == null) return;
    final bytes = packet.encode();
    if (bytes.length > _kMaxEncPayloadBytes) {
      debugPrint(
          '[Gossip] Encrypted packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      debugPrint('[Gossip] Encrypted forward failed: $e');
    }
  }

  /// Для img_meta/img_chunk используем увеличенный лимит.
  Future<void> _forwardImg(GossipPacket packet) async {
    if (onForwardPacket == null) return;
    final bytes = packet.encode();
    if (bytes.length > _kMaxImgPayloadBytes) {
      debugPrint(
          '[Gossip] Img packet too large (${bytes.length} bytes), dropping');
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
