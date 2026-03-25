import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_profile.dart';

class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  static const _kProfileKey = 'rlink_user_profile';

  // On desktop (macOS/Windows/Linux) use SharedPreferences — Keychain is
  // mobile-only; on desktop it can fail silently in sandboxed environments.
  static bool get _isMobile => Platform.isIOS || Platform.isAndroid;

  final _secureSt = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<String?> _read() async {
    if (_isMobile) return _secureSt.read(key: _kProfileKey);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kProfileKey);
  }

  Future<void> _write(String value) async {
    if (_isMobile) {
      await _secureSt.write(key: _kProfileKey, value: value);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kProfileKey, value);
    }
  }

  UserProfile? _profile;
  UserProfile? get profile => _profile;
  bool get hasProfile => _profile != null;

  final profileNotifier = ValueNotifier<UserProfile?>(null);

  Future<void> init() async {
    final stored = await _read();
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

    await _write(profile.encode());
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
    await _write(updated.encode());
    _profile = updated;
    profileNotifier.value = updated;
    return updated;
  }
}
