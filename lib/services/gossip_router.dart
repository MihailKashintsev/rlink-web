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
    700; // лимит для raw/ether/profile/ack: worst-case 90-char unicode ≈ 367 б, не-анонимный ether ≈ 400 б
const _kMaxImgPayloadBytes =
    500; // img_meta ≈ 233–350 б (с именем файла), img_chunk ≈ 274 б; BLE framing снимает ограничение MTU
const _kMaxEncPayloadBytes =
    700; // зашифрованные 'msg' пакеты: фикс. оверхед 294 б + base64(180 байт) = 534 б (90 символов unicode)

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
  String? replyToMessageId, {
  double? latitude,
  double? longitude,
});
typedef OnAckReceived = void Function(String fromId, String messageId);
typedef OnForwardPacket = Future<void> Function(GossipPacket packet);
// bleId — BLE device ID источника (для маппинга), publicKey — Ed25519 ключ,
// x25519Key — X25519 ключ base64 для E2E шифрования (пустая строка если нет)
typedef OnProfileReceived = void Function(
    String bleId, String publicKey, String nick, String username, int color,
    String emoji, String x25519Key, List<String> tags);

typedef OnEditReceived = Future<void> Function(
  String fromId,
  String messageId,
  String newText,
);
typedef OnDeleteReceived = Future<void> Function(
    String fromId, String messageId);
typedef OnReactReceived = Future<void> Function(
    String fromId, String messageId, String emoji);

/// Вызывается при получении сообщения в «Эфир».
/// [senderId] / [senderNick] — null если анонимно.
typedef OnEtherReceived = void Function(
    String id, String text, int color, String? senderId, String? senderNick);

/// Вызывается при получении сторис от пира.
typedef OnStoryReceived = void Function(
    String storyId, String authorId, String text, int bgColor,
    double textX, double textY, double textSize);

/// Вызывается при получении запроса историй от пира.
typedef OnStoryRequest = void Function(String fromId);

//// Pair request: device wants to exchange profiles.
typedef OnPairRequest = void Function(
    String bleId, String publicKey, String nick, String username, int color,
    String emoji, String x25519Key, List<String> tags);

/// Typing/activity indicator: 0=stopped, 1=typing, 2=recording video, 3=recording voice
typedef OnTypingReceived = void Function(String fromId, int activity);

//// Pair accepted: device accepted our pair request.
typedef OnPairAccepted = void Function(
    String bleId, String publicKey, String nick, String username, int color,
    String emoji, String x25519Key, List<String> tags);

/// Вызывается при получении img_meta (начало передачи изображения/голоса).
typedef OnImgMeta = void Function(
  String fromId,
  String msgId,
  int totalChunks,
  bool isAvatar,  // true — аватар
  bool isVoice,   // true — голосовое сообщение
  bool isVideo,   // true — видеосообщение
  bool isSquare,  // true — квадратное видео
  bool isFile,    // true — произвольный файл/документ
  String? fileName, // оригинальное имя файла (только для isFile)
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
  /// Maps msgId → rid8 prefix from img_meta for chunk filtering
  final Map<String, String> _imgMetaRid8 = {};
  /// Maps msgId → fromId from img_meta for chunk sender tracking
  final Map<String, String> _imgMetaFrom = {};

  OnMessageReceived? onMessageReceived;
  OnAckReceived? onAckReceived;
  OnForwardPacket? onForwardPacket;
  OnProfileReceived? onProfileReceived;
  OnEditReceived? onEditReceived;
  OnDeleteReceived? onDeleteReceived;
  OnReactReceived? onReactReceived;
  OnImgMeta? onImgMeta;
  OnImgChunk? onImgChunk;
  OnEtherReceived? onEtherReceived;
  OnStoryReceived? onStoryReceived;
  OnStoryRequest? onStoryRequest;
  void Function(String storyId, String authorId)? onStoryDelete;
  void Function(String storyId, String viewerId)? onStoryView;
  void Function(Map<String, dynamic> payload)? onAdminConfig;
  OnPairRequest? onPairRequest;
  OnPairAccepted? onPairAccepted;
  OnTypingReceived? onTypingReceived;

  // Channel/Group callbacks
  void Function(Map<String, dynamic> payload)? onChannelMeta;
  void Function(Map<String, dynamic> payload)? onChannelPost;
  void Function(Map<String, dynamic> payload)? onChannelDeletePost;
  void Function(Map<String, dynamic> payload)? onChannelSubscribe;
  void Function(Map<String, dynamic> payload)? onChannelInvite;
  void Function(Map<String, dynamic> payload)? onChannelComment;
  void Function(Map<String, dynamic> payload)? onChannelHistoryReq;
  void Function(Map<String, dynamic> payload)? onGroupMessage;
  void Function(Map<String, dynamic> payload)? onGroupInvite;
  void Function(Map<String, dynamic> payload)? onGroupAccept;

  // Universal reaction callback (story / channel_post / channel_comment / group_message)
  // Payload: { kind, targetId, emoji, from }
  void Function(Map<String, dynamic> payload)? onReactionExt;

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
    OnEtherReceived? onEther,
    OnStoryReceived? onStory,
    OnPairRequest? onPairReq,
    OnPairAccepted? onPairAcc,
    OnTypingReceived? onTyping,
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
    onEtherReceived = onEther;
    onStoryReceived = onStory;
    onPairRequest = onPairReq;
    onPairAccepted = onPairAcc;
    onTypingReceived = onTyping;
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
    double? latitude,
    double? longitude,
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
      if (latitude != null) 'lat': latitude,
      if (longitude != null) 'lng': longitude,
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
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
    return packet;
  }

  /// Отправляет зашифрованное сообщение тип 'msg' (ChaCha20-Poly1305 + X25519 ECDH).
  /// Размер пакета ~380-420 байт — укладывается в согласованный BLE MTU 512.
  Future<void> sendEncryptedMessage({
    required EncryptedMessage encrypted,
    required String senderId,
    required String recipientId,
    required String messageId,
    double? latitude,
    double? longitude,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;

    final payload = <String, dynamic>{
      ...encrypted.toJson(),
      if (rid8 != null) 'r': rid8,
      if (latitude != null) 'lat': latitude,
      if (longitude != null) 'lng': longitude,
    };

    final packet = GossipPacket(
      id: messageId,
      type: 'msg',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    _markSeen(packet.id);
    for (var i = 0; i < 3; i++) {
      await _forwardEncrypted(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<void> sendAck({
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(), // ACK packet id must be different (seen-cache dedup)
      type: 'ack',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {
        'messageId': messageId,
        'from': senderId,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> sendEditMessage({
    required String messageId,
    required String newText,
    required String senderId,
    required String recipientId,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(), // separate packet id for dedup
      type: 'edit',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'messageId': messageId,
        'text': newText,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> sendDeleteMessage({
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(), // separate packet id for dedup
      type: 'delete',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'messageId': messageId,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
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
    bool isFile = false,
    String? fileName,
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
        if (isFile) 'file': true,
        if (fileName != null) 'fname': fileName,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    // Retry img_meta 2 times for better avatar/image reliability.
    // Receivers dedup via _hasSeen so this is safe.
    for (var i = 0; i < 2; i++) {
      await _forwardImg(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  /// img_chunk ≈ 154 + base64(90 байт) = 274 байт < BLE MTU 290 байт.
  /// rid и from исключены из пакета — получатель берёт fromId из img_meta.
  Future<void> sendImgChunk({
    required String msgId,
    required int index,
    required String base64Data,
    required String fromId,
    String? recipientId,
  }) async {
    // Include 'r' for directed relay routing (adds ~14 bytes — acceptable).
    final rid8 = (recipientId?.length ?? 0) >= 8
        ? recipientId!.substring(0, 8)
        : null;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'img_chunk',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'msgId': msgId,
        'idx': index,
        'data': base64Data,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forwardImg(packet);
  }

  /// Отправляет сообщение в «Эфир» всем узлам сети.
  /// [senderId] / [senderNick] — null если анонимно.
  Future<void> sendEtherMessage({
    required String text,
    required int color,
    required String messageId,
    String? senderId,
    String? senderNick,
  }) async {
    final payload = <String, dynamic>{'text': text, 'col': color};
    if (senderId != null && senderNick != null) {
      payload['from'] = senderId;
      payload['nick'] = senderNick;
    }
    final packet = GossipPacket(
      id: messageId,
      type: 'ether',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    _markSeen(packet.id);
    // Ether is broadcast — retry 3 times for reliability over flaky BLE.
    // Receivers dedup via _hasSeen so this is safe.
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Отправляет сторис в mesh-сеть (broadcast, TTL=5).
  Future<void> sendStory({
    required String storyId,
    required String authorId,
    required String text,
    required int bgColor,
    double textX = 0,
    double textY = 0,
    double textSize = 26,
  }) async {
    final packet = GossipPacket(
      id: storyId,
      type: 'story',
      ttl: 5,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'from': authorId,
        'text': text,
        'col': bgColor,
        if (textX != 0) 'tx': textX,
        if (textY != 0) 'ty': textY,
        if (textSize != 26) 'ts': textSize,
      },
    );
    _markSeen(packet.id);
    // Story is broadcast — retry 3 times for reliability over flaky BLE.
    // Receivers dedup via _hasSeen so this is safe.
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<void> sendReaction({
    required String messageId,
    required String emoji,
    required String fromId,
    String recipientId = '',
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'react',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'messageId': messageId,
        'emoji': emoji,
        'from': fromId,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  /// Отправляет расширенную реакцию (toggle) для историй, постов каналов,
  /// комментариев каналов и сообщений групп.
  ///
  /// [kind] — 'story' | 'channel_post' | 'channel_comment' | 'group_message'
  /// [targetId] — id истории / постa / комментария / сообщения
  Future<void> sendReactionExt({
    required String kind,
    required String targetId,
    required String emoji,
    required String fromId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'react_ext',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'kind': kind,
        'targetId': targetId,
        'emoji': emoji,
        'from': fromId,
      },
    );
    _markSeen(packet.id);
    // Реакции — broadcast, ретраим 2 раза для надёжности в flaky BLE.
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Запрашивает у пиров их активные истории (broadcast, TTL=3).
  Future<void> sendStoryRequest({required String fromId}) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'story_req',
      ttl: 3,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {'from': fromId},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  /// Уведомляет пиров об удалении истории (broadcast, TTL=5, retry×3).
  Future<void> sendStoryDelete({
    required String storyId,
    required String authorId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'story_del',
      ttl: 5,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {'sid': storyId, 'from': authorId},
    );
    _markSeen(packet.id);
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Уведомляет автора истории о том, что [viewerId] посмотрел историю [storyId].
  /// Направленный пакет (TTL=3, r= первые 8 символов authorId).
  Future<void> sendStoryView({
    required String storyId,
    required String authorId,
    required String viewerId,
  }) async {
    final rid8 = authorId.length >= 8 ? authorId.substring(0, 8) : authorId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'story_view',
      ttl: 3,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {'sid': storyId, 'from': viewerId, 'r': rid8},
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  /// Синхронизирует хэш пароля админской панели между устройствами.
  Future<void> sendAdminConfig({
    required String adminPasswordHash,
    required String fromId,
    required String recipientId,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'admin_cfg',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'from': fromId,
        'hash': adminPasswordHash,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  /// Sends a pair request to a specific peer. TTL=1 (direct only).
  /// [recipientId] — the recipient's public key (used for directed routing).
  Future<void> sendPairRequest({
    required String publicKey,
    required String nick,
    String username = '',
    required int color,
    required String emoji,
    required String recipientId,
    String x25519Key = '',
    List<String> tags = const [],
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'pair_req',
      ttl: 1,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'id': publicKey,
        'nick': nick,
        if (username.isNotEmpty) 'u': username,
        'color': color,
        'emoji': emoji,
        'r': rid8,
        if (x25519Key.isNotEmpty) 'x': x25519Key,
        if (tags.isNotEmpty) 'tags': tags,
      },
    );
    _markSeen(packet.id);
    // Retry for reliability over BLE
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Accepts a pair request — sends profile with x25519 key.
  /// [recipientId] — the requester's public key (used for directed routing).
  Future<void> sendPairAccept({
    required String publicKey,
    required String nick,
    String username = '',
    required int color,
    required String emoji,
    required String x25519Key,
    required String recipientId,
    List<String> tags = const [],
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'pair_acc',
      ttl: 1,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'id': publicKey,
        'nick': nick,
        if (username.isNotEmpty) 'u': username,
        'color': color,
        'emoji': emoji,
        'r': rid8,
        if (x25519Key.isNotEmpty) 'x': x25519Key,
        if (tags.isNotEmpty) 'tags': tags,
      },
    );
    _markSeen(packet.id);
    // Retry for reliability
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Send typing/activity indicator. activity: 0=stopped, 1=typing, 2=recording video, 3=recording voice
  Future<void> sendTypingIndicator({
    required String fromId,
    required String recipientId,
    required int activity,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'typing',
      ttl: 2, // short range — no need to flood the mesh
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'from': fromId,
        'a': activity,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> broadcastProfile({
    required String id,
    required String nick,
    String username = '',
    required int color,
    required String emoji,
    String x25519Key = '', // X25519 публичный ключ base64 для E2E шифрования
    List<String> tags = const [],
  }) async {
    final payload = <String, dynamic>{
      'id': id,
      'nick': nick,
      if (username.isNotEmpty) 'u': username,
      'color': color,
      'emoji': emoji,
      if (x25519Key.isNotEmpty) 'x': x25519Key,
      if (tags.isNotEmpty) 'tags': tags,
    };
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'profile',
      ttl: _kProfileTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    _markSeen(packet.id);
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  // sourceId — BLE device ID пира, который прислал эти байты напрямую
  Future<void> onPacketReceived(Uint8List rawBytes, {String? sourceId}) async {
    final packet = GossipPacket.decode(rawBytes);
    if (packet == null) {
      debugPrint('[RLINK][Gossip] Failed to decode packet (${rawBytes.length} bytes)');
      return;
    }

    if (_hasSeen(packet.id)) return;
    _markSeen(packet.id);
    debugPrint('[RLINK][Gossip] Received type=${packet.type} ttl=${packet.ttl} id=${packet.id.substring(0, 8)}');

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
        debugPrint('[RLINK][Gossip] Message for $rid — not for us, skip');
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
          debugPrint('[RLINK][Gossip] Raw message not for us (rid prefix mismatch)');
          return;
        }

        debugPrint('[Gossip] Raw message from=$from len=${text?.length}');
        if (text != null) {
          final handler = onMessageReceived;
          if (handler != null) {
            final lat = (packet.payload['lat'] as num?)?.toDouble();
            final lng = (packet.payload['lng'] as num?)?.toDouble();
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
              latitude: lat,
              longitude: lng,
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
        final username = packet.payload['u'] as String? ?? '';
        final color = packet.payload['color'] as int?;
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';
        final tags = (packet.payload['tags'] as List<dynamic>?)
                ?.cast<String>() ??
            const <String>[];

        // Валидация: публичный ключ Ed25519 = 64 hex символа
        final isValidKey = publicKey != null &&
            publicKey.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey);

        if (isValidKey && nick != null && nick.isNotEmpty && color != null) {
          // sourceId — BLE ID пира, который прислал пакет напрямую.
          // onProfile в main.dart проверит isDirectBleId(bleId) перед регистрацией маппинга.
          final bleId = sourceId ?? publicKey;
          onProfileReceived?.call(bleId, publicKey, nick, username, color, emoji, x25519Key, tags);
        } else {
          debugPrint('[RLINK][Gossip] Invalid profile packet: key=$publicKey nick=$nick');
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
          debugPrint('[RLINK][Gossip] Dropping malformed msg packet (missing fields)');
          return;
        }
        final handler = onMessageReceived;
        if (handler != null) {
          final lat = (packet.payload['lat'] as num?)?.toDouble();
          final lng = (packet.payload['lng'] as num?)?.toDouble();
          await handler(
            encrypted.senderPublicKey,
            encrypted,
            packet.id,
            null,
            latitude: lat,
            longitude: lng,
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
        final isFile = (packet.payload['file'] as bool?) ?? false;
        final fileName = packet.payload['fname'] as String?;
        // Фильтрация по rid8: не-аватарные пакеты, адресованные другому получателю, игнорируем
        final rid8 = packet.payload['r'] as String?;
        if (!isAvatar && rid8 != null && myPublicKey != null &&
            !myPublicKey!.startsWith(rid8)) {
          debugPrint('[RLINK][Gossip] img_meta not for us (rid8 mismatch), skip');
          return;
        }
        if (msgId != null && totalChunks != null) {
          // Store rid8 and from for chunk filtering
          if (rid8 != null) _imgMetaRid8[msgId] = rid8;
          _imgMetaFrom[msgId] = from;
          onImgMeta?.call(from, msgId, totalChunks, isAvatar, isVoice, isVideo, isSquare, isFile, fileName);
        }
        return;
      }

      if (packet.type == 'ether') {
        final text = packet.payload['text'] as String?;
        final color = packet.payload['col'] as int?;
        debugPrint('[RLINK][Gossip] Ether packet: text=${text == null ? 'null' : text.substring(0, text.length.clamp(0, 20))} col=$color handler=${onEtherReceived != null}');
        if (text != null && text.isNotEmpty && color != null) {
          final senderId = packet.payload['from'] as String?;
          final senderNick = packet.payload['nick'] as String?;
          onEtherReceived?.call(packet.id, text, color, senderId, senderNick);
        }
        return;
      }

      if (packet.type == 'story_req') {
        final from = packet.payload['from'] as String?;
        if (from != null && from != myPublicKey) {
          onStoryRequest?.call(from);
        }
        return;
      }

      if (packet.type == 'admin_cfg') {
        final rid8 = packet.payload['r'] as String?;
        if (rid8 != null && myPublicKey != null && !myPublicKey!.startsWith(rid8)) return;
        onAdminConfig?.call(packet.payload);
        return;
      }

      if (packet.type == 'story') {
        final authorId = packet.payload['from'] as String?;
        final text = packet.payload['text'] as String?;
        final bgColor = packet.payload['col'] as int?;
        debugPrint('[RLINK][Gossip] Story packet: author=${authorId == null ? 'null' : authorId.substring(0, authorId.length.clamp(0, 16))} text=${text == null ? 'null' : text.substring(0, text.length.clamp(0, 20))} handler=${onStoryReceived != null}');
        if (authorId != null && text != null && bgColor != null) {
          final textX = (packet.payload['tx'] as num?)?.toDouble() ?? 0.0;
          final textY = (packet.payload['ty'] as num?)?.toDouble() ?? 0.0;
          final textSize = (packet.payload['ts'] as num?)?.toDouble() ?? 26.0;
          onStoryReceived?.call(packet.id, authorId, text, bgColor, textX, textY, textSize);
        }
        return;
      }

      if (packet.type == 'story_del') {
        final storyId = packet.payload['sid'] as String?;
        final authorId = packet.payload['from'] as String?;
        if (storyId != null && authorId != null) {
          onStoryDelete?.call(storyId, authorId);
        }
        return;
      }

      if (packet.type == 'story_view') {
        // Only forward to app when the packet is addressed to us.
        final rid8 = packet.payload['r'] as String?;
        if (rid8 != null && myPublicKey != null && !myPublicKey!.startsWith(rid8)) return;
        final storyId = packet.payload['sid'] as String?;
        final viewerId = packet.payload['from'] as String?;
        if (storyId != null && viewerId != null) {
          onStoryView?.call(storyId, viewerId);
        }
        return;
      }

      if (packet.type == 'pair_req') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String?;
        final username = packet.payload['u'] as String? ?? '';
        final color = packet.payload['color'] as int?;
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';
        final rid8 = packet.payload['r'] as String?;
        final tags = (packet.payload['tags'] as List<dynamic>?)
                ?.cast<String>() ??
            const <String>[];
        final bleId = sourceId ?? publicKey ?? '';
        // Drop pair_req not addressed to us (directed pairing)
        if (rid8 != null && myPublicKey != null &&
            !myPublicKey!.startsWith(rid8)) {
          debugPrint('[RLINK][Gossip] pair_req not for us (r=$rid8), dropping');
          return;
        }
        if (publicKey != null && nick != null && color != null) {
          debugPrint('[RLINK][Gossip] Pair request from $nick (${publicKey.substring(0, 8)})');
          onPairRequest?.call(bleId, publicKey, nick, username, color, emoji, x25519Key, tags);
        }
        return;
      }

      if (packet.type == 'pair_acc') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String?;
        final username = packet.payload['u'] as String? ?? '';
        final color = packet.payload['color'] as int?;
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';
        final rid8 = packet.payload['r'] as String?;
        final tags = (packet.payload['tags'] as List<dynamic>?)
                ?.cast<String>() ??
            const <String>[];
        final bleId = sourceId ?? publicKey ?? '';
        // Drop pair_acc not addressed to us (directed pairing)
        if (rid8 != null && myPublicKey != null &&
            !myPublicKey!.startsWith(rid8)) {
          debugPrint('[RLINK][Gossip] pair_acc not for us (r=$rid8), dropping');
          return;
        }
        if (publicKey != null && nick != null && color != null) {
          debugPrint('[RLINK][Gossip] Pair accepted by $nick (${publicKey.substring(0, 8)})');
          onPairAccepted?.call(bleId, publicKey, nick, username, color, emoji, x25519Key, tags);
        }
        return;
      }

      if (packet.type == 'typing') {
        final from = packet.payload['from'] as String?;
        final activity = packet.payload['a'] as int?;
        final rid8 = packet.payload['r'] as String?;
        if (from == null || activity == null) return;
        // Filter by recipient prefix
        if (rid8 != null && myPublicKey != null && !myPublicKey!.startsWith(rid8)) return;
        onTypingReceived?.call(from, activity);
        return;
      }

      if (packet.type == 'img_chunk') {
        final msgId = packet.payload['msgId'] as String?;
        final index = packet.payload['idx'] as int?;
        final data = packet.payload['data'] as String?;
        if (msgId == null || msgId.isEmpty || index == null || index < 0 ||
            data == null || data.isEmpty) { return; }
        // Filter chunks: if we received img_meta with rid8 for this msgId,
        // and it wasn't for us, skip the chunk too
        final storedRid8 = _imgMetaRid8[msgId];
        if (storedRid8 != null && myPublicKey != null &&
            !myPublicKey!.startsWith(storedRid8)) {
          return; // chunk not for us
        }
        // If we never got img_meta for this msgId, skip (prevents orphan chunks)
        final from = _imgMetaFrom[msgId];
        if (from == null) return;
        onImgChunk?.call(from, msgId, 0, index, data);
        return;
      }

      // ── Extended reactions (stories / channel posts / comments / group messages)
      if (packet.type == 'react_ext') {
        onReactionExt?.call(packet.payload);
        return;
      }

      // ── Channel packets ────────────────────────────────────────
      if (packet.type == 'channel_meta') {
        onChannelMeta?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_post') {
        onChannelPost?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_delete_post') {
        onChannelDeletePost?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_subscribe') {
        onChannelSubscribe?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_invite') {
        onChannelInvite?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_comment') {
        onChannelComment?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_history_req') {
        onChannelHistoryReq?.call(packet.payload);
        return;
      }

      // ── Group packets ──────────────────────────────────────────
      if (packet.type == 'group_message') {
        onGroupMessage?.call(packet.payload);
        return;
      }
      if (packet.type == 'group_invite') {
        onGroupInvite?.call(packet.payload);
        return;
      }
      if (packet.type == 'group_accept') {
        onGroupAccept?.call(packet.payload);
        return;
      }

      // ── Verification packets ───────────────────────────────────
      if (packet.type == 'verify_req') {
        onVerifyRequest?.call(packet.payload);
        return;
      }
      if (packet.type == 'verify_ok') {
        onVerifyApproval?.call(packet.payload);
        return;
      }

      // ── Admin action packets ───────────────────────────────────
      if (packet.type == 'channel_foreign_agent') {
        onChannelForeignAgent?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_block') {
        onChannelBlock?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_admin_delete') {
        onChannelAdminDelete?.call(packet.payload);
        return;
      }
    } catch (e) {
      debugPrint('[RLINK][Gossip] Failed to parse payload: $e');
    }
  }

  Future<void> _forward(GossipPacket packet) async {
    if (onForwardPacket == null) return;
    final bytes = packet.encode();
    if (bytes.length > _kMaxPayloadBytes) {
      debugPrint('[RLINK][Gossip] Packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      debugPrint('[RLINK][Gossip] Forward failed: $e');
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
      debugPrint('[RLINK][Gossip] Encrypted forward failed: $e');
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
      debugPrint('[RLINK][Gossip] Img forward failed: $e');
    }
  }

  bool _hasSeen(String id) => _seenIds.containsKey(id);
  void _markSeen(String id) => _seenIds[id] = DateTime.now();

  void _cleanup() {
    final cutoff = DateTime.now().subtract(_kSeenCacheTtl);
    _seenIds.removeWhere((_, time) => time.isBefore(cutoff));
    // Clean up img tracking maps (keep last 200 entries max)
    if (_imgMetaRid8.length > 200) {
      final keys = _imgMetaRid8.keys.toList();
      for (var i = 0; i < keys.length - 100; i++) {
        _imgMetaRid8.remove(keys[i]);
        _imgMetaFrom.remove(keys[i]);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Channel methods
  // ══════════════════════════════════════════════════════════════

  Future<void> broadcastChannelMeta({
    required String channelId,
    required String name,
    required String adminId,
    int? avatarColor,
    String? avatarEmoji,
    String? description,
    bool commentsEnabled = true,
    int? createdAt,
    bool verified = false,
    String? verifiedBy,
    List<String>? subscriberIds,
    List<String>? moderatorIds,
    String? username,
    String? universalCode,
    bool? isPublic,
  }) async {
    // Скрытые каналы не рассылаются широковещательно — только прямые invite.
    if (isPublic == false) return;
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_meta',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'name': name,
        'adminId': adminId,
        if (avatarColor != null) 'avatarColor': avatarColor,
        if (avatarEmoji != null) 'avatarEmoji': avatarEmoji,
        if (description != null) 'description': description,
        'commentsEnabled': commentsEnabled,
        if (createdAt != null) 'createdAt': createdAt,
        'verified': verified,
        if (verifiedBy != null) 'verifiedBy': verifiedBy,
        if (subscriberIds != null) 'subscriberIds': subscriberIds,
        if (moderatorIds != null) 'moderatorIds': moderatorIds,
        if (username != null && username.isNotEmpty) 'username': username,
        if (universalCode != null && universalCode.isNotEmpty) 'universalCode': universalCode,
        if (isPublic != null) 'isPublic': isPublic,
      },
    );
    await _forward(packet);
  }

  Future<void> sendChannelPost({
    required String channelId,
    required String postId,
    required String authorId,
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? fileUrl,
    String? fileName,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_post',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'postId': postId,
        'authorId': authorId,
        if (text != null) 'text': text,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (videoUrl != null) 'videoUrl': videoUrl,
        if (fileUrl != null) 'fileUrl': fileUrl,
        if (fileName != null) 'fileName': fileName,
      },
    );
    await _forward(packet);
  }

  Future<void> sendChannelDeletePost({
    required String postId,
    String? channelId,
    String? authorId,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_delete_post',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'postId': postId,
        if (channelId != null) 'channelId': channelId,
        if (authorId != null) 'authorId': authorId,
      },
    );
    await _forward(packet);
  }

  Future<void> broadcastChannelSubscribe({
    required String channelId,
    required String userId,
    bool unsubscribe = false,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_subscribe',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'userId': userId,
        'unsubscribe': unsubscribe,
      },
    );
    await _forward(packet);
  }

  Future<void> sendChannelInvite({
    required String channelId,
    required String channelName,
    required String adminId,
    required String inviterId,
    required String inviterNick,
    required String targetPublicKey,
    int? avatarColor,
    String? avatarEmoji,
    String? description,
    int? createdAt,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_invite',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: targetPublicKey,
      payload: {
        'channelId': channelId,
        'channelName': channelName,
        'adminId': adminId,
        'inviterId': inviterId,
        'inviterNick': inviterNick,
        if (avatarColor != null) 'avatarColor': avatarColor,
        if (avatarEmoji != null) 'avatarEmoji': avatarEmoji,
        if (description != null) 'description': description,
        if (createdAt != null) 'createdAt': createdAt,
      },
    );
    await _forward(packet);
  }

  Future<void> sendChannelComment({
    required String postId,
    required String commentId,
    required String authorId,
    required String text,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_comment',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'postId': postId,
        'commentId': commentId,
        'authorId': authorId,
        'text': text,
      },
    );
    await _forward(packet);
  }

  /// Запрос истории канала: отправляется новым подписчиком, админ (или другой
  /// подписчик) принимает и пересылает посты в ответ. Адресуется админу,
  /// но пакет — широковещательный, поэтому любой, у кого есть история, может
  /// ретранслировать посты.
  Future<void> sendChannelHistoryRequest({
    required String channelId,
    required String requesterId,
    required String adminId,
    int sinceTs = 0,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_history_req',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'requesterId': requesterId,
        'adminId': adminId,
        'sinceTs': sinceTs,
      },
    );
    await _forward(packet);
  }

  // ══════════════════════════════════════════════════════════════
  // Group methods
  // ══════════════════════════════════════════════════════════════

  Future<void> sendGroupMessage({
    required String groupId,
    required String senderId,
    required String text,
    required String messageId,
    String? imageUrl,
    String? videoUrl,
    String? fileUrl,
    String? fileName,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'group_message',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'groupId': groupId,
        'senderId': senderId,
        'text': text,
        'messageId': messageId,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (videoUrl != null) 'videoUrl': videoUrl,
        if (fileUrl != null) 'fileUrl': fileUrl,
        if (fileName != null) 'fileName': fileName,
      },
    );
    await _forward(packet);
  }

  Future<void> sendGroupInvite({
    required String groupId,
    required String groupName,
    required String inviterId,
    required String inviterNick,
    required String creatorId,
    required List<String> memberIds,
    required String targetPublicKey,
    int? avatarColor,
    String? avatarEmoji,
    int? createdAt,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'group_invite',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: targetPublicKey,
      payload: {
        'groupId': groupId,
        'groupName': groupName,
        'inviterId': inviterId,
        'inviterNick': inviterNick,
        'creatorId': creatorId,
        'memberIds': memberIds,
        if (avatarColor != null) 'avatarColor': avatarColor,
        if (avatarEmoji != null) 'avatarEmoji': avatarEmoji,
        if (createdAt != null) 'createdAt': createdAt,
      },
    );
    await _forward(packet);
  }

  Future<void> sendGroupAccept({
    required String groupId,
    required String accepterId,
    required String accepterNick,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'group_accept',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'groupId': groupId,
        'accepterId': accepterId,
        'accepterNick': accepterNick,
      },
    );
    await _forward(packet);
  }

  // ══════════════════════════════════════════════════════════════
  // Verification
  // ══════════════════════════════════════════════════════════════

  /// Channel admin requests verification (broadcast to all peers).
  Future<void> sendVerificationRequest({
    required String channelId,
    required String channelName,
    required String adminId,
    int subscriberCount = 0,
    String avatarEmoji = '📢',
    String? description,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'verify_req',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'channelName': channelName,
        'adminId': adminId,
        'subCount': subscriberCount,
        'emoji': avatarEmoji,
        if (description != null) 'desc': description,
      },
    );
    await _forward(packet);
  }

  /// Admin approves verification (broadcast to all peers).
  Future<void> sendVerificationApproval({
    required String channelId,
    required String verifiedBy,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'verify_ok',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'verifiedBy': verifiedBy,
      },
    );
    await _forward(packet);
  }

  // Callbacks for verification
  void Function(Map<String, dynamic> payload)? onVerifyRequest;
  void Function(Map<String, dynamic> payload)? onVerifyApproval;

  // ══════════════════════════════════════════════════════════════
  // Admin actions (foreign agent / block / delete)
  // ══════════════════════════════════════════════════════════════

  /// Admin marks a channel as ИНОАГЕНТ (or un-marks).
  Future<void> sendChannelForeignAgent({
    required String channelId,
    required bool value,
    required String byAdmin,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_foreign_agent',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'value': value,
        'by': byAdmin,
      },
    );
    await _forward(packet);
  }

  /// Admin blocks or unblocks a channel.
  Future<void> sendChannelBlock({
    required String channelId,
    required bool value,
    required String byAdmin,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_block',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'value': value,
        'by': byAdmin,
      },
    );
    await _forward(packet);
  }

  /// Admin deletes a channel network-wide.
  Future<void> sendChannelAdminDelete({
    required String channelId,
    required String byAdmin,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_admin_delete',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'by': byAdmin,
      },
    );
    await _forward(packet);
  }

  // Callbacks for admin actions
  void Function(Map<String, dynamic> payload)? onChannelForeignAgent;
  void Function(Map<String, dynamic> payload)? onChannelBlock;
  void Function(Map<String, dynamic> payload)? onChannelAdminDelete;
}
