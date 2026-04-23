import '../services/image_service.dart';
import 'user_profile.dart';

class Contact {
  final String publicKeyHex;
  final String nickname;
  final String username;             // юзернейм контакта (как в Telegram)
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath; // локальный путь к фото аватара контакта
  final String? x25519Key; // X25519 public key (base64) for E2E encryption
  final DateTime addedAt;
  final DateTime? lastSeen;
  final List<String> tags;           // теги из профиля контакта
  final String? bannerImagePath;     // баннер профиля контакта
  /// Локальный путь к треку «музыка в профиле» (после приёма с ретранслятора/BLE).
  final String? profileMusicPath;
  /// Эмодзи-статус из профиля контакта (gossip `st`).
  final String statusEmoji;

  const Contact({
    required this.publicKeyHex,
    required this.nickname,
    this.username = '',
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    this.x25519Key,
    required this.addedAt,
    this.lastSeen,
    this.tags = const [],
    this.bannerImagePath,
    this.profileMusicPath,
    this.statusEmoji = '',
  });

  String get initials {
    final parts = nickname.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';
  }

  String get shortId =>
      publicKeyHex.length > 8 ? publicKeyHex.substring(0, 8) : publicKeyHex;

  Contact copyWith({
    DateTime? lastSeen,
    String? nickname,
    String? username,
    String? avatarImagePath,
    bool setAvatarImagePath = false,
    String? x25519Key,
    List<String>? tags,
    String? bannerImagePath,
    bool setBannerImagePath = false,
    String? profileMusicPath,
    bool setProfileMusicPath = false,
    String? statusEmoji,
    int? avatarColor,
    String? avatarEmoji,
  }) =>
      Contact(
        publicKeyHex: publicKeyHex,
        nickname: nickname ?? this.nickname,
        username: username ?? this.username,
        avatarColor: avatarColor ?? this.avatarColor,
        avatarEmoji: avatarEmoji ?? this.avatarEmoji,
        avatarImagePath:
            setAvatarImagePath ? avatarImagePath : this.avatarImagePath,
        x25519Key: x25519Key ?? this.x25519Key,
        addedAt: addedAt,
        lastSeen: lastSeen ?? this.lastSeen,
        tags: tags ?? this.tags,
        bannerImagePath:
            setBannerImagePath ? bannerImagePath : this.bannerImagePath,
        profileMusicPath:
            setProfileMusicPath ? profileMusicPath : this.profileMusicPath,
        statusEmoji: statusEmoji ?? this.statusEmoji,
      );

  Map<String, dynamic> toMap() => {
        'id': publicKeyHex,
        'nick': nickname,
        'username': username.isEmpty ? null : username,
        'color': avatarColor,
        'emoji': avatarEmoji,
        'avatar_img_path': avatarImagePath,
        'x25519_key': x25519Key,
        'added_at': addedAt.millisecondsSinceEpoch,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
        'tags': tags.isEmpty ? null : tags.join(','),
        'banner_img_path': bannerImagePath,
        'profile_music_path': profileMusicPath,
        'status_emoji': statusEmoji.isEmpty ? null : statusEmoji,
      };

  factory Contact.fromMap(Map<String, dynamic> m) => Contact(
        publicKeyHex: m['id'] as String,
        nickname: m['nick'] as String,
        username: m['username'] as String? ?? '',
        avatarColor: m['color'] as int,
        avatarEmoji: m['emoji'] as String,
        // Resolve potentially stale iOS sandbox path
        avatarImagePath: ImageService.instance.resolveStoredPath(
            m['avatar_img_path'] as String?),
        x25519Key: m['x25519_key'] as String?,
        addedAt: DateTime.fromMillisecondsSinceEpoch(m['added_at'] as int),
        lastSeen: m['last_seen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['last_seen'] as int)
            : null,
        tags: (m['tags'] as String?)
                ?.split(',')
                .where((t) => t.isNotEmpty)
                .toList() ??
            const [],
        bannerImagePath: ImageService.instance.resolveStoredPath(
            m['banner_img_path'] as String?),
        profileMusicPath: ImageService.instance.resolveStoredPath(
            m['profile_music_path'] as String?),
        statusEmoji: UserProfile.normalizeStatusEmoji(
            (m['status_emoji'] as String?) ?? ''),
      );
}
