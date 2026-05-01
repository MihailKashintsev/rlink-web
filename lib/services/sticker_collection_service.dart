import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/sticker_pack.dart';

/// Локальная коллекция стикеров (свои и добавленные из чатов): пути `images/stk_*`.
/// Наборы — [StickerPack] в `sticker_packs.json`.
class StickerCollectionService {
  StickerCollectionService._();
  static final StickerCollectionService instance = StickerCollectionService._();

  final ValueNotifier<int> version = ValueNotifier(0);
  static const _jsonName = 'sticker_collection.json';
  static const _packsJsonName = 'sticker_packs.json';
  static const _defaultPackAssetPrefix = 'assets/sticker_packs/default/';
  static const _defaultPackAssetNames = <String>[
    'sticker_01.png',
    'sticker_02.png',
    'sticker_03.png',
    'sticker_04.png',
    'sticker_05.png',
    'sticker_06.png',
    'sticker_07.png',
    'sticker_08.png',
    'sticker_09.png',
    'sticker_10.png',
    'sticker_11.png',
    'sticker_12.png',
  ];
  final _uuid = const Uuid();

  /// Инициализация коллекции и подстановка встроенного набора при пустом списке.
  Future<void> init() async {
    await ensureInitialized();
    await _seedDefaultPackIfEmpty();
  }

  Future<void> _seedDefaultPackIfEmpty() async {
    final packs = await _readPacks();
    if (packs.isNotEmpty) return;

    final docs = await getApplicationDocumentsDirectory();
    final imgDir = Directory(p.join(docs.path, 'images'));
    if (!imgDir.existsSync()) imgDir.createSync(recursive: true);

    final rels = <String>[];
    for (final name in _defaultPackAssetNames) {
      try {
        final data =
            await rootBundle.load('$_defaultPackAssetPrefix$name');
        final destName =
            'stk_default_${name.replaceAll('.png', '').replaceAll('.webp', '')}${p.extension(name)}';
        final dest = File(p.join(imgDir.path, destName));
        await dest.writeAsBytes(data.buffer.asUint8List());
        rels.add(p.join('images', destName));
      } catch (e, st) {
        debugPrint('[Stickers] default asset $name: $e\n$st');
      }
    }
    if (rels.isEmpty) return;

    await createPack(
      title: 'Rlink',
      relPaths: rels,
    );
    debugPrint('[Stickers] seeded default pack (${rels.length} files)');
  }

  Future<File> _jsonFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File(p.join(d.path, _jsonName));
  }

  Future<File> _packsFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File(p.join(d.path, _packsJsonName));
  }

  Future<void> ensureInitialized() async {
    final f = await _jsonFile();
    if (!await f.exists()) {
      await syncFromDisk();
    }
    final pf = await _packsFile();
    if (!await pf.exists()) {
      await _writePacks(const []);
    }
  }

  Future<List<String>> _readList() async {
    final f = await _jsonFile();
    if (!await f.exists()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeList(List<String> relPaths) async {
    final f = await _jsonFile();
    await f.writeAsString(jsonEncode(relPaths));
    version.value++;
  }

  Future<List<StickerPack>> _readPacks() async {
    await ensureInitialized();
    final f = await _packsFile();
    if (!await f.exists()) return [];
    try {
      final raw = await f.readAsString();
      final list = StickerPack.decodeList(raw);
      final pruned = await _prunePackPaths(list);
      if (!_packListsEqual(list, pruned)) {
        await _writePacksRaw(pruned);
      }
      return pruned;
    } catch (_) {
      return [];
    }
  }

  bool _packListsEqual(List<StickerPack> a, List<StickerPack> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
      if (a[i].stickerRelPaths.length != b[i].stickerRelPaths.length) {
        return false;
      }
    }
    return true;
  }

  Future<void> _writePacksRaw(List<StickerPack> packs) async {
    final f = await _packsFile();
    await f.writeAsString(StickerPack.encodeList(packs));
    version.value++;
  }

  Future<void> _writePacks(List<StickerPack> packs) async {
    await _writePacksRaw(packs);
  }

  Future<List<StickerPack>> _prunePackPaths(List<StickerPack> packs) async {
    final docs = await getApplicationDocumentsDirectory();
    var changed = false;
    final out = <StickerPack>[];
    for (final pack in packs) {
      final keep = <String>[];
      for (final rel in pack.stickerRelPaths) {
        if (File(p.join(docs.path, rel)).existsSync()) {
          keep.add(rel);
        } else {
          changed = true;
        }
      }
      out.add(StickerPack(
        id: pack.id,
        title: pack.title,
        createdAtMs: pack.createdAtMs,
        stickerRelPaths: keep,
        sourcePeerId: pack.sourcePeerId,
        sourcePeerLabel: pack.sourcePeerLabel,
      ));
    }
    if (changed) {
      debugPrint('[Stickers] pruned missing files from packs');
    }
    return out;
  }

  /// Пути относительно каталога документов приложения.
  Future<List<String>> relativePathsValid() async {
    final docs = await getApplicationDocumentsDirectory();
    final raw = await _readList();
    final out = <String>[];
    for (final rel in raw) {
      if (File(p.join(docs.path, rel)).existsSync()) out.add(rel);
    }
    if (out.length != raw.length) {
      await _writeList(out);
    }
    return out;
  }

  Future<List<File>> stickerFilesNewestFirst() async {
    final docs = await getApplicationDocumentsDirectory();
    final rels = await relativePathsValid();
    final files = <File>[];
    for (final r in rels) {
      final f = File(p.join(docs.path, r));
      if (f.existsSync()) files.add(f);
    }
    files.sort((a, b) =>
        b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// Файлы набора по порядку; [packId] == null — все стикеры (как [stickerFilesNewestFirst]).
  Future<List<File>> stickerFilesForPack(String? packId) async {
    if (packId == null || packId.isEmpty) {
      return stickerFilesNewestFirst();
    }
    final packs = await _readPacks();
    StickerPack? pack;
    for (final e in packs) {
      if (e.id == packId) {
        pack = e;
        break;
      }
    }
    if (pack == null) return stickerFilesNewestFirst();
    final docs = await getApplicationDocumentsDirectory();
    final files = <File>[];
    for (final rel in pack.stickerRelPaths) {
      final f = File(p.join(docs.path, rel));
      if (f.existsSync()) files.add(f);
    }
    return files;
  }

  Future<List<StickerPack>> loadPacks() => _readPacks();

  Future<StickerPack?> packById(String id) async {
    final packs = await _readPacks();
    for (final e in packs) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Подтянуть в JSON все `images/stk_*` с диска.
  Future<void> syncFromDisk() async {
    final docs = await getApplicationDocumentsDirectory();
    final imgDir = Directory(p.join(docs.path, 'images'));
    final fromDisk = <String>{};
    if (imgDir.existsSync()) {
      for (final e in imgDir.listSync()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name.startsWith('stk_')) {
          fromDisk.add(p.join('images', name));
        }
      }
    }
    final merged = {...await _readList(), ...fromDisk}.toList()..sort();
    await _writeList(merged);
  }

  Future<String> _ensureRelForAbsolute(String absPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final norm = p.normalize(absPath);
    if (!File(norm).existsSync()) {
      throw StateError('file missing');
    }
    late final String rel;
    if (norm.startsWith(docs.path)) {
      rel = p.relative(norm, from: docs.path);
    } else {
      final destDir = Directory(p.join(docs.path, 'images'));
      if (!destDir.existsSync()) destDir.createSync(recursive: true);
      final ext = p.extension(norm);
      final safeExt =
          (ext.isNotEmpty && ext.length <= 6) ? ext.toLowerCase() : '.jpg';
      final name = 'stk_${_uuid.v4()}$safeExt';
      final dest = File(p.join(destDir.path, name));
      await File(norm).copy(dest.path);
      rel = p.join('images', name);
    }
    final list = await _readList();
    if (!list.contains(rel)) {
      list.insert(0, rel);
      await _writeList(list);
    } else {
      version.value++;
    }
    return rel;
  }

  /// Зарегистрировать файл стикера (уже в sandbox или скопировать в `images/stk_*`).
  Future<void> registerAbsoluteStickerPath(String absPath) async {
    await _ensureRelForAbsolute(absPath);
  }

  Future<void> importChatImageToCollection(String imageAbsPath) async {
    if (!File(imageAbsPath).existsSync()) return;
    await registerAbsoluteStickerPath(imageAbsPath);
  }

  /// Создать набор. [relPaths] — относительные пути; несуществующие отфильтровываются.
  Future<String> createPack({
    required String title,
    List<String> relPaths = const [],
    String? sourcePeerId,
    String? sourcePeerLabel,
  }) async {
    await ensureInitialized();
    final docs = await getApplicationDocumentsDirectory();
    final packs = await _readPacks();
    final id = _uuid.v4();
    final seen = <String>{};
    final valid = <String>[];
    for (final r in relPaths) {
      if (seen.contains(r)) continue;
      if (File(p.join(docs.path, r)).existsSync()) {
        valid.add(r);
        seen.add(r);
      }
    }
    final t = title.trim().isEmpty ? 'Набор' : title.trim();
    packs.insert(
      0,
      StickerPack(
        id: id,
        title: t,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        stickerRelPaths: valid,
        sourcePeerId: sourcePeerId,
        sourcePeerLabel: sourcePeerLabel,
      ),
    );
    await _writePacks(packs);
    return id;
  }

  Future<void> deletePack(String packId) async {
    final packs = await _readPacks();
    packs.removeWhere((e) => e.id == packId);
    await _writePacks(packs);
  }

  Future<void> renamePack(String packId, String newTitle) async {
    final packs = await _readPacks();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final t = newTitle.trim().isEmpty ? p0.title : newTitle.trim();
    packs[i] = StickerPack(
      id: p0.id,
      title: t,
      createdAtMs: p0.createdAtMs,
      stickerRelPaths: p0.stickerRelPaths,
      sourcePeerId: p0.sourcePeerId,
      sourcePeerLabel: p0.sourcePeerLabel,
    );
    await _writePacks(packs);
  }

  Future<void> setPackStickerRels(String packId, List<String> relPaths) async {
    final docs = await getApplicationDocumentsDirectory();
    final packs = await _readPacks();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final seen = <String>{};
    final valid = <String>[];
    for (final r in relPaths) {
      if (seen.contains(r)) continue;
      if (File(p.join(docs.path, r)).existsSync()) {
        valid.add(r);
        seen.add(r);
      }
    }
    packs[i] = StickerPack(
      id: p0.id,
      title: p0.title,
      createdAtMs: p0.createdAtMs,
      stickerRelPaths: valid,
      sourcePeerId: p0.sourcePeerId,
      sourcePeerLabel: p0.sourcePeerLabel,
    );
    await _writePacks(packs);
  }

  /// Импорт копий в галерею + новый набор (стикеры от контакта).
  Future<String> importPackFromAbsolutePaths({
    required String title,
    required List<String> absPaths,
    String? sourcePeerId,
    String? sourcePeerLabel,
  }) async {
    final rels = <String>[];
    for (final a in absPaths) {
      try {
        rels.add(await _ensureRelForAbsolute(a));
      } catch (_) {}
    }
    return createPack(
      title: title,
      relPaths: rels,
      sourcePeerId: sourcePeerId,
      sourcePeerLabel: sourcePeerLabel,
    );
  }

  /// Относительный путь для файла внутри sandbox (без копирования).
  Future<String?> relativePathIfInAppDocs(String absPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final norm = p.normalize(absPath);
    if (!norm.startsWith(docs.path)) return null;
    return p.relative(norm, from: docs.path);
  }
}
