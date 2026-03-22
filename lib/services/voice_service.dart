import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class VoiceService {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  final _recorder = AudioRecorder();
  AudioPlayer? _player;

  /// Путь к текущему воспроизводимому файлу (null — не играет).
  final ValueNotifier<String?> currentlyPlaying = ValueNotifier(null);

  /// Прогресс воспроизведения [0.0 – 1.0].
  final ValueNotifier<double> playProgress = ValueNotifier(0);

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Начинает запись. Возвращает путь к временному файлу.
  Future<String?> startRecording() async {
    if (!await _recorder.hasPermission()) return null;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 8000,
        sampleRate: 8000,
        numChannels: 1,
      ),
      path: path,
    );
    return path;
  }

  /// Останавливает запись и возвращает финальный путь.
  Future<String?> stopRecording() => _recorder.stop();

  /// Отменяет запись без сохранения.
  Future<void> cancelRecording() => _recorder.cancel();

  /// Воспроизводит голосовое сообщение по локальному пути.
  Future<void> play(String path) async {
    await _player?.stop();
    _player?.dispose();
    _player = AudioPlayer();
    currentlyPlaying.value = path;
    playProgress.value = 0;

    _player!.onPositionChanged.listen((pos) async {
      final dur = await _player?.getDuration();
      if (dur != null && dur.inMilliseconds > 0) {
        playProgress.value = pos.inMilliseconds / dur.inMilliseconds;
      }
    });
    _player!.onPlayerComplete.listen((_) {
      currentlyPlaying.value = null;
      playProgress.value = 0;
    });

    await _player!.play(DeviceFileSource(path));
  }

  /// Приостанавливает воспроизведение.
  Future<void> pause() async {
    await _player?.pause();
    currentlyPlaying.value = null;
  }

  /// Останавливает воспроизведение.
  Future<void> stop() async {
    await _player?.stop();
    currentlyPlaying.value = null;
    playProgress.value = 0;
  }

  void dispose() {
    _player?.dispose();
    _recorder.dispose();
  }
}
