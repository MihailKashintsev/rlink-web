import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Сколько байт сырых данных помещается в один img_chunk-пакет.
/// 90 байт → 120 байт base64. Итого JSON ≈ 274 байт < BLE MTU 290 байт.
/// (overhead: id36+type+ttl+ts+msgId36+idx = ~154 байт; без rid и from)
const kImgChunkBytes = 90;

class ImageService {
  ImageService._();
  static final ImageService instance = ImageService._();

  final _uuid = const Uuid();
  final Map<String, _ImageAssembly> _assemblies = {};

  // ── Сохранение и сжатие ──────────────────────────────────────

  /// Сжимает изображение и сохраняет в <documents>/images/.
  /// [isAvatar] = true: жёсткое сжатие 256×256 px; иначе — чат-качество.
  Future<String> compressAndSave(
    String sourcePath, {
    bool isAvatar = false,
  }) async {
    final dir = await _imagesDir();
    final name = '${_uuid.v4()}.jpg';
    final targetPath = p.join(dir.path, name);

    // Chat images: 320×320 quality 55 ≈ 15–30 KB → ~220 BLE chunks → ~7 seconds transfer.
    // Avatar images: 192×192 quality 60 ≈ 8–15 KB → ~120 chunks → ~4 seconds transfer.
    final result = await FlutterImageCompress.compressAndGetFile(
      sourcePath,
      targetPath,
      minWidth: isAvatar ? 192 : 320,
      minHeight: isAvatar ? 192 : 320,
      quality: isAvatar ? 60 : 55,
      format: CompressFormat.jpeg,
    );

    if (result == null) {
      // fallback: просто копируем
      await File(sourcePath).copy(targetPath);
      return targetPath;
    }
    return result.path;
  }

  /// Сохраняет аватар контакта по его publicKeyHex (перезаписывает).
  Future<String> saveContactAvatar(String publicKeyHex, Uint8List data) async {
    final dir = await _imagesDir();
    final name = 'avatar_${publicKeyHex.substring(0, 16)}.jpg';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(data);
    return path;
  }

  // ── Разбивка на чанки ─────────────────────────────────────────

  List<String> splitToBase64Chunks(Uint8List data) {
    final chunks = <String>[];
    int offset = 0;
    while (offset < data.length) {
      final end = (offset + kImgChunkBytes).clamp(0, data.length);
      final slice = data.sublist(offset, end);
      chunks.add(base64Encode(slice));
      offset = end;
    }
    return chunks;
  }

  // ── Сборка на приёмнике ───────────────────────────────────────

  void receiveChunk({
    required String msgId,
    required int totalChunks,
    required int index,
    required String base64Data,
  }) {
    // Only add to existing assembly — if img_meta was filtered (not for us),
    // there's no assembly and we silently drop the chunk.
    final assembly = _assemblies[msgId];
    if (assembly == null) return;
    assembly.add(index, base64Decode(base64Data));
  }

  bool isComplete(String msgId) => _assemblies[msgId]?.isComplete ?? false;

  /// Собирает, сохраняет на диск и возвращает путь.
  /// [forContactKey] — если задан, пишет в avatar_<short>.jpg.
  Future<String?> assembleAndSave(
    String msgId, {
    String? forContactKey,
  }) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;

    final data = assembly.assemble();
    final dir = await _imagesDir();
    final name = forContactKey != null
        ? 'avatar_${forContactKey.substring(0, 16)}.jpg'
        : '${_uuid.v4()}.jpg';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(data);
    return path;
  }

  /// Инициализирует сборку до прихода первого чанка (вызывается из onImgMeta).
  void initAssembly(String msgId, int totalChunks,
      {bool isAvatar = false,
      bool isVoice = false,
      bool isVideo = false,
      bool isSquare = false,
      String fromId = ''}) {
    _assemblies.putIfAbsent(
      msgId,
      () => _ImageAssembly(
        totalChunks: totalChunks,
        isAvatar: isAvatar,
        isVoice: isVoice,
        isVideo: isVideo,
        isSquare: isSquare,
        fromId: fromId,
      ),
    );
  }

  bool isAvatarAssembly(String msgId) => _assemblies[msgId]?.isAvatar ?? false;
  bool isVoiceAssembly(String msgId) => _assemblies[msgId]?.isVoice ?? false;
  bool isVideoAssembly(String msgId) => _assemblies[msgId]?.isVideo ?? false;
  bool isSquareAssembly(String msgId) => _assemblies[msgId]?.isSquare ?? false;
  String assemblyFromId(String msgId) => _assemblies[msgId]?.fromId ?? '';

  void cancelAssembly(String msgId) => _assemblies.remove(msgId);

  /// Собирает голосовое сообщение и сохраняет как .m4a в voices/.
  Future<String?> assembleAndSaveVoice(String msgId) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;
    final data = assembly.assemble();
    final dir = await _voicesDir();
    final path = p.join(dir.path, '$msgId.m4a');
    await File(path).writeAsBytes(data);
    return path;
  }

  // ── Helpers ───────────────────────────────────────────────────

  Future<Directory> _imagesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'images'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Directory> _voicesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'voices'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Directory> _videosDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'videos'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String> saveVideo(String sourcePath, {bool isSquare = false}) async {
    final dir = await _videosDir();
    final suffix = isSquare ? '_sq' : '';
    final name = '${_uuid.v4()}$suffix.mp4';
    final targetPath = p.join(dir.path, name);
    await File(sourcePath).copy(targetPath);
    return targetPath;
  }

  Future<String?> assembleAndSaveVideo(String msgId, {bool isSquare = false}) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;
    final data = assembly.assemble();
    final dir = await _videosDir();
    final suffix = isSquare ? '_sq' : '';
    final path = p.join(dir.path, '$msgId$suffix.mp4');
    await File(path).writeAsBytes(data);
    return path;
  }
}

class _ImageAssembly {
  final int totalChunks;
  final bool isAvatar;
  final bool isVoice;
  final bool isVideo;
  final bool isSquare;
  final String fromId;
  final Map<int, Uint8List> _chunks = {};

  _ImageAssembly({
    required this.totalChunks,
    this.isAvatar = false,
    this.isVoice = false,
    this.isVideo = false,
    this.isSquare = false,
    this.fromId = '',
  });

  void add(int index, Uint8List data) => _chunks[index] = data;

  bool get isComplete => _chunks.length == totalChunks;

  Uint8List assemble() {
    final out = BytesBuilder();
    for (var i = 0; i < totalChunks; i++) {
      out.add(_chunks[i]!);
    }
    return out.toBytes();
  }
}
