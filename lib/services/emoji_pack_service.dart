import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/emoji_pack.dart';

/// Локальные наборы кастомных эмодзи: каталог [emoji_packs/], индекс [emoji_packs.json].
class EmojiPackService {
  EmojiPackService._();
  static final EmojiPackService instance = EmojiPackService._();

  final ValueNotifier<int> version = ValueNotifier(0);
  static const _jsonName = 'emoji_packs.json';
  static const _packDirName = 'emoji_packs';

  final _uuid = const Uuid();
  String? _docsRoot;

  /// shortcode (lower) → absolute path для синхронного рендера в [RichMessageText].
  final Map<String, String> _shortcodeToAbsPath = {};

  /// shortcode (lower) → исходный регистр shortcode + relPath
  final Map<String, CustomEmoji> _shortcodeToEmoji = {};

  Future<File> _packsFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File(p.join(d.path, _jsonName));
  }

  Future<Directory> _packsRootDir() async {
    final d = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(d.path, _packDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<void> ensureInitialized() async {
    final d = await getApplicationDocumentsDirectory();
    _docsRoot = d.path;
    final f = await _packsFile();
    if (!await f.exists()) {
      await f.writeAsString(EmojiPack.encodeList(const []));
    }
    await _packsRootDir();
    refreshIndexSync();
  }

  void refreshIndexSync() {
    final root = _docsRoot;
    _shortcodeToAbsPath.clear();
    _shortcodeToEmoji.clear();
    if (root == null) return;
    try {
      final f = File(p.join(root, _jsonName));
      if (!f.existsSync()) return;
      final packs = EmojiPack.decodeList(f.readAsStringSync());
      for (final pack in packs) {
        for (final e in pack.emojis) {
          final abs = p.join(root, e.relPath);
          if (!File(abs).existsSync()) continue;
          final k = e.shortcode.toLowerCase();
          if (_shortcodeToAbsPath.containsKey(k)) continue;
          _shortcodeToAbsPath[k] = abs;
          _shortcodeToEmoji[k] =
              CustomEmoji(shortcode: e.shortcode, relPath: e.relPath);
        }
      }
    } catch (_) {}
  }

  Future<List<EmojiPack>> _readPacksRaw() async {
    await ensureInitialized();
    final f = await _packsFile();
    if (!await f.exists()) return [];
    try {
      final raw = await f.readAsString();
      final list = EmojiPack.decodeList(raw);
      return await _pruneMissingFiles(list);
    } catch (_) {
      return [];
    }
  }

  Future<List<EmojiPack>> _pruneMissingFiles(List<EmojiPack> packs) async {
    final docs = await getApplicationDocumentsDirectory();
    var changed = false;
    final out = <EmojiPack>[];
    for (final pack in packs) {
      final keep = <CustomEmoji>[];
      for (final e in pack.emojis) {
        if (File(p.join(docs.path, e.relPath)).existsSync()) {
          keep.add(e);
        } else {
          changed = true;
        }
      }
      out.add(EmojiPack(
        id: pack.id,
        name: pack.name,
        emojis: keep,
        sourcePeerId: pack.sourcePeerId,
      ));
    }
    if (changed) {
      await _writePacks(out);
    }
    return out;
  }

  Future<void> _writePacks(List<EmojiPack> packs) async {
    final f = await _packsFile();
    await f.writeAsString(EmojiPack.encodeList(packs));
    refreshIndexSync();
    version.value++;
  }

  Future<void> warmIndex() async {
    await ensureInitialized();
    refreshIndexSync();
  }

  Future<List<EmojiPack>> loadPacks() => _readPacksRaw();

  Future<EmojiPack?> packById(String id) async {
    final packs = await _readPacksRaw();
    for (final e in packs) {
      if (e.id == id) return e;
    }
    return null;
  }

  CustomEmoji? lookupByShortcode(String shortcode) {
    final k = shortcode.trim().toLowerCase();
    if (k.isEmpty) return null;
    final em = _shortcodeToEmoji[k];
    if (em == null) return null;
    final abs = _shortcodeToAbsPath[k];
    if (abs == null || !File(abs).existsSync()) return null;
    return em;
  }

  Future<List<EmojiPack>> packsContainingShortcode(String shortcode) async {
    final sc = shortcode.trim().toLowerCase();
    if (sc.isEmpty) return const [];
    final packs = await _readPacksRaw();
    final out = <EmojiPack>[];
    for (final pack in packs) {
      if (pack.emojis.any((e) => e.shortcode.toLowerCase() == sc)) {
        out.add(pack);
      }
    }
    return out;
  }

  String? absolutePathForShortcode(String shortcode) {
    final k = shortcode.trim().toLowerCase();
    final abs = _shortcodeToAbsPath[k];
    if (abs == null || !File(abs).existsSync()) return null;
    return abs;
  }

  Future<String?> absolutePathForEmoji(CustomEmoji e) async {
    final docs = await getApplicationDocumentsDirectory();
    final abs = p.join(docs.path, e.relPath);
    if (File(abs).existsSync()) return abs;
    return null;
  }

  Future<Uint8List?> readEmojiBytesByShortcode(String shortcode) async {
    await ensureInitialized();
    final abs = absolutePathForShortcode(shortcode);
    if (abs == null) return null;
    final f = File(abs);
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  Future<String> createPack({
    required String name,
    String? sourcePeerId,
  }) async {
    await ensureInitialized();
    final packs = await _readPacksRaw();
    final id = _uuid.v4();
    final root = await _packsRootDir();
    Directory(p.join(root.path, id)).createSync(recursive: true);
    final n = name.trim().isEmpty ? 'Набор' : name.trim();
    packs.insert(
      0,
      EmojiPack(
        id: id,
        name: n,
        emojis: const [],
        sourcePeerId: sourcePeerId,
      ),
    );
    await _writePacks(packs);
    return id;
  }

  Future<void> renamePack(String packId, String newName) async {
    final packs = await _readPacksRaw();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final n = newName.trim().isEmpty ? p0.name : newName.trim();
    packs[i] = EmojiPack(
      id: p0.id,
      name: n,
      emojis: p0.emojis,
      sourcePeerId: p0.sourcePeerId,
    );
    await _writePacks(packs);
  }

  Future<void> addEmoji({
    required String packId,
    required String shortcode,
    required String absoluteImagePath,
  }) async {
    final sc = _normalizeShortcode(shortcode);
    if (sc == null) {
      throw ArgumentError('invalid shortcode');
    }
    final src = File(absoluteImagePath);
    if (!src.existsSync()) {
      throw StateError('image missing');
    }
    final docs = await getApplicationDocumentsDirectory();
    final ext = p.extension(src.path);
    final safeExt =
        (ext.isNotEmpty && ext.length <= 6) ? ext.toLowerCase() : '.png';
    final name = '${_uuid.v4()}$safeExt';
    final rel = p.join(_packDirName, packId, name);
    final dest = File(p.join(docs.path, rel));
    dest.parent.createSync(recursive: true);
    await src.copy(dest.path);

    final packs = await _readPacksRaw();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) {
      try {
        await dest.delete();
      } catch (_) {}
      throw StateError('pack not found');
    }
    final p0 = packs[i];
    final emojis = List<CustomEmoji>.from(p0.emojis)
      ..removeWhere((e) => e.shortcode.toLowerCase() == sc.toLowerCase());
    emojis.add(CustomEmoji(shortcode: sc, relPath: rel));
    packs[i] = EmojiPack(
      id: p0.id,
      name: p0.name,
      emojis: emojis,
      sourcePeerId: p0.sourcePeerId,
    );
    await _writePacks(packs);
  }

  String? _normalizeShortcode(String raw) {
    var s = raw.trim();
    if (s.startsWith(':') && s.endsWith(':') && s.length >= 2) {
      s = s.substring(1, s.length - 1).trim();
    }
    if (s.isEmpty || s.length > 48) return null;
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(s)) return null;
    return s;
  }

  Future<void> deleteEmoji(String packId, String shortcode) async {
    final sc = shortcode.trim().toLowerCase();
    final packs = await _readPacksRaw();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final docs = await getApplicationDocumentsDirectory();
    CustomEmoji? removed;
    final emojis = <CustomEmoji>[];
    for (final e in p0.emojis) {
      if (e.shortcode.toLowerCase() == sc) {
        removed = e;
      } else {
        emojis.add(e);
      }
    }
    if (removed != null) {
      try {
        final f = File(p.join(docs.path, removed.relPath));
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
    packs[i] = EmojiPack(
      id: p0.id,
      name: p0.name,
      emojis: emojis,
      sourcePeerId: p0.sourcePeerId,
    );
    await _writePacks(packs);
  }

  Future<void> deletePack(String packId) async {
    final docs = await getApplicationDocumentsDirectory();
    final packs = await _readPacksRaw();
    final kept = <EmojiPack>[];
    for (final e in packs) {
      if (e.id == packId) {
        for (final em in e.emojis) {
          try {
            final f = File(p.join(docs.path, em.relPath));
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
        try {
          final dir = Directory(p.join(docs.path, _packDirName, packId));
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } catch (_) {}
        continue;
      }
      kept.add(e);
    }
    await _writePacks(kept);
  }

  /// Карточка чата: [payload] с `type`/`kind` = emoji_pack, name, emojis: [{shortcode, data}] (base64).
  Future<String?> installFromSharePayload(Map<String, dynamic> payload) async {
    await ensureInitialized();
    final name = (payload['name'] as String?)?.trim().isNotEmpty == true
        ? (payload['name'] as String).trim()
        : 'Набор';
    final rawEmojis = (payload['emojis'] as List?) ?? const [];
    if (rawEmojis.isEmpty) return null;

    final packId = _uuid.v4();
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _packDirName, packId));
    dir.createSync(recursive: true);

    final built = <CustomEmoji>[];
    final seenShortcodes = <String>{};
    for (final e in rawEmojis) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final scRaw = (m['shortcode'] as String? ?? '').trim();
      final b64 = m['data'] as String? ?? m['imageBase64'] as String? ?? '';
      if (scRaw.isEmpty || b64.isEmpty) continue;
      final List<int> bytes;
      try {
        bytes = base64Decode(b64);
      } catch (_) {
        continue;
      }
      if (bytes.isEmpty) continue;
      final norm = _normalizeShortcode(scRaw);
      if (norm == null) continue;
      if (!seenShortcodes.add(norm)) continue;
      final fileName = '${_uuid.v4()}.png';
      final rel = p.join(_packDirName, packId, fileName);
      final dest = File(p.join(docs.path, rel));
      await dest.writeAsBytes(bytes, flush: true);
      built.add(CustomEmoji(shortcode: norm, relPath: rel));
    }
    if (built.isEmpty) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
      return null;
    }

    final packs = await _readPacksRaw();
    packs.insert(
      0,
      EmojiPack(
        id: packId,
        name: name,
        emojis: built,
        sourcePeerId: payload['sourcePeerId'] as String?,
      ),
    );
    await _writePacks(packs);
    return packId;
  }

  /// Авто-импорт эмодзи от пира (служебный payload relay blob).
  Future<int> installFromAutoPayload(
    Map<String, dynamic> payload, {
    required String sourcePeerId,
  }) async {
    await ensureInitialized();
    final rawEmojis = (payload['emojis'] as List?) ?? const [];
    if (rawEmojis.isEmpty) return 0;

    final packs = await _readPacksRaw();
    String? packId;
    for (final p0 in packs) {
      if (p0.sourcePeerId == sourcePeerId && p0.name == 'Автоимпорт') {
        packId = p0.id;
        break;
      }
    }
    packId ??= await createPack(name: 'Автоимпорт', sourcePeerId: sourcePeerId);

    final tmpDir = await getTemporaryDirectory();
    var n = 0;
    for (final e in rawEmojis) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final scRaw = (m['shortcode'] as String? ?? '').trim();
      final b64 = (m['data'] as String? ?? '').trim();
      if (scRaw.isEmpty || b64.isEmpty) continue;
      final norm = _normalizeShortcode(scRaw);
      if (norm == null) continue;
      List<int> bytes;
      try {
        bytes = base64Decode(b64);
      } catch (_) {
        continue;
      }
      if (bytes.isEmpty) continue;
      final tmp = File(p.join(tmpDir.path, 'emoji_auto_${_uuid.v4()}.png'));
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        await addEmoji(
          packId: packId,
          shortcode: norm,
          absoluteImagePath: tmp.path,
        );
        n++;
      } catch (_) {
      } finally {
        try {
          if (tmp.existsSync()) await tmp.delete();
        } catch (_) {}
      }
    }
    if (n > 0) {
      refreshIndexSync();
      version.value++;
    }
    return n;
  }
}
