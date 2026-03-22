import 'dart:convert';

class ChatMessage {
  final String id;
  final String peerId;
  final String text;
  final String? replyToMessageId;
  final String? imagePath;
  final String? videoPath; // локальный путь к видеосообщению (.mp4)
  final String? voicePath; // локальный путь к голосовому сообщению (.m4a)
  final double? latitude;  // геотег — широта (локально, не передаётся по BLE)
  final double? longitude; // геотег — долгота
  final bool isOutgoing;
  final DateTime timestamp;
  final MessageStatus status;
  final Map<String, List<String>> reactions;

  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.text,
    this.replyToMessageId,
    this.imagePath,
    this.videoPath,
    this.voicePath,
    this.latitude,
    this.longitude,
    required this.isOutgoing,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.reactions = const {},
  });

  ChatMessage copyWith({
    MessageStatus? status,
    String? imagePath,
    String? videoPath,
    String? voicePath,
    double? latitude,
    double? longitude,
    Map<String, List<String>>? reactions,
  }) =>
      ChatMessage(
        id: id,
        peerId: peerId,
        text: text,
        replyToMessageId: replyToMessageId,
        imagePath: imagePath ?? this.imagePath,
        videoPath: videoPath ?? this.videoPath,
        voicePath: voicePath ?? this.voicePath,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        isOutgoing: isOutgoing,
        timestamp: timestamp,
        status: status ?? this.status,
        reactions: reactions ?? this.reactions,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'peer_id': peerId,
        'text': text,
        'reply_to_message_id': replyToMessageId,
        'image_path': imagePath,
        'video_path': videoPath,
        'voice_path': voicePath,
        'latitude': latitude,
        'longitude': longitude,
        'is_outgoing': isOutgoing ? 1 : 0,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status.index,
        'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
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
    return ChatMessage(
      id: m['id'] as String,
      peerId: m['peer_id'] as String,
      text: m['text'] as String,
      replyToMessageId: m['reply_to_message_id'] as String?,
      imagePath: m['image_path'] as String?,
      videoPath: m['video_path'] as String?,
      voicePath: m['voice_path'] as String?,
      latitude: (m['latitude'] as num?)?.toDouble(),
      longitude: (m['longitude'] as num?)?.toDouble(),
      isOutgoing: (m['is_outgoing'] as int) == 1,
      timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
      status: MessageStatus.values[m['status'] as int],
      reactions: reactions,
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
