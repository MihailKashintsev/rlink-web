import 'dart:convert';

import '../services/image_service.dart';

class ChatMessage {
  final String id;
  final String peerId;
  final String text;
  final String? replyToMessageId;
  final String? imagePath;
  final String? videoPath; // локальный путь к видеосообщению (.mp4)
  final String? voicePath; // локальный путь к голосовому сообщению (.m4a)
  final String? filePath;  // локальный путь к файлу/документу
  final String? fileName;  // оригинальное имя файла
  final int? fileSize;     // размер файла в байтах
  final double? latitude;  // геотег — широта (локально, не передаётся по BLE)
  final double? longitude; // геотег — долгота
  final bool isOutgoing;
  final DateTime timestamp;
  final MessageStatus status;
  final Map<String, List<String>> reactions;
  /// Одноразовый просмотр (медиа): до открытия скрываем превью у получателя.
  final bool viewOnce;
  final bool viewOnceOpened;
  /// Переслано: публичный ключ автора оригинала (Ed25519 hex).
  final String? forwardFromId;
  /// Отображаемое имя автора оригинала (подпись над пересланным).
  final String? forwardFromNick;
  /// Переслано из канала — id канала (для перехода в ленту).
  final String? forwardFromChannelId;
  /// JSON приглашения в канал/группу в ЛС (`kind` + поля payload), для кнопок в пузыре.
  final String? invitePayloadJson;
  /// Id файлов, загруженных в GigaChat (чат с ИИ); хранится как JSON-массив в БД.
  final List<String> gigachatAttachmentIds;

  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.text,
    this.replyToMessageId,
    this.imagePath,
    this.videoPath,
    this.voicePath,
    this.filePath,
    this.fileName,
    this.fileSize,
    this.latitude,
    this.longitude,
    required this.isOutgoing,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.reactions = const {},
    this.viewOnce = false,
    this.viewOnceOpened = false,
    this.forwardFromId,
    this.forwardFromNick,
    this.forwardFromChannelId,
    this.invitePayloadJson,
    this.gigachatAttachmentIds = const [],
  });

  ChatMessage copyWith({
    MessageStatus? status,
    String? imagePath,
    String? videoPath,
    String? voicePath,
    String? filePath,
    String? fileName,
    int? fileSize,
    double? latitude,
    double? longitude,
    Map<String, List<String>>? reactions,
    bool? viewOnce,
    bool? viewOnceOpened,
    String? forwardFromId,
    String? forwardFromNick,
    String? forwardFromChannelId,
    String? invitePayloadJson,
    List<String>? gigachatAttachmentIds,
  }) =>
      ChatMessage(
        id: id,
        peerId: peerId,
        text: text,
        replyToMessageId: replyToMessageId,
        imagePath: imagePath ?? this.imagePath,
        videoPath: videoPath ?? this.videoPath,
        voicePath: voicePath ?? this.voicePath,
        filePath: filePath ?? this.filePath,
        fileName: fileName ?? this.fileName,
        fileSize: fileSize ?? this.fileSize,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        isOutgoing: isOutgoing,
        timestamp: timestamp,
        status: status ?? this.status,
        reactions: reactions ?? this.reactions,
        viewOnce: viewOnce ?? this.viewOnce,
        viewOnceOpened: viewOnceOpened ?? this.viewOnceOpened,
        forwardFromId: forwardFromId ?? this.forwardFromId,
        forwardFromNick: forwardFromNick ?? this.forwardFromNick,
        forwardFromChannelId:
            forwardFromChannelId ?? this.forwardFromChannelId,
        invitePayloadJson: invitePayloadJson ?? this.invitePayloadJson,
        gigachatAttachmentIds:
            gigachatAttachmentIds ?? this.gigachatAttachmentIds,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'peer_id': peerId,
        'text': text,
        'reply_to_message_id': replyToMessageId,
        'image_path': imagePath,
        'video_path': videoPath,
        'voice_path': voicePath,
        'file_path': filePath,
        'file_name': fileName,
        'file_size': fileSize,
        'latitude': latitude,
        'longitude': longitude,
        'is_outgoing': isOutgoing ? 1 : 0,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.index,
        'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
        'view_once': viewOnce ? 1 : 0,
        'view_once_opened': viewOnceOpened ? 1 : 0,
        'forward_from_id': forwardFromId,
        'forward_from_nick': forwardFromNick,
        'forward_from_channel_id': forwardFromChannelId,
        'invite_payload': invitePayloadJson,
        'gigachat_attachment_ids': gigachatAttachmentIds.isEmpty
            ? null
            : jsonEncode(gigachatAttachmentIds),
      };

  factory ChatMessage.fromMap(Map<String, dynamic> m) {
    Map<String, List<String>> reactions = {};
    final raw = m['reactions'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        reactions =
            decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
      } catch (_) {}
    }
    var gigaAtt = const <String>[];
    final gigaRaw = m['gigachat_attachment_ids'] as String?;
    if (gigaRaw != null && gigaRaw.isNotEmpty) {
      try {
        gigaAtt = (jsonDecode(gigaRaw) as List).cast<String>();
      } catch (_) {}
    }
    // Resolve potentially stale iOS sandbox paths for media files
    final resolve = ImageService.instance.resolveStoredPath;
    return ChatMessage(
      id: m['id'] as String,
      peerId: m['peer_id'] as String,
      text: m['text'] as String,
      replyToMessageId: m['reply_to_message_id'] as String?,
      imagePath: resolve(m['image_path'] as String?),
      videoPath: resolve(m['video_path'] as String?),
      voicePath: resolve(m['voice_path'] as String?),
      filePath: resolve(m['file_path'] as String?),
      fileName: m['file_name'] as String?,
      fileSize: m['file_size'] as int?,
      latitude: (m['latitude'] as num?)?.toDouble(),
      longitude: (m['longitude'] as num?)?.toDouble(),
      isOutgoing: (m['is_outgoing'] as int) == 1,
      timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
      status: MessageStatus
          .values[(m['status'] as int?)?.clamp(0, MessageStatus.values.length - 1) ??
              0],
      reactions: reactions,
      viewOnce: (m['view_once'] as int?) == 1,
      viewOnceOpened: (m['view_once_opened'] as int?) == 1,
      forwardFromId: m['forward_from_id'] as String?,
      forwardFromNick: m['forward_from_nick'] as String?,
      forwardFromChannelId: m['forward_from_channel_id'] as String?,
      invitePayloadJson: m['invite_payload'] as String?,
      gigachatAttachmentIds: gigaAtt,
    );
  }
}

enum MessageStatus { sending, sent, delivered, failed }

class ChatPreview {
  final String peerId;
  final String peerNickname;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String lastMessage;
  final DateTime lastMessageTime;
  final int unreadCount;
  final bool isOnline;

  const ChatPreview({
    required this.peerId,
    required this.peerNickname,
    required this.peerAvatarColor,
    required this.peerAvatarEmoji,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.unreadCount,
    required this.isOnline,
  });

  String get initials {
    final parts = peerNickname.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return peerNickname.isNotEmpty ? peerNickname[0].toUpperCase() : '?';
  }
}
