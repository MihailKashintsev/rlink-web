import 'dart:convert';

import '../services/image_service.dart';

class UserProfile {
  final String publicKeyHex;
  final String nickname;
  final String username;         // уникальный юзернейм (как в Telegram)
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath; // локальный путь к фото аватара
  final List<String> tags;       // теги профиля (интересы)
  final String? bannerImagePath; // баннер профиля

  const UserProfile({
    required this.publicKeyHex,
    required this.nickname,
    this.username = '',
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    this.tags = const [],
    this.bannerImagePath,
  });

  String get initials {
    final parts = nickname.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';
  }

  String get shortId =>
      publicKeyHex.length > 8 ? publicKeyHex.substring(0, 8) : publicKeyHex;

  Map<String, dynamic> toJson() => {
        'id': publicKeyHex,
        'nick': nickname,
        if (username.isNotEmpty) 'u': username,
        'color': avatarColor,
        'emoji': avatarEmoji,
        if (avatarImagePath != null) 'imgPath': avatarImagePath,
        if (tags.isNotEmpty) 'tags': tags,
        if (bannerImagePath != null) 'bannerPath': bannerImagePath,
      };

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        publicKeyHex: j['id'] as String,
        nickname: j['nick'] as String,
        username: j['u'] as String? ?? '',
        avatarColor: j['color'] as int,
        avatarEmoji: j['emoji'] as String,
        avatarImagePath: ImageService.instance.resolveStoredPath(
            j['imgPath'] as String?),
        tags: (j['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
        bannerImagePath: ImageService.instance.resolveStoredPath(
            j['bannerPath'] as String?),
      );

  String encode() => jsonEncode(toJson());

  static UserProfile? tryDecode(String s) {
    try {
      return UserProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static const avatarColors = [
    0xFF5C6BC0,
    0xFF26A69A,
    0xFFEF5350,
    0xFFAB47BC,
    0xFF42A5F5,
    0xFF66BB6A,
    0xFFFF7043,
    0xFFEC407A,
  ];

  static const avatarEmojis = [
    '😎',
    '🥷',
    '🧙',
    '🧛',
    '🦊',
    '🐺',
    '🦁',
    '🐯',
    '🐻',
    '🐼',
    '🦄',
    '🐲',
    '👾',
    '🤖',
    '👻',
    '💀',
    '🔥',
    '⚡',
    '🌊',
    '💎',
    '🚀',
    '🎮',
    '🎸',
    '🏆',
    '🌙',
    '⭐',
    '🌈',
    '✨',
    '🔮',
    '🎯',
    '💥',
    '🌟',
  ];
}
