import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';
import 'diagnostics_log_service.dart';

const _kDefaultTtl = 7;
const _kProfileTtl =
    4; // Профили распространяются на 4 хопа для лучшего discovery
const _kSeenCacheTtl = Duration(minutes: 30);
const _kMaxPayloadBytes =
    700; // лимит для raw/ether/profile/ack: worst-case 90-char unicode ≈ 367 б, не-анонимный ether ≈ 400 б
const _kMaxImgPayloadBytes =
    500; // img_meta ≈ 233–350 б (с именем файла), img_chunk ≈ 274 б; BLE framing снимает ограничение MTU
const _kMaxEncPayloadBytes =
    780; // 'msg': шифртекст + опционально rt/ffid/ffn (пересылка, ответ)

/// JSON numbers on dart2js are often [double]; gossip must still decode.
int? _jsonIntLoose(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

String? _rid8From(String? publicKey) {
  if (publicKey == null || publicKey.isEmpty) return null;
  final key = publicKey.trim().toLowerCase();
  if (key.isEmpty) return null;
  return key.length >= 8 ? key.substring(0, 8) : key;
}

bool _matchesRid8(String? myPublicKey, String? rid8) {
  if (rid8 == null || rid8.isEmpty) return true;
  if (myPublicKey == null || myPublicKey.isEmpty) return false;
  return myPublicKey.toLowerCase().startsWith(rid8.toLowerCase());
}

void _gossipTrace(String line) {
  debugPrint(line);
  DiagnosticsLogService.instance.add(line);
}

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
    final ttl = _jsonIntLoose(j['ttl']);
    final ts = _jsonIntLoose(j['ts']);
    if (id is! String ||
        id.isEmpty ||
        type is! String ||
        type.isEmpty ||
        ttl == null ||
        ts == null) {
      throw FormatException(
          'Invalid GossipPacket fields: id=$id t=$type ttl=${j['ttl']} ts=${j['ts']}');
    }
    final rawP = j['p'];
    final Map<String, dynamic> payload =
        rawP is Map ? Map<String, dynamic>.from(rawP) : <String, dynamic>{};
    return GossipPacket(
      id: id,
      type: type,
      ttl: ttl,
      timestamp: ts,
      recipientId: j['rid'] as String?,
      payload: payload,
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
  String? forwardFromId,
  String? forwardFromNick,
  String? forwardFromChannelId,
});
typedef OnAckReceived = void Function(String fromId, String messageId);
typedef OnForwardPacket = Future<void> Function(GossipPacket packet);
// bleId — BLE device ID источника (для маппинга), publicKey — Ed25519 ключ,
// x25519Key — X25519 ключ base64 для E2E шифрования (пустая строка если нет)
typedef OnProfileReceived = void Function(
  String bleId,
  String publicKey,
  String nick,
  String username,
  int color,
  String emoji,
  String x25519Key,
  List<String> tags,
  String? statusEmojiPayload,
);

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
  String id,
  String text,
  int color,
  String? senderId,
  String? senderNick, {
  double? lat,
  double? lng,
});

/// Вызывается при получении сторис от пира.
typedef OnStoryReceived = void Function(String storyId, String authorId,
    String text, int bgColor, double textX, double textY, double textSize);

/// Вызывается при получении запроса историй от пира.
typedef OnStoryRequest = void Function(String fromId);

//// Pair request: device wants to exchange profiles.
typedef OnPairRequest = void Function(
    String bleId,
    String publicKey,
    String nick,
    String username,
    int color,
    String emoji,
    String x25519Key,
    List<String> tags);

/// Typing/activity indicator: 0=stopped, 1=typing, 2=recording video, 3=recording voice
typedef OnTypingReceived = void Function(String fromId, int activity);

//// Pair accepted: device accepted our pair request.
typedef OnPairAccepted = void Function(
    String bleId,
    String publicKey,
    String nick,
    String username,
    int color,
    String emoji,
    String x25519Key,
    List<String> tags);

typedef OnDeviceLinkRequest = void Function(
  String sourceId,
  String publicKey,
  String nick,
  String username,
);

typedef OnDeviceLinkAck = void Function(
  String sourceId,
  String publicKey,
  String nick,
  bool accepted,
);

typedef OnDeviceUnlink = void Function(
  String sourceId,
  String publicKey,
);

typedef OnDeviceDmSyncRequest = void Function(
  String sourceId,
  String publicKey,
);

typedef OnDeviceDmSyncPacket = Future<void> Function(
  String sourceId,
  String publicKey,
  String kind,
  Map<String, dynamic> data,
  bool snapshot,
);

/// Вызывается при получении img_meta (начало передачи изображения/голоса).
typedef OnImgMeta = void Function(
  String fromId,
  String msgId,
  int totalChunks,
  bool isAvatar, // true — аватар
  bool isVoice, // true — голосовое сообщение
  bool isVideo, // true — видеосообщение
  bool isSquare, // true — квадратное видео
  bool isFile, // true — произвольный файл/документ
  bool isSticker, // true — стикер (сохраняется как stk_*.jpg, компактный UI)
  String? fileName, // оригинальное имя файла (только для isFile)
  bool viewOnce, {
  String? forwardFromId,
  String? forwardFromNick,
  String? forwardFromChannelId,
});

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

  /// Chunks that arrived before [img_meta] (BLE mesh reordering).
  final Map<String, Map<int, String>> _pendingImgChunks = {};

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

  /// Зашифрованный admin_cfg2: только устройства с тем же Ed25519, что и [from].
  /// [channelIds] — список каналов для синхронизации подписок между устройствами.
  void Function(String hash, int revision, List<String> channelIds)?
      onAdminConfigSecure;
  OnPairRequest? onPairRequest;
  OnPairAccepted? onPairAccepted;
  OnDeviceLinkRequest? onDeviceLinkRequest;
  OnDeviceLinkAck? onDeviceLinkAck;
  OnDeviceUnlink? onDeviceUnlink;
  OnDeviceDmSyncRequest? onDeviceDmSyncRequest;
  OnDeviceDmSyncPacket? onDeviceDmSyncPacket;
  OnTypingReceived? onTypingReceived;

  // Channel/Group callbacks
  void Function(Map<String, dynamic> payload)? onChannelMeta;
  void Function(Map<String, dynamic> payload)? onChannelPost;
  void Function(String postId, String viewerId)? onChannelPostView;
  void Function(Map<String, dynamic> payload)? onChannelDeletePost;
  void Function(Map<String, dynamic> payload)? onChannelSubscribe;
  void Function(Map<String, dynamic> payload)? onChannelInvite;
  void Function(Map<String, dynamic> payload)? onChannelComment;
  void Function(Map<String, dynamic> payload)? onChannelCommentDelete;
  void Function(Map<String, dynamic> payload)? onChannelHistoryReq;
  Future<void> Function(GossipPacket packet)? onChannelBackupKey;
  Future<void> Function(GossipPacket packet)? onChannelBackupMeta;
  Future<void> Function(GossipPacket packet)? onChannelBackupChunk;
  void Function(Map<String, dynamic> payload)? onGroupMessage;
  void Function(Map<String, dynamic> payload)? onGroupInvite;
  void Function(Map<String, dynamic> payload)? onGroupAccept;
  void Function(Map<String, dynamic> payload)? onGroupHistoryReq;

  /// Закрепление в личном чате: { mid, a, from, r? }
  Future<void> Function(Map<String, dynamic> payload)? onDmPin;

  /// poll_vote: { k: kind, t: targetId, v: voterId, c: [int] }
  void Function(Map<String, dynamic> payload)? onPollVote;

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
    bool startCleanupTimer = true,
  }) {
    _cleanupTimer?.cancel();
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
    if (startCleanupTimer) {
      _cleanupTimer =
          Timer.periodic(const Duration(minutes: 10), (_) => _cleanup());
    }
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
    String? forwardFromId,
    String? forwardFromNick,
    String? forwardFromChannelId,
  }) async {
    // Безопасность: включаем 8-символьный префикс публичного ключа получателя
    // как поле 'r' в payload. Это позволяет другим узлам отфильтровать пакеты,
    // предназначенные не им (экономим 56 байт по сравнению с полным rid в пакете).
    // Вероятность коллизии 8 hex = 4 байта = 1/2^32 ≈ незначительна.
    final rid8 = _rid8From(recipientId);

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

    String? ffnShort(String? n) {
      if (n == null || n.isEmpty) return null;
      return n.length > 36 ? n.substring(0, 36) : n;
    }

    // Пробуем включить reply / пересылку — убираем по частям если пакет велик.
    var rt = replyToMessageId;
    var ffid = (forwardFromId != null &&
            forwardFromId.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(forwardFromId))
        ? forwardFromId
        : null;
    var ffn = ffnShort(forwardFromNick);
    var ffch = forwardFromChannelId?.trim();
    if (ffch != null && (ffch.isEmpty || ffch.length > 48)) ffch = null;
    while (true) {
      final p = Map<String, dynamic>.from(payload);
      if (rt != null) p['rt'] = rt;
      if (ffid != null) p['ffid'] = ffid;
      if (ffn != null) p['ffn'] = ffn;
      if (ffch != null) p['ffch'] = ffch;
      final testPacket = GossipPacket(
        id: packetId,
        type: 'raw',
        ttl: _kDefaultTtl,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: p,
      );
      if (testPacket.encode().length <= _kMaxPayloadBytes) {
        if (rt != null) payload['rt'] = rt;
        if (ffid != null) payload['ffid'] = ffid;
        if (ffn != null) payload['ffn'] = ffn;
        if (ffch != null) payload['ffch'] = ffch;
        break;
      }
      if (ffn != null) {
        ffn = null;
        continue;
      }
      if (ffch != null) {
        ffch = null;
        continue;
      }
      if (ffid != null) {
        ffid = null;
        continue;
      }
      if (rt != null) {
        rt = null;
        continue;
      }
      break;
    }

    final packet = GossipPacket(
      id: packetId,
      type: 'raw',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: payload,
    );
    _gossipTrace('[RLINK][Gossip][TX] type=raw id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
        'to=${_rid8From(recipientId) ?? '-'} from=${senderId.substring(0, senderId.length.clamp(0, 8))}');
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
    String? replyToMessageId,
    String? forwardFromId,
    String? forwardFromNick,
    String? forwardFromChannelId,
  }) async {
    final rid8 = _rid8From(recipientId);

    final payload = <String, dynamic>{
      ...encrypted.toJson(),
      if (rid8 != null) 'r': rid8,
      if (latitude != null) 'lat': latitude,
      if (longitude != null) 'lng': longitude,
    };

    String? ffnShort(String? n) {
      if (n == null || n.isEmpty) return null;
      return n.length > 36 ? n.substring(0, 36) : n;
    }

    var rt = replyToMessageId;
    var ffid = (forwardFromId != null &&
            forwardFromId.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(forwardFromId))
        ? forwardFromId
        : null;
    var ffn = ffnShort(forwardFromNick);
    var ffch = forwardFromChannelId?.trim();
    if (ffch != null && (ffch.isEmpty || ffch.length > 48)) ffch = null;
    while (true) {
      final p = Map<String, dynamic>.from(payload);
      if (rt != null) p['rt'] = rt;
      if (ffid != null) p['ffid'] = ffid;
      if (ffn != null) p['ffn'] = ffn;
      if (ffch != null) p['ffch'] = ffch;
      final testPacket = GossipPacket(
        id: messageId,
        type: 'msg',
        ttl: _kDefaultTtl,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: p,
      );
      if (testPacket.encode().length <= _kMaxEncPayloadBytes) {
        if (rt != null) payload['rt'] = rt;
        if (ffid != null) payload['ffid'] = ffid;
        if (ffn != null) payload['ffn'] = ffn;
        if (ffch != null) payload['ffch'] = ffch;
        break;
      }
      if (ffn != null) {
        ffn = null;
        continue;
      }
      if (ffch != null) {
        ffch = null;
        continue;
      }
      if (ffid != null) {
        ffid = null;
        continue;
      }
      if (rt != null) {
        rt = null;
        continue;
      }
      break;
    }

    final packet = GossipPacket(
      id: messageId,
      type: 'msg',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: payload,
    );
    _gossipTrace('[RLINK][Gossip][TX] type=msg id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
        'to=${_rid8From(recipientId) ?? '-'} from=${senderId.substring(0, senderId.length.clamp(0, 8))}');
    _markSeen(packet.id);
    for (var i = 0; i < 3; i++) {
      await _forwardEncrypted(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Синхронизация закрепления в личном чате (видят оба участника).
  Future<void> sendDmPin({
    required String recipientId,
    required String messageId,
    required bool add,
    required String fromId,
  }) async {
    final rid8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : null;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'dm_pin',
      ttl: 5,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
      payload: {
        'mid': messageId,
        'a': add,
        'from': fromId,
        if (rid8 != null) 'r': rid8,
      },
    );
    _markSeen(packet.id);
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
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
      recipientId: recipientId,
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
      recipientId: recipientId,
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
    bool isSticker = false,
    String? fileName,
    bool viewOnce = false,
    String? forwardFromId,
    String? forwardFromNick,
    String? forwardFromChannelId,
  }) async {
    // rid8 для не-аватаров: фильтрует на промежуточных узлах, +14 байт ≤ MTU 285
    final rid8 = (!isAvatar && (recipientId?.length ?? 0) >= 8)
        ? recipientId!.substring(0, 8)
        : null;

    String? ffnShort(String? n) {
      if (n == null || n.isEmpty) return null;
      return n.length > 36 ? n.substring(0, 36) : n;
    }

    var ffid = (forwardFromId != null &&
            forwardFromId.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(forwardFromId))
        ? forwardFromId
        : null;
    var ffn = ffnShort(forwardFromNick);
    var ffch = forwardFromChannelId?.trim();
    if (ffch != null && (ffch.isEmpty || ffch.length > 48)) ffch = null;
    var fnameForPayload = fileName;

    Map<String, dynamic> buildPayload() {
      final m = <String, dynamic>{
        'msgId': msgId,
        'chunks': totalChunks,
        'from': fromId,
        'avatar': isAvatar,
        if (isVoice) 'voice': true,
        if (isVideo) 'video': true,
        if (isSquare) 'sq': true,
        if (isFile) 'file': true,
        if (isSticker) 'stk': true,
        if (fnameForPayload != null) 'fname': fnameForPayload,
        if (viewOnce) 'vo': true,
        if (rid8 != null) 'r': rid8,
      };
      if (ffid != null) m['ffid'] = ffid;
      if (ffn != null) m['ffn'] = ffn;
      if (ffch != null) m['ffch'] = ffch;
      return m;
    }

    Map<String, dynamic> finalPayload;
    while (true) {
      finalPayload = buildPayload();
      final test = GossipPacket(
        id: _uuid.v4(),
        type: 'img_meta',
        ttl: _kDefaultTtl,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: finalPayload,
      );
      if (test.encode().length <= _kMaxImgPayloadBytes) break;
      if (ffn != null) {
        ffn = null;
        continue;
      }
      if (ffch != null) {
        ffch = null;
        continue;
      }
      if (ffid != null) {
        ffid = null;
        continue;
      }
      if (fnameForPayload != null) {
        fnameForPayload = null;
        continue;
      }
      break;
    }

    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'img_meta',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: finalPayload,
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
    final rid8 =
        (recipientId?.length ?? 0) >= 8 ? recipientId!.substring(0, 8) : null;
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
    double? lat,
    double? lng,
  }) async {
    final payload = <String, dynamic>{'text': text, 'col': color};
    if (senderId != null && senderNick != null) {
      payload['from'] = senderId;
      payload['nick'] = senderNick;
    }
    if (lat != null && lng != null) {
      payload['lat'] = lat;
      payload['lng'] = lng;
    }
    final packet = GossipPacket(
      id: messageId,
      type: 'ether',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    _gossipTrace('[RLINK][Gossip][TX] type=ether id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
        'len=${text.length} from=${(senderId ?? '').substring(0, (senderId ?? '').length.clamp(0, 8))}');
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

  /// Синхронизация пароля админ-панели между устройствами одной идентичности.
  /// Relay видит только AEAD-ciphertext; открыть может только владелец приватного ключа.
  Future<void> sendAdminConfigSecure({
    required String adminPasswordHash,
    required int revision,
    List<String> channelIds = const [],
  }) async {
    final myKey = myPublicKey ?? '';
    if (myKey.isEmpty) return;
    final inner = jsonEncode({
      'hash': adminPasswordHash,
      'rev': revision,
      'chans': channelIds,
    });
    final sealed = await CryptoService.instance.sealAdminPanelSync(inner);
    final boxMap = jsonDecode(sealed) as Map<String, dynamic>;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'admin_cfg2',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'from': myKey,
        'n': boxMap['n'],
        'ct': boxMap['ct'],
        'm': boxMap['m'],
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
    final rid8 = _rid8From(recipientId) ?? '';
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'pair_req',
      ttl: 1,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
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
    _gossipTrace('[RLINK][Gossip][TX] type=pair_req id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
        'to=$rid8 from=${publicKey.substring(0, publicKey.length.clamp(0, 8))}');
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
    final rid8 = _rid8From(recipientId) ?? '';
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'pair_acc',
      ttl: 1,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientId,
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
    _gossipTrace('[RLINK][Gossip][TX] type=pair_acc id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
        'to=$rid8 from=${publicKey.substring(0, publicKey.length.clamp(0, 8))}');
    _markSeen(packet.id);
    // Retry for reliability
    for (var i = 0; i < 3; i++) {
      await _forward(packet);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<void> sendDeviceLinkRequest({
    required String publicKey,
    required String nick,
    String username = '',
    required String recipientId,
  }) async {
    final rid8 =
        recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'dev_link_req',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: <String, dynamic>{
        'id': publicKey,
        'nick': nick,
        if (username.isNotEmpty) 'u': username,
        'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendDeviceLinkAck({
    required String publicKey,
    required String nick,
    required String recipientId,
    required bool accepted,
  }) async {
    final rid8 =
        recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'dev_link_ack',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: <String, dynamic>{
        'id': publicKey,
        'nick': nick,
        'ok': accepted,
        'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendDeviceUnlink({
    required String publicKey,
    required String recipientId,
  }) async {
    final rid8 =
        recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'dev_unlink',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: <String, dynamic>{
        'id': publicKey,
        'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendDeviceDmSyncRequest({
    required String publicKey,
    required String recipientId,
  }) async {
    final rid8 =
        recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'dev_dm_sync_req',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: <String, dynamic>{
        'id': publicKey,
        'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendDeviceDmSync({
    required String publicKey,
    required String recipientId,
    required String kind,
    Map<String, dynamic> data = const <String, dynamic>{},
    bool snapshot = false,
  }) async {
    final rid8 =
        recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'dev_dm_sync',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: <String, dynamic>{
        'id': publicKey,
        'k': kind,
        if (snapshot) 'snap': true,
        if (data.isNotEmpty) 'd': data,
        'r': rid8,
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
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
    String statusEmoji = '',
  }) async {
    final payload = <String, dynamic>{
      'id': id,
      'nick': nick,
      if (username.isNotEmpty) 'u': username,
      'color': color,
      'emoji': emoji,
      if (x25519Key.isNotEmpty) 'x': x25519Key,
      if (tags.isNotEmpty) 'tags': tags,
      'st': statusEmoji,
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
      debugPrint(
          '[RLINK][Gossip] Failed to decode packet (${rawBytes.length} bytes)');
      return;
    }

    if (_hasSeen(packet.id)) return;
    _markSeen(packet.id);
    if (kDebugMode) {
      debugPrint(
          '[RLINK][Gossip] Received type=${packet.type} ttl=${packet.ttl} id=${packet.id.substring(0, 8)}');
    }

    if (packet.isExpired) return;
    if (packet.ttl <= 0) return;

    await _handleIncoming(packet, sourceId: sourceId);

    final fromRelay = sourceId != null && sourceId.startsWith('relay:');
    // Do not re-inject relay-delivered packets back into relay transport.
    // Otherwise internet peers bounce the same packet in loops and create
    // self-echo traffic that obscures real delivery behavior.
    if (fromRelay) {
      if (packet.type == 'msg' ||
          packet.type == 'raw' ||
          packet.type == 'pair_req' ||
          packet.type == 'pair_acc' ||
          packet.type == 'ether') {
        _gossipTrace(
            '[RLINK][Gossip] relay_ingress_no_reforward type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))}');
      }
      return;
    }

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
        final replyToMessageId = (packet.payload['rt'] ??
            packet.payload['replyToMessageId']) as String?;

        // Фильтрация по префиксу получателя: если 'r' задан и не совпадает с нашим ключом
        // значит сообщение предназначено другому пользователю — пропускаем
        final myKey = myPublicKey;
        if (!_matchesRid8(myKey, rid8)) {
          debugPrint(
              '[RLINK][Gossip] Raw message not for us (rid prefix mismatch)');
          return;
        }

        debugPrint('[Gossip] Raw message from=$from len=${text?.length}');
        if (text != null) {
          final handler = onMessageReceived;
          if (handler != null) {
            final lat = (packet.payload['lat'] as num?)?.toDouble();
            final lng = (packet.payload['lng'] as num?)?.toDouble();
            final ffid = packet.payload['ffid'] as String?;
            final ffn = packet.payload['ffn'] as String?;
            final ffch = packet.payload['ffch'] as String?;
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
              forwardFromId: ffid,
              forwardFromNick: ffn,
              forwardFromChannelId: ffch,
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
        final color = _jsonIntLoose(packet.payload['color']);
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';
        final tags =
            (packet.payload['tags'] as List<dynamic>?)?.cast<String>() ??
                const <String>[];
        final String? statusEmojiPayload = packet.payload.containsKey('st')
            ? (packet.payload['st'] as String? ?? '')
            : null;

        // Валидация: публичный ключ Ed25519 = 64 hex символа
        final isValidKey = publicKey != null &&
            publicKey.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey);

        if (isValidKey && nick != null && nick.isNotEmpty && color != null) {
          // sourceId — BLE ID пира, который прислал пакет напрямую.
          // onProfile в main.dart проверит isDirectBleId(bleId) перед регистрацией маппинга.
          final bleId = sourceId ?? publicKey;
          onProfileReceived?.call(bleId, publicKey, nick, username, color,
              emoji, x25519Key, tags, statusEmojiPayload);
        } else {
          debugPrint(
              '[RLINK][Gossip] Invalid profile packet: key=$publicKey nick=$nick');
        }
        return;
      }

      if (packet.type == 'msg') {
        // Фильтрация по 8-символьному префиксу получателя
        final rid8 = packet.payload['r'] as String?;
        final myKey = myPublicKey;
        if (!_matchesRid8(myKey, rid8)) {
          _gossipTrace('[RLINK][Gossip][DROP] type=msg id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
              'my=${(myKey ?? '').substring(0, (myKey ?? '').length.clamp(0, 8))} rid8=${rid8 ?? '-'}');
          // Не нам — пакет будет переслан в onPacketReceived
          return;
        }
        _gossipTrace('[RLINK][Gossip][RX] type=msg id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} rid8=${rid8 ?? '-'}');
        final encrypted = EncryptedMessage.fromJson(packet.payload);
        // Drop malformed encrypted messages — prevents ciphertext leaking as plaintext
        if (encrypted.ephemeralPublicKey.isEmpty ||
            encrypted.nonce.isEmpty ||
            encrypted.cipherText.isEmpty ||
            encrypted.mac.isEmpty) {
          debugPrint(
              '[RLINK][Gossip] Dropping malformed msg packet (missing fields)');
          return;
        }
        final handler = onMessageReceived;
        if (handler != null) {
          final lat = (packet.payload['lat'] as num?)?.toDouble();
          final lng = (packet.payload['lng'] as num?)?.toDouble();
          final rt = (packet.payload['rt'] ??
              packet.payload['replyToMessageId']) as String?;
          final ffid = packet.payload['ffid'] as String?;
          final ffn = packet.payload['ffn'] as String?;
          final ffch = packet.payload['ffch'] as String?;
          await handler(
            encrypted.senderPublicKey,
            encrypted,
            packet.id,
            rt,
            latitude: lat,
            longitude: lng,
            forwardFromId: ffid,
            forwardFromNick: ffn,
            forwardFromChannelId: ffch,
          );
        }
        return;
      }

      if (packet.type == 'dm_pin') {
        final handler = onDmPin;
        if (handler != null) {
          await handler(packet.payload);
        }
        return;
      }

      if (packet.type == 'img_meta') {
        final msgId = packet.payload['msgId'] as String?;
        final totalChunks = _jsonIntLoose(packet.payload['chunks']);
        final from = packet.payload['from'] as String? ?? 'unknown';
        final isAvatar = (packet.payload['avatar'] as bool?) ?? false;
        final isVoice = (packet.payload['voice'] as bool?) ?? false;
        final isVideo = (packet.payload['video'] as bool?) ?? false;
        final isSquare = (packet.payload['sq'] as bool?) ?? false;
        final isFile = (packet.payload['file'] as bool?) ?? false;
        final isSticker = (packet.payload['stk'] as bool?) ?? false;
        final fileName = packet.payload['fname'] as String?;
        final viewOnce = (packet.payload['vo'] as bool?) ?? false;
        final ffid = packet.payload['ffid'] as String?;
        final ffn = packet.payload['ffn'] as String?;
        final ffch = packet.payload['ffch'] as String?;
        // Фильтрация по rid8: не-аватарные пакеты, адресованные другому получателю, игнорируем
        final rid8 = packet.payload['r'] as String?;
        if (!isAvatar && !_matchesRid8(myPublicKey, rid8)) {
          debugPrint(
              '[RLINK][Gossip] img_meta not for us (rid8 mismatch), skip');
          if (msgId != null) _pendingImgChunks.remove(msgId);
          return;
        }
        if (msgId != null && totalChunks != null) {
          // Store rid8 and from for chunk filtering
          if (rid8 != null) _imgMetaRid8[msgId] = rid8;
          _imgMetaFrom[msgId] = from;
          onImgMeta?.call(from, msgId, totalChunks, isAvatar, isVoice, isVideo,
              isSquare, isFile, isSticker, fileName, viewOnce,
              forwardFromId: ffid,
              forwardFromNick: ffn,
              forwardFromChannelId: ffch);
          _deliverPendingImgChunks(msgId);
        }
        return;
      }

      if (packet.type == 'ether') {
        final text = packet.payload['text'] as String?;
        final color = _jsonIntLoose(packet.payload['col']);
        _gossipTrace('[RLINK][Gossip][RX] type=ether id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
            'textLen=${text?.length ?? 0} col=$color handler=${onEtherReceived != null}');
        if (text != null && text.isNotEmpty && color != null) {
          final senderId = packet.payload['from'] as String?;
          final senderNick = packet.payload['nick'] as String?;
          final lat = (packet.payload['lat'] as num?)?.toDouble();
          final lng = (packet.payload['lng'] as num?)?.toDouble();
          onEtherReceived?.call(
            packet.id,
            text,
            color,
            senderId,
            senderNick,
            lat: lat,
            lng: lng,
          );
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

      if (packet.type == 'admin_cfg2') {
        final from = packet.payload['from'] as String?;
        if (from == null || myPublicKey == null || from != myPublicKey) {
          return;
        }
        final n = packet.payload['n'] as String?;
        final ct = packet.payload['ct'] as String?;
        final m = packet.payload['m'] as String?;
        if (n == null || ct == null || m == null) return;
        final sealed = jsonEncode({'n': n, 'ct': ct, 'm': m});
        final plain = await CryptoService.instance.openAdminPanelSync(sealed);
        if (plain == null) return;
        try {
          final map = jsonDecode(plain) as Map<String, dynamic>;
          final hash = map['hash'] as String?;
          final rev = (map['rev'] as num?)?.toInt() ?? 0;
          final chans =
              (map['chans'] as List?)?.cast<String>() ?? const <String>[];
          if (hash == null ||
              hash.length != 64 ||
              !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
            return;
          }
          onAdminConfigSecure?.call(hash, rev, chans);
        } catch (_) {}
        return;
      }

      if (packet.type == 'admin_cfg') {
        final rid8 = packet.payload['r'] as String?;
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        onAdminConfig?.call(packet.payload);
        return;
      }

      if (packet.type == 'story') {
        final authorId = packet.payload['from'] as String?;
        final text = packet.payload['text'] as String?;
        final bgColor = _jsonIntLoose(packet.payload['col']);
        debugPrint(
            '[RLINK][Gossip] Story packet: author=${authorId == null ? 'null' : authorId.substring(0, authorId.length.clamp(0, 16))} text=${text == null ? 'null' : text.substring(0, text.length.clamp(0, 20))} handler=${onStoryReceived != null}');
        if (authorId != null && text != null && bgColor != null) {
          final textX = (packet.payload['tx'] as num?)?.toDouble() ?? 0.0;
          final textY = (packet.payload['ty'] as num?)?.toDouble() ?? 0.0;
          final textSize = (packet.payload['ts'] as num?)?.toDouble() ?? 26.0;
          onStoryReceived?.call(
              packet.id, authorId, text, bgColor, textX, textY, textSize);
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
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
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
        final color = _jsonIntLoose(packet.payload['color']);
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';
        final rid8 = packet.payload['r'] as String?;
        final tags =
            (packet.payload['tags'] as List<dynamic>?)?.cast<String>() ??
                const <String>[];
        final bleId = sourceId ?? publicKey ?? '';
        // Drop pair_req not addressed to us (directed pairing)
        if (!_matchesRid8(myPublicKey, rid8)) {
          _gossipTrace('[RLINK][Gossip][DROP] type=pair_req id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
              'my=${(myPublicKey ?? '').substring(0, (myPublicKey ?? '').length.clamp(0, 8))} r=$rid8');
          return;
        }
        if (publicKey != null && nick != null && color != null) {
          _gossipTrace(
              '[RLINK][Gossip][RX] type=pair_req from=${publicKey.substring(0, 8)} nick=$nick');
          onPairRequest?.call(
              bleId, publicKey, nick, username, color, emoji, x25519Key, tags);
        }
        return;
      }

      if (packet.type == 'pair_acc') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String?;
        final username = packet.payload['u'] as String? ?? '';
        final color = _jsonIntLoose(packet.payload['color']);
        final emoji = packet.payload['emoji'] as String? ?? '';
        final x25519Key = packet.payload['x'] as String? ?? '';
        final rid8 = packet.payload['r'] as String?;
        final tags =
            (packet.payload['tags'] as List<dynamic>?)?.cast<String>() ??
                const <String>[];
        final bleId = sourceId ?? publicKey ?? '';
        // Drop pair_acc not addressed to us (directed pairing)
        if (!_matchesRid8(myPublicKey, rid8)) {
          _gossipTrace('[RLINK][Gossip][DROP] type=pair_acc id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
              'my=${(myPublicKey ?? '').substring(0, (myPublicKey ?? '').length.clamp(0, 8))} r=$rid8');
          return;
        }
        if (publicKey != null && nick != null && color != null) {
          _gossipTrace(
              '[RLINK][Gossip][RX] type=pair_acc from=${publicKey.substring(0, 8)} nick=$nick');
          onPairAccepted?.call(
              bleId, publicKey, nick, username, color, emoji, x25519Key, tags);
        }
        return;
      }

      if (packet.type == 'dev_link_req') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String?;
        final username = packet.payload['u'] as String? ?? '';
        final rid8 = packet.payload['r'] as String?;
        final srcId = sourceId ?? publicKey ?? '';
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        if (publicKey != null && nick != null && nick.isNotEmpty) {
          onDeviceLinkRequest?.call(srcId, publicKey, nick, username);
        }
        return;
      }

      if (packet.type == 'dev_link_ack') {
        final publicKey = packet.payload['id'] as String?;
        final nick = packet.payload['nick'] as String? ?? '';
        final accepted = packet.payload['ok'] == true;
        final rid8 = packet.payload['r'] as String?;
        final srcId = sourceId ?? publicKey ?? '';
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        if (publicKey != null) {
          onDeviceLinkAck?.call(srcId, publicKey, nick, accepted);
        }
        return;
      }

      if (packet.type == 'dev_unlink') {
        final publicKey = packet.payload['id'] as String?;
        final rid8 = packet.payload['r'] as String?;
        final srcId = sourceId ?? publicKey ?? '';
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        if (publicKey != null) {
          onDeviceUnlink?.call(srcId, publicKey);
        }
        return;
      }

      if (packet.type == 'dev_dm_sync_req') {
        final publicKey = packet.payload['id'] as String?;
        final rid8 = packet.payload['r'] as String?;
        final srcId = sourceId ?? publicKey ?? '';
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        if (publicKey != null) {
          onDeviceDmSyncRequest?.call(srcId, publicKey);
        }
        return;
      }

      if (packet.type == 'dev_dm_sync') {
        final publicKey = packet.payload['id'] as String?;
        final kind = packet.payload['k'] as String?;
        final data = (packet.payload['d'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        final snapshot = packet.payload['snap'] == true;
        final rid8 = packet.payload['r'] as String?;
        final srcId = sourceId ?? publicKey ?? '';
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        if (publicKey != null && kind != null && kind.isNotEmpty) {
          await onDeviceDmSyncPacket?.call(
            srcId,
            publicKey,
            kind,
            data,
            snapshot,
          );
        }
        return;
      }

      if (packet.type == 'typing') {
        final from = packet.payload['from'] as String?;
        final activity = _jsonIntLoose(packet.payload['a']);
        final rid8 = packet.payload['r'] as String?;
        if (from == null || activity == null) return;
        // Filter by recipient prefix
        if (!_matchesRid8(myPublicKey, rid8)) {
          return;
        }
        onTypingReceived?.call(from, activity);
        return;
      }

      if (packet.type == 'img_chunk') {
        final msgId = packet.payload['msgId'] as String?;
        final index = _jsonIntLoose(packet.payload['idx']);
        final data = packet.payload['data'] as String?;
        if (msgId == null ||
            msgId.isEmpty ||
            index == null ||
            index < 0 ||
            data == null ||
            data.isEmpty) {
          return;
        }
        // Filter chunks: if we received img_meta with rid8 for this msgId,
        // and it wasn't for us, skip the chunk too
        final storedRid8 = _imgMetaRid8[msgId];
        if (storedRid8 != null &&
            myPublicKey != null &&
            !myPublicKey!.startsWith(storedRid8)) {
          return; // chunk not for us
        }
        final chunkRid8 = packet.payload['r'] as String?;
        // Directed media: chunk can arrive before img_meta — drop if clearly not for us.
        if (storedRid8 == null &&
            chunkRid8 != null &&
            myPublicKey != null &&
            !myPublicKey!.startsWith(chunkRid8)) {
          return;
        }
        final from = _imgMetaFrom[msgId];
        if (from == null) {
          // Mesh often delivers img_chunk before img_meta — buffer until meta arrives.
          final bucket = _pendingImgChunks.putIfAbsent(msgId, () => {});
          if (bucket.length >= 512) return;
          bucket[index] = data;
          return;
        }
        onImgChunk?.call(from, msgId, 0, index, data);
        return;
      }

      // ── Extended reactions (stories / channel posts / comments / group messages)
      if (packet.type == 'react_ext') {
        onReactionExt?.call(packet.payload);
        return;
      }

      // ── Channel packets ────────────────────────────────────────
      if (packet.type == 'ch_bak_key') {
        final h = onChannelBackupKey;
        if (h != null) await h(packet);
        return;
      }
      if (packet.type == 'ch_bak_meta') {
        final h = onChannelBackupMeta;
        if (h != null) await h(packet);
        return;
      }
      if (packet.type == 'ch_bak_c') {
        final h = onChannelBackupChunk;
        if (h != null) await h(packet);
        return;
      }
      if (packet.type == 'channel_meta') {
        onChannelMeta?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_post') {
        onChannelPost?.call(packet.payload);
        return;
      }
      if (packet.type == 'channel_post_view') {
        final postId = packet.payload['p'] as String?;
        final viewerId = packet.payload['v'] as String?;
        if (postId != null && viewerId != null) {
          onChannelPostView?.call(postId, viewerId);
        }
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
      if (packet.type == 'channel_comment_del') {
        onChannelCommentDelete?.call(packet.payload);
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
      if (packet.type == 'group_history_req') {
        onGroupHistoryReq?.call(packet.payload);
        return;
      }
      if (packet.type == 'poll_vote') {
        onPollVote?.call(packet.payload);
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
    if (onForwardPacket == null) {
      _gossipTrace(
          '[RLINK][Gossip][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=onForwardPacket_null');
      return;
    }
    final bytes = packet.encode();
    if (bytes.length > _kMaxPayloadBytes) {
      debugPrint(
          '[RLINK][Gossip] Packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      _gossipTrace(
          '[RLINK][Gossip][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=forward_failed err=$e');
    }
  }

  /// Для зашифрованных 'msg' пакетов используем увеличенный лимит (MTU 512).
  Future<void> _forwardEncrypted(GossipPacket packet) async {
    if (onForwardPacket == null) {
      _gossipTrace(
          '[RLINK][Gossip][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=onForwardPacket_null');
      return;
    }
    final bytes = packet.encode();
    if (bytes.length > _kMaxEncPayloadBytes) {
      debugPrint(
          '[Gossip] Encrypted packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      _gossipTrace(
          '[RLINK][Gossip][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=encrypted_forward_failed err=$e');
    }
  }

  /// Для img_meta/img_chunk используем увеличенный лимит.
  Future<void> _forwardImg(GossipPacket packet) async {
    if (onForwardPacket == null) {
      _gossipTrace(
          '[RLINK][Gossip][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=onForwardPacket_null');
      return;
    }
    final bytes = packet.encode();
    if (bytes.length > _kMaxImgPayloadBytes) {
      debugPrint(
          '[Gossip] Img packet too large (${bytes.length} bytes), dropping');
      return;
    }
    try {
      await onForwardPacket!(packet);
    } catch (e) {
      _gossipTrace(
          '[RLINK][Gossip][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=img_forward_failed err=$e');
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
        _pendingImgChunks.remove(keys[i]);
      }
    }
    if (_pendingImgChunks.length > 120) {
      final keys = _pendingImgChunks.keys.toList();
      for (var i = 0; i < keys.length - 60; i++) {
        _pendingImgChunks.remove(keys[i]);
      }
    }
  }

  void _deliverPendingImgChunks(String msgId) {
    final pending = _pendingImgChunks.remove(msgId);
    if (pending == null || pending.isEmpty) return;
    final from = _imgMetaFrom[msgId];
    final handler = onImgChunk;
    if (from == null || handler == null) return;
    final idxs = pending.keys.toList()..sort();
    for (final idx in idxs) {
      final d = pending[idx];
      if (d != null && d.isNotEmpty) {
        handler(from, msgId, 0, idx, d);
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
    List<String>? linkAdminIds,
    bool? signStaffPosts,
    Map<String, String>? staffLabels,
    String? username,
    String? universalCode,
    bool? isPublic,
    bool? driveBackup,
    int? driveBackupRev,
    bool? allowModeratorsManageDriveAccount,
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
        'avatarColor': avatarColor ?? 0xFF42A5F5,
        'avatarEmoji': avatarEmoji ?? '📢',
        if (description != null) 'description': description,
        'commentsEnabled': commentsEnabled,
        if (createdAt != null) 'createdAt': createdAt,
        'verified': verified,
        if (verifiedBy != null) 'verifiedBy': verifiedBy,
        if (subscriberIds != null) 'subscriberIds': subscriberIds,
        if (moderatorIds != null) 'moderatorIds': moderatorIds,
        if (linkAdminIds != null) 'linkAdminIds': linkAdminIds,
        if (signStaffPosts != null) 'signStaffPosts': signStaffPosts,
        if (staffLabels != null && staffLabels.isNotEmpty)
          'staffLabels': staffLabels,
        if (username != null && username.isNotEmpty) 'username': username,
        if (universalCode != null && universalCode.isNotEmpty)
          'universalCode': universalCode,
        if (isPublic != null) 'isPublic': isPublic,
        if (driveBackup != null) 'driveBackup': driveBackup,
        if (driveBackupRev != null) 'driveBackupRev': driveBackupRev,
        if (allowModeratorsManageDriveAccount != null)
          'allowModeratorsManageDriveAccount':
              allowModeratorsManageDriveAccount,
      },
    );
    await _forward(packet);
  }

  Future<void> sendChannelBackupKey({
    required String channelId,
    required String recipientPublicKeyHex,
    required EncryptedMessage wrapped,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'ch_bak_key',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      recipientId: recipientPublicKeyHex,
      payload: {
        'cid': channelId,
        'em': wrapped.toJson(),
      },
    );
    _markSeen(packet.id);
    await _forward(packet);
  }

  Future<void> sendChannelBackupMeta({
    required String channelId,
    required int rev,
    required int totalChunks,
    required String adminId,
    required String msgId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'ch_bak_meta',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'cid': channelId,
        'r': rev,
        'n': totalChunks,
        'from': adminId,
        'mid': msgId,
      },
    );
    _markSeen(packet.id);
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 280));
    }
  }

  Future<void> sendChannelBackupChunk({
    required String msgId,
    required int index,
    required String base64Data,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'ch_bak_c',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'mid': msgId,
        'i': index,
        'd': base64Data,
      },
    );
    _markSeen(packet.id);
    await _forwardImg(packet);
  }

  /// Broadcasts a channel post to the mesh. [timestamp] lets peers preserve the
  /// original creation time when re-broadcasted from history (P2P история канала).
  /// [reactionsJson] — опциональный JSON-энкодед map реакций (для full-state sync).
  /// [hasImage]/[hasVideo]/[hasFile]/[fileName] — хинты о медиа, сами байты
  /// передаются отдельно через img_meta/img_chunk (postId = msgId).
  Future<void> sendChannelPost({
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
        if (timestamp != null) 'ts': timestamp,
        if (reactionsJson != null && reactionsJson.isNotEmpty)
          'rx': reactionsJson,
        if (hasImage) 'img': true,
        if (hasVideo) 'vid': true,
        if (hasVoice) 'voice': true,
        if (hasFile) 'file': true,
        if (isSticker) 'stk': true,
        if (fileName != null && fileName.isNotEmpty) 'fname': fileName,
        if (pollJson != null && pollJson.isNotEmpty) 'pj': pollJson,
        if (staffLabel != null && staffLabel.isNotEmpty) 'sl': staffLabel,
      },
    );
    await _forward(packet);
  }

  /// Распространяет факт просмотра поста канала (один зритель — один раз на узел).
  Future<void> sendChannelPostView({
    required String postId,
    required String viewerId,
  }) async {
    final packet = GossipPacket(
      id: _uuid.v4(),
      type: 'channel_post_view',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'p': postId,
        'v': viewerId,
      },
    );
    _markSeen(packet.id);
    for (var i = 0; i < 2; i++) {
      await _forward(packet);
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> sendPollVote({
    required String kind,
    required String targetId,
    required String voterId,
    required List<int> choiceIndices,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'poll_vote',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'k': kind,
        't': targetId,
        'v': voterId,
        'c': choiceIndices,
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
    int? timestamp,
    String? reactionsJson,
    bool hasImage = false,
    bool hasVideo = false,
    bool hasVoice = false,
    bool hasFile = false,
    String? fileName,
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
        if (timestamp != null) 'ts': timestamp,
        if (reactionsJson != null && reactionsJson.isNotEmpty)
          'rx': reactionsJson,
        if (hasImage) 'img': true,
        if (hasVideo) 'vid': true,
        if (hasVoice) 'voice': true,
        if (hasFile) 'file': true,
        if (fileName != null && fileName.isNotEmpty) 'fname': fileName,
      },
    );
    await _forward(packet);
  }

  Future<void> sendChannelCommentDelete({
    required String channelId,
    required String postId,
    required String commentId,
    required String byUserId,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_comment_del',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'postId': postId,
        'commentId': commentId,
        'by': byUserId,
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
    String? ffnShort(String? n) {
      if (n == null || n.isEmpty) return null;
      return n.length > 36 ? n.substring(0, 36) : n;
    }

    var ffid = (forwardFromId != null &&
            forwardFromId.length == 64 &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(forwardFromId))
        ? forwardFromId
        : null;
    var ffn = ffnShort(forwardFromNick);
    Map<String, dynamic> buildPayload() => {
          'groupId': groupId,
          'senderId': senderId,
          'text': text,
          'messageId': messageId,
          if (timestamp != null) 'ts': timestamp,
          if (latitude != null) 'lat': latitude,
          if (longitude != null) 'lng': longitude,
          if (reactionsJson != null && reactionsJson.isNotEmpty)
            'rx': reactionsJson,
          if (hasImage) 'img': true,
          if (hasVideo) 'vid': true,
          if (hasFile) 'file': true,
          if (fileName != null && fileName.isNotEmpty) 'fname': fileName,
          if (pollJson != null && pollJson.isNotEmpty) 'pj': pollJson,
          if (ffid != null) 'ffid': ffid,
          if (ffn != null) 'ffn': ffn,
        };

    while (true) {
      final packet = GossipPacket(
        id: const Uuid().v4(),
        type: 'group_message',
        ttl: _kDefaultTtl,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: buildPayload(),
      );
      if (packet.encode().length <= _kMaxPayloadBytes) {
        await _forward(packet);
        return;
      }
      if (ffn != null) {
        ffn = null;
        continue;
      }
      if (ffid != null) {
        ffid = null;
        continue;
      }
      debugPrint('[RLINK][Gossip] group_message packet too large, dropping');
      return;
    }
  }

  /// Запрос истории группы: отправляется новым участником (или при открытии
  /// группы для синхронизации «что пропустил»). Любой онлайн-участник отвечает
  /// набором `group_message` с исходным `messageId` и `timestamp`.
  Future<void> sendGroupHistoryRequest({
    required String groupId,
    required String requesterId,
    int sinceTs = 0,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'group_history_req',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'groupId': groupId,
        'requesterId': requesterId,
        'sinceTs': sinceTs,
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
    String? universalCode,
  }) async {
    final packet = GossipPacket(
      id: const Uuid().v4(),
      type: 'channel_admin_delete',
      ttl: _kDefaultTtl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'channelId': channelId,
        'by': byAdmin,
        if (universalCode != null && universalCode.isNotEmpty)
          'uc': universalCode,
      },
    );
    await _forward(packet);
  }

  // Callbacks for admin actions
  void Function(Map<String, dynamic> payload)? onChannelForeignAgent;
  void Function(Map<String, dynamic> payload)? onChannelBlock;
  void Function(Map<String, dynamic> payload)? onChannelAdminDelete;
}
