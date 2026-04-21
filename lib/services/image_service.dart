import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:video_compress/video_compress.dart';
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
  /// Track completed assemblies to prevent duplicate processing
  /// when both blob and gossip chunks deliver the same msgId.
  final Set<String> _completedMsgIds = {};
  static const _kMaxCompletedTracked = 500;

  /// Cached documents directory path — set during init().
  /// Used by resolveStoredPath() to fix stale iOS sandbox paths after rebuild.
  String? _docsPath;

  /// Must be called once at startup (before any path resolution).
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _docsPath = dir.path;
  }

  /// Resolves a stored file path that may have become stale after a rebuild or
  /// app reinstall.
  ///
  /// - iOS changes the sandbox UUID on each Xcode install, so absolute paths
  ///   saved in the DB are remapped via the '/Documents/' marker.
  /// - Android changes the app data directory on reinstall; paths are remapped
  ///   by trying the current documents directory with the same filename/subpath.
  ///
  /// Handles both old absolute paths and relative paths.
  String? resolveStoredPath(String? path) {
    if (path == null || path.isEmpty) return null;
    final docsPath = _docsPath;
    if (docsPath == null) return path; // init not called yet — return as-is

    // Already a relative path (e.g. "images/uuid.jpg")
    if (!path.startsWith('/')) return p.join(docsPath, path);

    // Absolute path that already matches current sandbox
    if (path.startsWith(docsPath)) return path;

    // Stale absolute path — try to extract relative portion after /Documents/
    // (covers iOS sandbox UUID rotation)
    const marker = '/Documents/';
    final idx = path.indexOf(marker);
    if (idx >= 0) {
      final relative = path.substring(idx + marker.length);
      final candidate = p.join(docsPath, relative);
      if (File(candidate).existsSync()) return candidate;
      // Fall through to basename check if the resolved path doesn't exist
    }

    // Android / unknown format: try to find the file by its basename under the
    // current documents directory (covers app_flutter path changes on reinstall).
    // Walk up to one subdirectory level (e.g. images/, voices/, videos/).
    final basename = p.basename(path);
    // Try <docsPath>/<basename>
    final flat = p.join(docsPath, basename);
    if (File(flat).existsSync()) return flat;
    // Try common subdirectories
    for (final sub in const ['images', 'voices', 'videos', 'files']) {
      final inSub = p.join(docsPath, sub, basename);
      if (File(inSub).existsSync()) return inSub;
    }

    // Could not resolve — return original path and let the UI handle missing file
    return path;
  }

  /// Сбрасывает кэш [Image.file] / [FileImage] для пути из БД (смена аватар/баннер канала).
  void evictFileImageCache(String? storedPath) {
    if (storedPath == null || storedPath.isEmpty) return;
    try {
      final r = resolveStoredPath(storedPath);
      if (r == null) return;
      final f = File(r);
      if (!f.existsSync()) return;
      PaintingBinding.instance.imageCache.evict(FileImage(f));
    } catch (_) {}
  }

  // ── Сохранение и сжатие ──────────────────────────────────────

  /// Сжимает изображение и сохраняет в <documents>/images/.
  /// [isAvatar] = true: жёсткое сжатие 256×256 px; иначе — чат-качество.
  /// [quality] и [maxSize] позволяют явно задать параметры сжатия.
  Future<String> compressAndSave(
    String sourcePath, {
    bool isAvatar = false,
    int? quality,
    int? maxSize,
  }) async {
    final dir = await _imagesDir();
    final name = '${_uuid.v4()}.jpg';
    final targetPath = p.join(dir.path, name);

    final w = maxSize ?? (isAvatar ? 192 : 320);
    final h = maxSize ?? (isAvatar ? 192 : 320);
    final q = quality ?? (isAvatar ? 60 : 55);
    final result = await FlutterImageCompress.compressAndGetFile(
      sourcePath,
      targetPath,
      minWidth: w,
      minHeight: h,
      quality: q,
      format: CompressFormat.jpeg,
    );

    if (result == null) {
      // fallback: просто копируем
      await File(sourcePath).copy(targetPath);
      return targetPath;
    }
    return result.path;
  }

  /// Фото из галереи: GIF копируем без перекодирования (анимация сохраняется).
  Future<String> saveChatImageFromPicker(String sourcePath) async {
    if (sourcePath.toLowerCase().endsWith('.gif')) {
      final dir = await _imagesDir();
      final out = p.join(dir.path, '${_uuid.v4()}.gif');
      await File(sourcePath).copy(out);
      return out;
    }
    return compressAndSave(sourcePath);
  }

  /// Сохраняет аватар контакта по его publicKeyHex (перезаписывает).
  Future<String> saveContactAvatar(String publicKeyHex, Uint8List data) async {
    final dir = await _imagesDir();
    final key = publicKeyHex.length >= 16 ? publicKeyHex.substring(0, 16) : publicKeyHex;
    final name = 'avatar_$key.jpg';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(data);
    return path;
  }

  /// Сохраняет баннер профиля контакта (отдельный файл, не пересекается с аватаром).
  Future<String> saveBannerImage(String publicKeyHex, Uint8List data) async {
    final dir = await _imagesDir();
    final key = publicKeyHex.length >= 16 ? publicKeyHex.substring(0, 16) : publicKeyHex;
    final name = 'banner_$key.jpg';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(data);
    return path;
  }

  String _audioExtFromMagic(Uint8List data) {
    if (data.length >= 3 && data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33) {
      return 'mp3';
    }
    if (data.length >= 12) {
      final f = String.fromCharCodes(data.sublist(4, 8));
      if (f == 'ftyp') return 'm4a';
    }
    return 'mp3';
  }

  /// Сохраняет принятую по сети «музыку профиля» контакта.
  Future<String> saveProfileMusic(String publicKeyHex, Uint8List data) async {
    final dir = await _imagesDir();
    final key = publicKeyHex.length >= 16 ? publicKeyHex.substring(0, 16) : publicKeyHex;
    final ext = _audioExtFromMagic(data);
    final name = 'profile_music_$key.$ext';
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(data);
    return path;
  }

  /// Сборка BLE-чанков для msgId `profile_music_...`.
  Future<String?> assembleAndSaveProfileMusic(
      String msgId, String senderPublicKey) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;
    final raw = assembly.assemble();
    final data = decompress(raw);
    return saveProfileMusic(senderPublicKey, data);
  }

  /// Saves a received video story to persistent storage.
  /// [storyId] is the story UUID; returns the local file path.
  Future<String> saveStoryVideo(String storyId, Uint8List bytes) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'story_videos'))
      ..createSync(recursive: true);
    final path = p.join(dir.path, '$storyId.mp4');
    await File(path).writeAsBytes(bytes);
    return path;
  }

  // ── Сжатие zlib ──────────────────────────────────────────────

  /// Сжимает данные через zlib (deflate) перед отправкой.
  /// Для уже сжатых форматов (JPEG, M4A, MP4) выигрыш ~5-10%.
  /// Для документов (PDF, TXT, DOCX) выигрыш 30-70%.
  Uint8List compress(Uint8List data) {
    final compressed = Uint8List.fromList(ZLibCodec(level: 6).encode(data));
    debugPrint('[ImageService] compress: ${data.length} → ${compressed.length} '
        '(${(100 - compressed.length * 100 / data.length).toStringAsFixed(0)}% saved)');
    // Используем сжатое только если оно меньше оригинала
    return compressed.length < data.length ? compressed : data;
  }

  /// Распаковывает zlib-сжатые данные на приёмнике.
  Uint8List decompress(Uint8List data) {
    try {
      return Uint8List.fromList(ZLibCodec().decode(data));
    } catch (_) {
      // Если данные не сжаты (обратная совместимость) — возвращаем как есть
      return data;
    }
  }

  // ── Разбивка на чанки ─────────────────────────────────────────

  /// Сжимает данные zlib → разбивает на base64-чанки для BLE.
  List<String> splitToBase64Chunks(Uint8List data) {
    final compressed = compress(data);
    final chunks = <String>[];
    int offset = 0;
    while (offset < compressed.length) {
      final end = (offset + kImgChunkBytes).clamp(0, compressed.length);
      final slice = compressed.sublist(offset, end);
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

  /// Receive a complete compressed blob from relay (no chunking needed).
  /// Sets the assembly as complete with a single data block.
  void receiveBlobData({required String msgId, required Uint8List compressedData}) {
    final assembly = _assemblies[msgId];
    if (assembly == null) return;
    // Override totalChunks=1 and put all data at index 0
    assembly._totalOverride = 1;
    assembly._chunks.clear();
    assembly._chunks[0] = compressedData;
  }

  /// Возвращает прогресс сборки: (received, total).
  (int received, int total) assemblyProgress(String msgId) {
    final assembly = _assemblies[msgId];
    if (assembly == null) return (0, 0);
    return (assembly.receivedCount, assembly.totalChunks);
  }

  /// Собирает, распаковывает zlib, сохраняет на диск и возвращает путь.
  /// [forContactKey] — если задан, пишет в avatar_<short>.jpg.
  Future<String?> assembleAndSave(
    String msgId, {
    String? forContactKey,
  }) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;

    final raw = assembly.assemble();
    final data = decompress(raw);
    final dir = await _imagesDir();
    String name;
    if (forContactKey != null) {
      // Banner keys end with '_banner' — use distinct prefix to avoid overwriting avatar.
      if (forContactKey.endsWith('_banner')) {
        final base = forContactKey.substring(0, forContactKey.length - 7); // strip '_banner'
        final key = base.length >= 16 ? base.substring(0, 16) : base;
        name = 'banner_$key.jpg';
      } else {
        final key = forContactKey.length >= 16 ? forContactKey.substring(0, 16) : forContactKey;
        name = 'avatar_$key.jpg';
      }
    } else {
      name = '${_uuid.v4()}.jpg';
    }
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(data);
    return path;
  }

  /// Check if a msgId was already fully assembled (blob or chunks completed).
  /// Prevents duplicate processing when both delivery paths succeed.
  bool wasAlreadyCompleted(String msgId) => _completedMsgIds.contains(msgId);

  /// Mark a msgId as completed after successful assembly.
  void markCompleted(String msgId) {
    _completedMsgIds.add(msgId);
    // Evict old entries to prevent unbounded growth
    if (_completedMsgIds.length > _kMaxCompletedTracked) {
      _completedMsgIds.remove(_completedMsgIds.first);
    }
  }

  /// Инициализирует сборку до прихода первого чанка (вызывается из onImgMeta).
  void initAssembly(String msgId, int totalChunks,
      {bool isAvatar = false,
      bool isVoice = false,
      bool isVideo = false,
      bool isSquare = false,
      bool isFile = false,
      bool isStory = false,
      String? fileName,
      String? storyId,
      String fromId = '',
      bool viewOnce = false}) {
    // Skip if this msgId was already fully assembled via another delivery path
    if (_completedMsgIds.contains(msgId)) return;
    _assemblies.putIfAbsent(
      msgId,
      () => _ImageAssembly(
        totalChunks: totalChunks,
        isAvatar: isAvatar,
        isVoice: isVoice,
        isVideo: isVideo,
        isSquare: isSquare,
        isFile: isFile,
        isStory: isStory,
        fileName: fileName,
        storyId: storyId,
        fromId: fromId,
        viewOnce: viewOnce,
      ),
    );
  }

  bool isAvatarAssembly(String msgId) => _assemblies[msgId]?.isAvatar ?? false;
  bool isVoiceAssembly(String msgId) => _assemblies[msgId]?.isVoice ?? false;
  bool isVideoAssembly(String msgId) => _assemblies[msgId]?.isVideo ?? false;
  bool isSquareAssembly(String msgId) => _assemblies[msgId]?.isSquare ?? false;
  bool isFileAssembly(String msgId) => _assemblies[msgId]?.isFile ?? false;
  bool isStoryAssembly(String msgId) => _assemblies[msgId]?.isStory ?? false;
  bool isViewOnceAssembly(String msgId) =>
      _assemblies[msgId]?.viewOnce ?? false;
  String? assemblyStoryId(String msgId) => _assemblies[msgId]?.storyId;
  String? assemblyFileName(String msgId) => _assemblies[msgId]?.fileName;
  String assemblyFromId(String msgId) => _assemblies[msgId]?.fromId ?? '';

  void cancelAssembly(String msgId) => _assemblies.remove(msgId);

  /// Собирает голосовое сообщение, распаковывает zlib, сохраняет как .m4a.
  Future<String?> assembleAndSaveVoice(String msgId) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;
    final raw = assembly.assemble();
    final data = decompress(raw);
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

  /// Native platform channel for square video cropping.
  static const _videoCropChannel = MethodChannel('com.rendergames.rlink/video_crop');

  /// Saves a video with native compression (no FFmpeg / no external Maven).
  /// Uses platform-native codec (Android MediaCodec / iOS AVFoundation).
  /// When [isSquare] is true, the video is first center-cropped to 1:1 via
  /// a native platform channel (AVFoundation on iOS, file copy + display crop
  /// on Android), then compressed.
  Future<String> saveVideo(String sourcePath, {bool isSquare = false}) async {
    final dir = await _videosDir();
    final suffix = isSquare ? '_sq' : '';
    final name = '${_uuid.v4()}$suffix.mp4';
    final targetPath = p.join(dir.path, name);

    // Step 1: Native square crop (if requested)
    String inputForCompress = sourcePath;
    if (isSquare) {
      debugPrint('[VideoSave] Cropping to square via native platform…');
      try {
        final croppedPath = p.join(dir.path, '${_uuid.v4()}_cropped.mp4');
        final success = await _videoCropChannel.invokeMethod<bool>(
          'cropToSquare',
          {'input': sourcePath, 'output': croppedPath},
        );
        if (success == true && await File(croppedPath).exists()) {
          inputForCompress = croppedPath;
          debugPrint('[VideoSave] Native crop OK: ${(await File(croppedPath).length()) ~/ 1024}KB');
        } else {
          debugPrint('[VideoSave] Native crop returned false, using original');
        }
      } catch (e) {
        debugPrint('[VideoSave] Native crop failed: $e — using original');
      }
    }

    // Step 2: Compress
    debugPrint('[VideoSave] Compressing via native codec (isSquare=$isSquare)…');
    try {
      final mediaInfo = await VideoCompress.compressVideo(
        inputForCompress,
        quality: VideoQuality.MediumQuality,
        includeAudio: true,
        deleteOrigin: false,
      );
      if (mediaInfo?.path != null) {
        final origKB = (await File(sourcePath).length()) ~/ 1024;
        final outKB  = (await File(mediaInfo!.path!).length()) ~/ 1024;
        debugPrint('[VideoSave] Compressed: ${origKB}KB → ${outKB}KB');
        await File(mediaInfo.path!).copy(targetPath);
        await VideoCompress.deleteAllCache();
        // Clean up intermediate cropped file
        if (inputForCompress != sourcePath) {
          try { await File(inputForCompress).delete(); } catch (_) {}
        }
        return targetPath;
      }
    } catch (e) {
      debugPrint('[VideoSave] Compression failed: $e — falling back to copy');
    }

    // Fallback: plain copy
    await File(inputForCompress).copy(targetPath);
    if (inputForCompress != sourcePath) {
      try { await File(inputForCompress).delete(); } catch (_) {}
    }
    return targetPath;
  }

  Future<String?> assembleAndSaveVideo(String msgId, {bool isSquare = false}) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;
    final raw = assembly.assemble();
    final data = decompress(raw);
    final dir = await _videosDir();
    final suffix = isSquare ? '_sq' : '';
    final path = p.join(dir.path, '$msgId$suffix.mp4');
    await File(path).writeAsBytes(data);
    return path;
  }

  /// Assembles a received file transfer and saves it to the files directory.
  /// Returns the local path, or null on failure.
  Future<String?> assembleAndSaveFile(String msgId) async {
    final assembly = _assemblies.remove(msgId);
    if (assembly == null || !assembly.isComplete) return null;
    final raw = assembly.assemble();
    final data = decompress(raw);
    final dir = await _filesDir();
    // Preserve original extension from fileName, else use .bin
    final originalName = assembly.fileName;
    final ext = (originalName != null && originalName.contains('.'))
        ? originalName.split('.').last
        : 'bin';
    final safeName = originalName ?? '$msgId.$ext';
    final path = p.join(dir.path, safeName);
    await File(path).writeAsBytes(data);
    return path;
  }

  Future<Directory> _filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'files'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}

class _ImageAssembly {
  final int totalChunks;
  final bool isAvatar;
  final bool isVoice;
  final bool isVideo;
  final bool isSquare;
  final bool isFile;
  final bool isStory;
  final bool viewOnce;
  final String? fileName;
  final String? storyId;
  final String fromId;
  final Map<int, Uint8List> _chunks = {};
  int? _totalOverride; // set by receiveBlobData for relay blobs

  _ImageAssembly({
    required this.totalChunks,
    this.isAvatar = false,
    this.isVoice = false,
    this.isVideo = false,
    this.isSquare = false,
    this.isFile = false,
    this.isStory = false,
    this.viewOnce = false,
    this.fileName,
    this.storyId,
    this.fromId = '',
  });

  void add(int index, Uint8List data) => _chunks[index] = data;

  int get receivedCount => _chunks.length;
  int get _effectiveTotal => _totalOverride ?? totalChunks;
  bool get isComplete => _chunks.length == _effectiveTotal;

  Uint8List assemble() {
    final out = BytesBuilder();
    for (var i = 0; i < _effectiveTotal; i++) {
      out.add(_chunks[i]!);
    }
    return out.toBytes();
  }
}
