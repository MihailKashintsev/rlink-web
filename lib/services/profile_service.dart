import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_profile.dart';
import 'crypto_service.dart';
import 'runtime_platform.dart';
import 'web_account_bundle.dart';
import 'web_identity_portable.dart';

class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  static const _kProfileKey = 'rlink_user_profile';

  // On desktop (macOS/Windows/Linux) use SharedPreferences — Keychain is
  // mobile-only; on desktop it can fail silently in sandboxed environments.
  static bool get _isMobile => RuntimePlatform.isIos || RuntimePlatform.isAndroid;

  final _secureSt = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<String?> _read() async {
    if (RuntimePlatform.isWeb) {
      return WebAccountBundle.layeredRead(_kProfileKey);
    }
    if (_isMobile) return _secureSt.read(key: _kProfileKey);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kProfileKey);
  }

  Future<void> _write(String value) async {
    if (RuntimePlatform.isWeb) {
      await WebAccountBundle.layeredWrite(_kProfileKey, value);
      await WebAccountBundle.mergeProfileIntoBundle(value);
      unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs(
        profileJsonOverride: value,
      ));
      return;
    }
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
    var stored = await _read();
    if (stored == null && RuntimePlatform.isWeb) {
      stored = await WebAccountBundle.profileJsonFromBundle();
      if (stored != null && stored.isNotEmpty) {
        await WebAccountBundle.layeredWrite(_kProfileKey, stored);
      }
    }
    if (stored != null) {
      _profile = UserProfile.tryDecode(stored);
      // Sync publicKeyHex with the current CryptoService key —
      // if secure storage was cleared, the crypto key regenerated
      // but the profile still holds the old one.
      if (_profile != null) {
        final currentKey = CryptoService.instance.publicKeyHex;
        if (currentKey.isNotEmpty && _profile!.publicKeyHex != currentKey) {
          _profile = UserProfile(
            publicKeyHex: currentKey,
            nickname: _profile!.nickname,
            username: _profile!.username,
            avatarColor: _profile!.avatarColor,
            avatarEmoji: _profile!.avatarEmoji,
            avatarImagePath: _profile!.avatarImagePath,
            tags: _profile!.tags,
            bannerImagePath: _profile!.bannerImagePath,
            profileMusicPath: _profile!.profileMusicPath,
            statusEmoji: _profile!.statusEmoji,
          );
          await _write(_profile!.encode());
        }
      }
      profileNotifier.value = _profile;
    }
  }

  /// Clears the in-memory profile. Called during a full app reset so that
  /// [hasProfile] returns false and [profileNotifier] reflects the cleared state.
  void clearProfile() {
    _profile = null;
    profileNotifier.value = null;
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
    String? username,
    int? avatarColor,
    String? avatarEmoji,
    String? avatarImagePath,
    List<String>? tags,
    String? bannerImagePath,
    String? profileMusicPath,
    String? statusEmoji,
  }) async {
    if (_profile == null) throw StateError('No profile');
    // Always use the current CryptoService key to prevent divergence
    final currentKey = CryptoService.instance.publicKeyHex;
    final nextStatus = statusEmoji != null
        ? UserProfile.normalizeStatusEmoji(statusEmoji)
        : _profile!.statusEmoji;
    final updated = UserProfile(
      publicKeyHex: currentKey.isNotEmpty ? currentKey : _profile!.publicKeyHex,
      nickname: nickname ?? _profile!.nickname,
      username: username ?? _profile!.username,
      avatarColor: avatarColor ?? _profile!.avatarColor,
      avatarEmoji: avatarEmoji ?? _profile!.avatarEmoji,
      avatarImagePath: avatarImagePath ?? _profile!.avatarImagePath,
      tags: tags ?? _profile!.tags,
      bannerImagePath: bannerImagePath ?? _profile!.bannerImagePath,
      profileMusicPath: profileMusicPath ?? _profile!.profileMusicPath,
      statusEmoji: nextStatus,
    );
    await _write(updated.encode());
    _profile = updated;
    profileNotifier.value = updated;
    return updated;
  }
}
