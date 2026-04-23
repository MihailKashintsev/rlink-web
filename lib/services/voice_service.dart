import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart' show AudioPlayer, DeviceFileSource;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../ui/widgets/dm_video_fullscreen_page.dart';
import 'embedded_video_pause_bus.dart';

/// Тип элемента очереди (квадратик в очереди идёт как видео с дорожкой).
enum PlaybackMediaKind { voice, audioFile, squareVideo }

class PlaybackQueueItem {
  final String path;
  final String title;
  final PlaybackMediaKind kind;

  const PlaybackQueueItem({
    required this.path,
    required this.title,
    required this.kind,
  });
}

/// Сессия для мини-плеера под статус-баром.
class VoicePlaybackSession {
  final String path;
  final String title;
  final int indexOneBased;
  final int total;
  final PlaybackMediaKind kind;
  final bool isPaused;

  const VoicePlaybackSession({
    required this.path,
    required this.title,
    required this.indexOneBased,
    required this.total,
    required this.kind,
    required this.isPaused,
  });
}

class VoiceService {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  final _recorder = AudioRecorder();
  AudioPlayer? _player;
  StreamSubscription<Duration>? _audioPosSub;
  StreamSubscription<void>? _audioCompleteSub;

  GlobalKey<NavigatorState>? _navigatorKey;

  /// Импульсы для паузы/возобновления квадратика, когда плеер в отдельном route.
  final ValueNotifier<int> squareVideoUiPausePulse = ValueNotifier(0);
  final ValueNotifier<int> squareVideoUiResumePulse = ValueNotifier(0);

  List<PlaybackQueueItem> _queue = [];
  int _queuePos = 0;
  bool _sessionPaused = false;
  bool _advanceInFlight = false;
  Completer<void>? _audioSessionConfigured;

  void configureNavigator(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
  }

  void _setProgressClamped(double v) {
    if (!v.isFinite) {
      playProgress.value = 0;
      return;
    }
    playProgress.value = v.clamp(0.0, 1.0);
  }

  Future<void> _ensurePlaybackAudioSession() async {
    if (_audioSessionConfigured != null) {
      await _audioSessionConfigured!.future;
      return;
    }
    final c = Completer<void>();
    _audioSessionConfigured = c;
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.duckOthers,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      await session.setActive(true);
      c.complete();
    } catch (e, st) {
      debugPrint('[Voice] audio_session: $e\n$st');
      if (!c.isCompleted) c.complete();
    }
  }

  /// Путь к текущему воспроизводимому файлу (null — не играет).
  final ValueNotifier<String?> currentlyPlaying = ValueNotifier(null);

  /// Прогресс воспроизведения [0.0 – 1.0].
  final ValueNotifier<double> playProgress = ValueNotifier(0);

  /// Мини-плеер: заголовок, позиция в очереди, пауза.
  final ValueNotifier<VoicePlaybackSession?> playbackSession =
      ValueNotifier(null);

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Остановить очередь и приглушить встроенные видео (перед записью с микрофона).
  Future<void> interruptForRecording() async {
    await stopPlayback();
    EmbeddedVideoPauseBus.instance.bump();
  }

  /// Начинает запись. Возвращает путь к временному файлу.
  Future<String?> startRecording() async {
    await interruptForRecording();
    if (!await _recorder.hasPermission()) return null;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
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

  Future<void> _disposePlaybackOutputs() async {
    _audioPosSub?.cancel();
    _audioPosSub = null;
    _audioCompleteSub?.cancel();
    _audioCompleteSub = null;
    try {
      await _player?.stop();
    } catch (_) {}
    _player?.dispose();
    _player = null;
  }

  /// Прогресс квадратика с полноэкранного плеера (0..1).
  void reportSquarePlaybackProgress(double p) {
    if (_queue.isEmpty || _queuePos < 0 || _queuePos >= _queue.length) return;
    if (_queue[_queuePos].kind != PlaybackMediaKind.squareVideo) return;
    final cur = currentlyPlaying.value;
    if (cur == null || cur != _queue[_queuePos].path) return;
    _setProgressClamped(p);
  }

  void _syncSession() {
    if (_queue.isEmpty || _queuePos < 0 || _queuePos >= _queue.length) {
      playbackSession.value = null;
      return;
    }
    final item = _queue[_queuePos];
    playbackSession.value = VoicePlaybackSession(
      path: item.path,
      title: item.title,
      indexOneBased: _queuePos + 1,
      total: _queue.length,
      kind: item.kind,
      isPaused: _sessionPaused,
    );
  }

  /// Очередь голосовых / аудио / квадратиков по порядку (как в Telegram).
  Future<void> playQueue(List<PlaybackQueueItem> items) async {
    final filtered = <PlaybackQueueItem>[];
    for (final it in items) {
      if (it.path.isNotEmpty && File(it.path).existsSync()) {
        filtered.add(it);
      }
    }
    if (filtered.isEmpty) return;

    EmbeddedVideoPauseBus.instance.bump();
    await _disposePlaybackOutputs();
    _queue = filtered;
    _queuePos = 0;
    _sessionPaused = false;
    await _playCurrentItem();
  }

  /// Одно сообщение — как очередь из одного элемента.
  Future<void> play(
    String path, {
    String title = 'Голосовое',
    PlaybackMediaKind kind = PlaybackMediaKind.voice,
  }) async {
    await playQueue([
      PlaybackQueueItem(path: path, title: title, kind: kind),
    ]);
  }

  Future<void> _playCurrentItem() async {
    if (_queuePos < 0 || _queuePos >= _queue.length) {
      await stopPlayback();
      return;
    }

    await _disposePlaybackOutputs();
    final item = _queue[_queuePos];
    currentlyPlaying.value = item.path;
    _setProgressClamped(0);
    _sessionPaused = false;
    _syncSession();

    if (item.kind == PlaybackMediaKind.squareVideo) {
      await _startVideoItem(item);
    } else {
      await _startAudioItem(item);
    }
  }

  Future<void> _startAudioItem(PlaybackQueueItem item) async {
    await _ensurePlaybackAudioSession();
    _player = AudioPlayer();
    _audioPosSub = _player!.onPositionChanged.listen((pos) async {
      try {
        final dur = await _player?.getDuration();
        if (dur != null && dur.inMilliseconds > 0) {
          _setProgressClamped(
              pos.inMilliseconds / dur.inMilliseconds);
        }
      } catch (e, st) {
        debugPrint('[Voice] position tick: $e\n$st');
      }
    });
    _audioCompleteSub = _player!.onPlayerComplete.listen((_) {
      unawaited(_advanceQueue());
    });
    await _player!.play(DeviceFileSource(item.path));
  }

  Future<void> _startVideoItem(PlaybackQueueItem item) async {
    await _ensurePlaybackAudioSession();
    final nav = _navigatorKey?.currentState;
    if (nav == null) {
      debugPrint('[Voice] square video: navigator not configured');
      await _advanceQueue();
      return;
    }
    try {
      await nav.push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => DmVideoFullscreenPage(
                path: item.path,
                closeWhenPlaybackSessionCleared: true,
              ),
        ),
      );
    } catch (e, st) {
      debugPrint('[Voice] square video route: $e\n$st');
    }
    if (_queue.isEmpty) return;
    if (_queuePos < 0 || _queuePos >= _queue.length) return;
    final still = _queue[_queuePos];
    if (still.path != item.path ||
        still.kind != PlaybackMediaKind.squareVideo) {
      return;
    }
    await _advanceQueue();
  }

  Future<void> _advanceQueue() async {
    if (_advanceInFlight) return;
    _advanceInFlight = true;
    try {
      _queuePos++;
      if (_queuePos >= _queue.length) {
        await stopPlayback();
      } else {
        await _playCurrentItem();
      }
    } finally {
      _advanceInFlight = false;
    }
  }

  Future<void> pausePlayback() async {
    if (_queue.isEmpty) return;
    _sessionPaused = true;
    final item = _queue[_queuePos];
    if (item.kind == PlaybackMediaKind.squareVideo) {
      squareVideoUiPausePulse.value++;
    } else {
      try {
        await _player?.pause();
      } catch (_) {}
    }
    _syncSession();
  }

  Future<void> resumePlayback() async {
    if (_queue.isEmpty) return;
    _sessionPaused = false;
    final item = _queue[_queuePos];
    if (item.kind == PlaybackMediaKind.squareVideo) {
      squareVideoUiResumePulse.value++;
    } else {
      try {
        if (_player != null) {
          await _player!.resume();
        }
      } catch (_) {}
    }
    _syncSession();
  }

  /// Полная остановка очереди и плееров.
  Future<void> stopPlayback() async {
    await _disposePlaybackOutputs();
    _queue = [];
    _queuePos = 0;
    _sessionPaused = false;
    playbackSession.value = null;
    currentlyPlaying.value = null;
    _setProgressClamped(0);
  }

  void dispose() {
    _audioPosSub?.cancel();
    _audioPosSub = null;
    _audioCompleteSub?.cancel();
    _audioCompleteSub = null;
    _player?.dispose();
    _player = null;
    _recorder.dispose();
  }
}
