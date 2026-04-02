import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the list of blocked user public keys.
/// Blocked users cannot send messages or pair requests that are shown in the UI.
class BlockService {
  BlockService._();
  static final BlockService instance = BlockService._();

  static const _kKey = 'blocked_users';

  final blockedNotifier = ValueNotifier<Set<String>>({});

  Set<String> get blockedIds => blockedNotifier.value;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kKey) ?? [];
    blockedNotifier.value = Set<String>.from(list);
  }

  bool isBlocked(String publicKeyHex) => blockedNotifier.value.contains(publicKeyHex);

  Future<void> block(String publicKeyHex) async {
    if (isBlocked(publicKeyHex)) return;
    final updated = {...blockedNotifier.value, publicKeyHex};
    blockedNotifier.value = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kKey, updated.toList());
    debugPrint('[Block] Blocked: ${publicKeyHex.substring(0, 8)}...');
  }

  Future<void> unblock(String publicKeyHex) async {
    if (!isBlocked(publicKeyHex)) return;
    final updated = {...blockedNotifier.value}..remove(publicKeyHex);
    blockedNotifier.value = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kKey, updated.toList());
    debugPrint('[Block] Unblocked: ${publicKeyHex.substring(0, 8)}...');
  }

  Future<void> toggleBlock(String publicKeyHex) async {
    if (isBlocked(publicKeyHex)) {
      await unblock(publicKeyHex);
    } else {
      await block(publicKeyHex);
    }
  }
}
