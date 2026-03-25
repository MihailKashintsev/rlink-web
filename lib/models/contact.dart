import '../services/image_service.dart';

class Contact {
  final String publicKeyHex;
  final String nickname;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath; // локальный путь к фото аватара контакта
  final DateTime addedAt;
  final DateTime? lastSeen;

  const Contact({
    required this.publicKeyHex,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    required this.addedAt,
    this.lastSeen,
  });

  String get initials {
    final parts = nickname.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';
  }

  String get shortId =>
      publicKeyHex.length > 8 ? publicKeyHex.substring(0, 8) : publicKeyHex;

  Contact copyWith(
          {DateTime? lastSeen, String? nickname, String? avatarImagePath}) =>
      Contact(
        publicKeyHex: publicKeyHex,
        nickname: nickname ?? this.nickname,
        avatarColor: avatarColor,
        avatarEmoji: avatarEmoji,
        avatarImagePath: avatarImagePath ?? this.avatarImagePath,
        addedAt: addedAt,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toMap() => {
        'id': publicKeyHex,
        'nick': nickname,
        'color': avatarColor,
        'emoji': avatarEmoji,
        'avatar_img_path': avatarImagePath,
        'added_at': addedAt.millisecondsSinceEpoch,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
      };

  factory Contact.fromMap(Map<String, dynamic> m) => Contact(
        publicKeyHex: m['id'] as String,
        nickname: m['nick'] as String,
        avatarColor: m['color'] as int,
        avatarEmoji: m['emoji'] as String,
        // Resolve potentially stale iOS sandbox path
        avatarImagePath: ImageService.instance.resolveStoredPath(
            m['avatar_img_path'] as String?),
        addedAt: DateTime.fromMillisecondsSinceEpoch(m['added_at'] as int),
        lastSeen: m['last_seen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['last_seen'] as int)
            : null,
      );
}
