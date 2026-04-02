import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';

/// Renders emoji as Twemoji images (Apple-like style) instead of Android system emoji.
/// Uses CDN with aggressive local caching for offline support.
class AppleEmoji extends StatelessWidget {
  final String emoji;
  final double size;

  const AppleEmoji({
    super.key,
    required this.emoji,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    // On iOS/macOS emoji already look great — use native text rendering
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isLinux) {
      return Text(emoji, style: TextStyle(fontSize: size * 0.85));
    }

    final codepoints = _emojiToTwemojiCode(emoji);
    if (codepoints == null) {
      return Text(emoji, style: TextStyle(fontSize: size * 0.85));
    }

    return FutureBuilder<File?>(
      future: TwemojiCache.instance.getEmojiFile(codepoints),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return Image.file(
            snapshot.data!,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                Text(emoji, style: TextStyle(fontSize: size * 0.85)),
          );
        }
        // Fallback to system emoji while loading
        return Text(emoji, style: TextStyle(fontSize: size * 0.85));
      },
    );
  }

  /// Converts an emoji string to Twemoji filename codepoints.
  /// E.g. "❤️" → "2764-fe0f", "👍" → "1f44d", "🔥" → "1f525"
  static String? _emojiToTwemojiCode(String emoji) {
    if (emoji.isEmpty) return null;
    final codeUnits = emoji.runes.toList();
    if (codeUnits.isEmpty) return null;
    // Filter out variation selector 0xFE0F for some emoji that don't need it
    final parts = codeUnits
        .map((r) => r.toRadixString(16))
        .toList();
    final code = parts.join('-');
    return code;
  }
}

/// Cache manager for Twemoji PNG files.
/// Downloads from CDN once, then serves from local cache.
class TwemojiCache {
  TwemojiCache._();
  static final TwemojiCache instance = TwemojiCache._();

  static const _cdnBase =
      'https://cdn.jsdelivr.net/gh/jdecked/twemoji@15.1.0/assets/72x72';

  String? _cacheDir;
  final Map<String, File?> _memCache = {};
  final Map<String, Future<File?>> _pendingDownloads = {};
  Dio? _dio;

  Future<String> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final dir = await getApplicationDocumentsDirectory();
    final emojiDir = Directory('${dir.path}/twemoji');
    if (!await emojiDir.exists()) {
      await emojiDir.create(recursive: true);
    }
    _cacheDir = emojiDir.path;
    return _cacheDir!;
  }

  Dio _getDio() {
    _dio ??= Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
    ));
    return _dio!;
  }

  /// Returns cached emoji file, or downloads it in background.
  Future<File?> getEmojiFile(String codepoints) async {
    // Check memory cache first
    if (_memCache.containsKey(codepoints)) {
      return _memCache[codepoints];
    }

    // Check disk cache
    final dir = await _getCacheDir();
    final file = File('$dir/$codepoints.png');
    if (await file.exists()) {
      _memCache[codepoints] = file;
      return file;
    }

    // Download from CDN (deduplicate concurrent requests)
    if (_pendingDownloads.containsKey(codepoints)) {
      return _pendingDownloads[codepoints];
    }

    final future = _downloadEmoji(codepoints, file);
    _pendingDownloads[codepoints] = future;

    try {
      final result = await future;
      _memCache[codepoints] = result;
      return result;
    } finally {
      _pendingDownloads.remove(codepoints);
    }
  }

  Future<File?> _downloadEmoji(String codepoints, File file) async {
    try {
      // Try with the full codepoint string first
      var url = '$_cdnBase/$codepoints.png';
      var response = await _getDio().get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );

      if (response.statusCode == 200 && response.data != null) {
        await file.writeAsBytes(response.data!);
        return file;
      }
    } catch (_) {
      // Try without fe0f variant selector
      try {
        final simplified = codepoints.replaceAll('-fe0f', '');
        if (simplified != codepoints) {
          final url = '$_cdnBase/$simplified.png';
          final response = await _getDio().get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
          );
          if (response.statusCode == 200 && response.data != null) {
            await file.writeAsBytes(response.data!);
            return file;
          }
        }
      } catch (_) {}
    }

    // Download failed — cache null so we don't retry immediately
    _memCache[codepoints] = null;
    return null;
  }

  /// Pre-cache a list of commonly used emoji.
  Future<void> preloadCommon() async {
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isLinux) return;

    const commonEmoji = [
      '❤️', '👍', '🔥', '😂', '😮', '😢', '🎉', '👎', '🤔', '💯', '😍', '🥳',
      '📢', '👥', '😀', '😊', '🙂', '😎', '🤗', '💪', '✨', '🌟', '⭐',
    ];

    for (final emoji in commonEmoji) {
      final code = AppleEmoji._emojiToTwemojiCode(emoji);
      if (code != null) {
        // Fire and forget — don't block
        getEmojiFile(code).catchError((_) => null);
      }
    }
  }
}
