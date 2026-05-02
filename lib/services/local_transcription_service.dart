import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_whisper_kit/flutter_whisper_kit.dart';

/// Локальная (on-device) расшифровка аудио через WhisperKit.
///
/// Сейчас поддержка включена для iOS/macOS (Apple-платформы).
class LocalTranscriptionService {
  LocalTranscriptionService._();
  static final LocalTranscriptionService instance = LocalTranscriptionService._();

  final FlutterWhisperKit _whisper = FlutterWhisperKit();
  bool _modelReady = false;
  bool _loadingModel = false;

  bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isMacOS;
  }

  Future<void> _ensureModel() async {
    if (_modelReady) return;
    if (_loadingModel) {
      while (_loadingModel) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (_modelReady) return;
    }
    _loadingModel = true;
    try {
      // `base` — мультиязычная модель; `tiny` даёт хуже русский и чаще уезжает в латиницу/англ.
      final loaded = await _whisper.loadModel('base');
      if (loaded == null || loaded.isEmpty) {
        throw StateError('Whisper model load failed');
      }
      _modelReady = true;
    } finally {
      _loadingModel = false;
    }
  }

  Future<String> transcribeFile(String audioPath, {String language = 'ru'}) async {
    if (!isSupported) {
      throw UnsupportedError('Локальная расшифровка доступна на iOS/macOS.');
    }
    if (audioPath.isEmpty || !File(audioPath).existsSync()) {
      throw ArgumentError('Файл голосового не найден.');
    }
    await _ensureModel();
    // Явная JSON-сборка: только `task: transcribe` (не translate — иначе выход на английском).
    final decode = DecodingOptions.fromJson(<String, dynamic>{
      'verbose': false,
      'task': 'transcribe',
      'language': language,
      'detectLanguage': false,
      'temperature': 0.0,
      'temperatureIncrementOnFallback': 0.2,
      'temperatureFallbackCount': 5,
      'sampleLength': 224,
      'topK': 5,
      'usePrefillPrompt': false,
      'usePrefillCache': false,
      'skipSpecialTokens': true,
      'withoutTimestamps': true,
      'wordTimestamps': false,
      'clipTimestamps': <double>[0.0],
      'concurrentWorkerCount': 4,
      'chunkingStrategy': 'vad',
    });
    final result = await _whisper.transcribeFromFile(
      audioPath,
      options: decode,
    );
    final text = (result?.text ?? '').trim();
    if (text.isEmpty) {
      throw StateError('Речь не распознана');
    }
    return text;
  }
}

