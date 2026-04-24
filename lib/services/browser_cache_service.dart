import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Browser-local persistence helpers for web embedding mode.
class BrowserCacheService {
  BrowserCacheService._();
  static final BrowserCacheService instance = BrowserCacheService._();

  static const _kLocalAccountId = 'web_local_account_id';
  final _uuid = const Uuid();

  String? _localAccountId;
  String? get localAccountId => _localAccountId;

  Future<void> init() async {
    if (!kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    var id = (prefs.getString(_kLocalAccountId) ?? '').trim();
    if (id.isEmpty) {
      id = _uuid.v4();
      await prefs.setString(_kLocalAccountId, id);
    }
    _localAccountId = id;
  }
}
