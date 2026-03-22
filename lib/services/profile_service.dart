import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/user_profile.dart';

class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  static const _kProfileKey = 'rlink_user_profile';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  UserProfile? _profile;
  UserProfile? get profile => _profile;
  bool get hasProfile => _profile != null;

  final profileNotifier = ValueNotifier<UserProfile?>(null);

  Future<void> init() async {
    final stored = await _storage.read(key: _kProfileKey);
    if (stored != null) {
      _profile = UserProfile.tryDecode(stored);
      profileNotifier.value = _profile;
    }
  }

  Future<UserProfile> createProfile({
    required String publicKeyHex,
    required String nickname,
  }) async {
    final rng = Random();
    final color =
        UserProfile.avatarColors[rng.nextInt(UserProfile.avatarColors.length)];
    final emoji =
        UserProfile.avatarEmojis[rng.nextInt(UserProfile.avatarEmojis.length)];

    final profile = UserProfile(
      publicKeyHex: publicKeyHex,
      nickname: nickname.trim(),
      avatarColor: color,
      avatarEmoji: emoji,
    );

    await _storage.write(key: _kProfileKey, value: profile.encode());
    _profile = profile;
    profileNotifier.value = profile;
    return profile;
  }

  Future<UserProfile> updateProfile({
    String? nickname,
    int? avatarColor,
    String? avatarEmoji,
    String? avatarImagePath,
  }) async {
    if (_profile == null) throw StateError('No profile');
    final updated = UserProfile(
      publicKeyHex: _profile!.publicKeyHex,
      nickname: nickname ?? _profile!.nickname,
      avatarColor: avatarColor ?? _profile!.avatarColor,
      avatarEmoji: avatarEmoji ?? _profile!.avatarEmoji,
      avatarImagePath: avatarImagePath ?? _profile!.avatarImagePath,
    );
    await _storage.write(key: _kProfileKey, value: updated.encode());
    _profile = updated;
    profileNotifier.value = updated;
    return updated;
  }
}
