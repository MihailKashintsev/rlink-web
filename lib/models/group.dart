import 'dart:convert';

/// Модель группового чата.
class Group {
  final String id; // UUID группы
  final String name;
  final String creatorId; // publicKeyHex создателя
  final List<String> memberIds; // publicKeyHex всех участников
  final List<String> moderatorIds; // publicKeyHex модераторов (могут всё, кроме удаления группы)
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;
  final int createdAt; // ms since epoch

  const Group({
    required this.id,
    required this.name,
    required this.creatorId,
    required this.memberIds,
    this.moderatorIds = const [],
    this.avatarColor = 0xFF5C6BC0,
    this.avatarEmoji = '👥',
    this.avatarImagePath,
    required this.createdAt,
  });

  /// Returns true if [userId] is an admin (creator) or moderator.
  bool canModerate(String userId) => userId == creatorId || moderatorIds.contains(userId);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'creator': creatorId,
        'members': memberIds,
        if (moderatorIds.isNotEmpty) 'mods': moderatorIds,
        'color': avatarColor,
        'emoji': avatarEmoji,
        if (avatarImagePath != null) 'img': avatarImagePath,
        'ts': createdAt,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: j['name'] as String,
        creatorId: j['creator'] as String,
        memberIds: (j['members'] as List).cast<String>(),
        moderatorIds: j['mods'] != null
            ? (j['mods'] as List).cast<String>()
            : const [],
        avatarColor: j['color'] as int? ?? 0xFF5C6BC0,
        avatarEmoji: j['emoji'] as String? ?? '👥',
        avatarImagePath: j['img'] as String?,
        createdAt: j['ts'] as int? ?? 0,
      );

  String encode() => jsonEncode(toJson());

  static Group? tryDecode(String s) {
    try {
      return Group.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Group copyWith({
    String? name,
    List<String>? memberIds,
    List<String>? moderatorIds,
    int? avatarColor,
    String? avatarEmoji,
    String? avatarImagePath,
  }) =>
      Group(
        id: id,
        name: name ?? this.name,
        creatorId: creatorId,
        memberIds: memberIds ?? this.memberIds,
        moderatorIds: moderatorIds ?? this.moderatorIds,
        avatarColor: avatarColor ?? this.avatarColor,
        avatarEmoji: avatarEmoji ?? this.avatarEmoji,
        avatarImagePath: avatarImagePath ?? this.avatarImagePath,
        createdAt: createdAt,
      );
}

/// Сообщение в групповом чате.
class GroupMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String text;
  final String? imagePath;
  final String? videoPath;
  final String? voicePath;
  final bool isOutgoing;
  final int timestamp;

  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    this.text = '',
    this.imagePath,
    this.videoPath,
    this.voicePath,
    required this.isOutgoing,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'group_id': groupId,
        'sender_id': senderId,
        'text': text,
        'image_path': imagePath,
        'video_path': videoPath,
        'voice_path': voicePath,
        'is_outgoing': isOutgoing ? 1 : 0,
        'timestamp': timestamp,
      };

  factory GroupMessage.fromMap(Map<String, dynamic> m) => GroupMessage(
        id: m['id'] as String,
        groupId: m['group_id'] as String,
        senderId: m['sender_id'] as String,
        text: m['text'] as String? ?? '',
        imagePath: m['image_path'] as String?,
        videoPath: m['video_path'] as String?,
        voicePath: m['voice_path'] as String?,
        isOutgoing: (m['is_outgoing'] as int) == 1,
        timestamp: m['timestamp'] as int,
      );
}
