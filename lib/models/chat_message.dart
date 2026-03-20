class ChatMessage {
  final String id;
  final String peerId;      // ID собеседника
  final String text;
  final String? replyToMessageId; // ID сообщения, на которое отвечают
  final String? imagePath;  // локальный путь к прикреплённому изображению
  final bool isOutgoing;
  final DateTime timestamp;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.text,
    this.replyToMessageId,
    this.imagePath,
    required this.isOutgoing,
    required this.timestamp,
    this.status = MessageStatus.sent,
  });

  ChatMessage copyWith({MessageStatus? status, String? imagePath}) => ChatMessage(
        id:               id,
        peerId:           peerId,
        text:             text,
        replyToMessageId: replyToMessageId,
        imagePath:        imagePath ?? this.imagePath,
        isOutgoing:       isOutgoing,
        timestamp:        timestamp,
        status:           status ?? this.status,
      );

  Map<String, dynamic> toMap() => {
        'id':                  id,
        'peer_id':             peerId,
        'text':                text,
        'reply_to_message_id': replyToMessageId,
        'image_path':          imagePath,
        'is_outgoing':         isOutgoing ? 1 : 0,
        'timestamp':           timestamp.millisecondsSinceEpoch,
        'status':              status.index,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        id:               m['id']               as String,
        peerId:           m['peer_id']           as String,
        text:             m['text']              as String,
        replyToMessageId: m['reply_to_message_id'] as String?,
        imagePath:        m['image_path']        as String?,
        isOutgoing:       (m['is_outgoing'] as int) == 1,
        timestamp:        DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
        status:           MessageStatus.values[m['status'] as int],
      );
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
