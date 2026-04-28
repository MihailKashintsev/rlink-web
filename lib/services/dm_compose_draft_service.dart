import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_storage_service.dart';

/// Несохранённый текст из поля ввода личного чата (по peer_id).
class DmComposeDraftService {
  DmComposeDraftService._();
  static final DmComposeDraftService instance = DmComposeDraftService._();

  static const _prefix = 'rlink_dm_compose_draft_v1_';

  /// Инкремент при изменении черновиков — список чатов может подписаться.
  final ValueNotifier<int> revision = ValueNotifier(0);

  String _key(String peerId) =>
      '$_prefix${ChatStorageService.normalizeDmPeerId(peerId)}';

  Future<String?> getDraft(String peerId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_key(peerId));
  }

  /// Все ненулевые черновики: ключ — нормализованный peer_id.
  Future<Map<String, String>> getAllDrafts() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, String>{};
    for (final k in p.getKeys()) {
      if (!k.startsWith(_prefix)) continue;
      final pid = k.substring(_prefix.length);
      final v = p.getString(k);
      if (v != null && v.trim().isNotEmpty) {
        out[pid] = v;
      }
    }
    return out;
  }

  /// Пустая строка или только пробелы — удаляет черновик.
  Future<void> setDraft(String peerId, String text) async {
    final p = await SharedPreferences.getInstance();
    final k = _key(peerId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      if (p.containsKey(k)) {
        await p.remove(k);
        revision.value++;
      }
      return;
    }
    final prev = p.getString(k);
    if (prev == text) return;
    await p.setString(k, text);
    revision.value++;
  }
}
