import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart' show AudioPlayer, DeviceFileSource;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

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
  StreamSubscription<Duration>? _audioDurSub;
  StreamSubscription<dynamic>? _audioStateSub;

  VideoPlayerController? _squareQueueCtrl;
  bool _squareEndDispatchedInService = false;

  /// Импульсы для паузы/возобновления квадратика из очереди (пузырь в чате).
  final ValueNotifier<int> squareVideoUiPausePulse = ValueNotifier(0);
  final ValueNotifier<int> squareVideoUiResumePulse = ValueNotifier(0);

  List<PlaybackQueueItem> _queue = [];
  int _queuePos = 0;
  bool _sessionPaused = false;
  bool _advanceInFlight = false;
  Completer<void>? _audioSessionConfigured;

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
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.duckOthers,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
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

  /// Полная длительность текущего трека (Duration.zero — неизвестна).
  final ValueNotifier<Duration> playDuration = ValueNotifier(Duration.zero);

  /// Мини-плеер: заголовок, позиция в очереди, пауза.
  final ValueNotifier<VoicePlaybackSession?> playbackSession =
      ValueNotifier(null);

  /// Квадратик из очереди: один контроллер для PiP и фона (вне чата).
  final ValueNotifier<VideoPlayerController?> squareQueueVideoPreview =
      ValueNotifier(null);

  /// Счётчик для перерисовки PiP при смене видимости пузыря в списке.
  final ValueNotifier<int> squareQueuePipLayoutRevision = ValueNotifier(0);

  /// Путь квадратика из очереди, чей пузырь сейчас пересекается с видимой областью экрана.
  String? _squarePathWithVisibleViewport;

  void _bumpSquareQueuePipLayout() {
    squareQueuePipLayoutRevision.value = squareQueuePipLayoutRevision.value + 1;
  }

  void _clearSquareViewportCoverage() {
    if (_squarePathWithVisibleViewport != null) {
      _squarePathWithVisibleViewport = null;
      _bumpSquareQueuePipLayout();
    }
  }

  /// Вызывается из пузыря квадратика: при пересечении с viewport PiP скрывается (без «дубля»).
  void reportSquareBubbleViewportCoverage(String path, bool overlapsViewport) {
    final cur = currentlyPlaying.value;
    if (cur != path) return;
    if (!isCurrentQueueSquareAtPath(path)) return;
    if (overlapsViewport) {
      if (_squarePathWithVisibleViewport != path) {
        _squarePathWithVisibleViewport = path;
        _bumpSquareQueuePipLayout();
      }
    } else {
      if (_squarePathWithVisibleViewport == path) {
        _squarePathWithVisibleViewport = null;
        _bumpSquareQueuePipLayout();
      }
    }
  }

  /// Плавающая миниатюра — только если этот же ролик не виден в списке чата.
  bool shouldDisplaySquareQueuePip() {
    if (_squareQueueCtrl == null) return false;
    final cur = currentlyPlaying.value;
    if (cur == null || cur.isEmpty) return false;
    if (!isCurrentQueueSquareAtPath(cur)) return false;
    return _squarePathWithVisibleViewport != cur;
  }

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

  /// Пауза текущей записи (если поддерживается платформой).
  Future<void> pauseRecording() async {
    try {
      await _recorder.pause();
    } catch (e) {
      debugPrint('[Voice] pauseRecording failed: $e');
    }
  }

  /// Продолжить запись после паузы.
  Future<void> resumeRecording() async {
    try {
      await _recorder.resume();
    } catch (e) {
      debugPrint('[Voice] resumeRecording failed: $e');
    }
  }

  /// Поток амплитуды микрофона (дБ). Удобно для живой волны при записи.
  Stream<double> amplitudeStream({
    Duration interval = const Duration(milliseconds: 80),
  }) {
    return _recorder.onAmplitudeChanged(interval).map((a) => a.current);
  }

  Future<void> _disposeSquareQueueController() async {
    _squareEndDispatchedInService = false;
    _clearSquareViewportCoverage();
    final c = _squareQueueCtrl;
    _squareQueueCtrl = null;
    squareQueueVideoPreview.value = null;
    if (c == null) return;
    try {
      c.removeListener(_onSquareQueueVideoTick);
    } catch (_) {}
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  void _onSquareQueueVideoTick() {
    final c = _squareQueueCtrl;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    final totalMs = v.duration.inMilliseconds;
    if (totalMs <= 0) return;
    reportSquarePlaybackProgress(v.position.inMilliseconds / totalMs);
    if (_squareEndDispatchedInService) return;
    if (v.position.inMilliseconds >= totalMs - 80) {
      _squareEndDispatchedInService = true;
      final path = _queue.isNotEmpty &&
              _queuePos >= 0 &&
              _queuePos < _queue.length
          ? _queue[_queuePos].path
          : null;
      if (path != null) {
        unawaited(onSquareVideoPlaybackEnded(path));
      }
    }
  }

  Future<void> _disposePlaybackOutputs() async {
    await _disposeSquareQueueController();
    _audioPosSub?.cancel();
    _audioPosSub = null;
    _audioCompleteSub?.cancel();
    _audioCompleteSub = null;
    _audioDurSub?.cancel();
    _audioDurSub = null;
    _audioStateSub?.cancel();
    _audioStateSub = null;
    try {
      await _player?.stop();
    } catch (_) {}
    _player?.dispose();
    _player = null;
  }

  /// Текущий элемент очереди — квадратик по этому пути (для UI в чате).
  bool isCurrentQueueSquareAtPath(String path) {
    if (_queue.isEmpty || _queuePos < 0 || _queuePos >= _queue.length) {
      return false;
    }
    final it = _queue[_queuePos];
    return it.kind == PlaybackMediaKind.squareVideo && it.path == path;
  }

  bool get hasSquareQueueVideoController => _squareQueueCtrl != null;

  /// Прогресс квадратика в пузыре чата (0..1) при воспроизведении из очереди.
  void reportSquarePlaybackProgress(double p) {
    if (_queue.isEmpty || _queuePos < 0 || _queuePos >= _queue.length) return;
    if (_queue[_queuePos].kind != PlaybackMediaKind.squareVideo) return;
    final cur = currentlyPlaying.value;
    if (cur == null || cur != _queue[_queuePos].path) return;
    _setProgressClamped(p);
  }

  /// Вызывается из пузыря [VideoPlayer], когда ролик `_sq.mp4` доиграл до конца в режиме очереди.
  Future<void> onSquareVideoPlaybackEnded(String path) async {
    if (_queue.isEmpty) return;
    if (_queuePos < 0 || _queuePos >= _queue.length) return;
    final still = _queue[_queuePos];
    if (still.path != path || still.kind != PlaybackMediaKind.squareVideo) {
      return;
    }
    await _advanceQueue();
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
    playDuration.value = Duration.zero;
    _audioDurSub = _player!.onDurationChanged.listen((dur) {
      if (dur.inMilliseconds > 0) playDuration.value = dur;
    });
    _audioPosSub = _player!.onPositionChanged.listen((pos) async {
      try {
        final dur = playDuration.value.inMilliseconds > 0
            ? playDuration.value
            : await _player?.getDuration();
        if (dur != null && dur.inMilliseconds > 0) {
          playDuration.value = dur;
          _setProgressClamped(pos.inMilliseconds / dur.inMilliseconds);
        }
      } catch (e, st) {
        debugPrint('[Voice] position tick: $e\n$st');
      }
    });
    _audioCompleteSub = _player!.onPlayerComplete.listen((_) {
      unawaited(_advanceQueue());
    });
    _audioStateSub =
        _player!.onPlayerStateChanged.listen((state) {}, onError: (e) {
      debugPrint('[Voice] player error: $e');
      unawaited(_advanceQueue());
    });
    await _player!.play(DeviceFileSource(item.path));
  }

  /// Перемотка на позицию [progress] ∈ [0.0, 1.0].
  Future<void> seekTo(double progress) async {
    final p = progress.clamp(0.0, 1.0);
    if (_queue.isNotEmpty &&
        _queuePos >= 0 &&
        _queuePos < _queue.length &&
        _queue[_queuePos].kind == PlaybackMediaKind.squareVideo) {
      final c = _squareQueueCtrl;
      if (c == null || !c.value.isInitialized) return;
      final totalMs = c.value.duration.inMilliseconds;
      if (totalMs <= 0) return;
      final target =
          Duration(milliseconds: (p * totalMs).round());
      try {
        await c.seekTo(target);
        _setProgressClamped(p);
      } catch (e) {
        debugPrint('[Voice] square seek error: $e');
      }
      return;
    }
    final dur = playDuration.value;
    if (dur.inMilliseconds <= 0) return;
    final target = Duration(
        milliseconds: (p * dur.inMilliseconds).round());
    try {
      await _player?.seek(target);
      _setProgressClamped(p);
    } catch (e) {
      debugPrint('[Voice] seek error: $e');
    }
  }

  Future<void> _startVideoItem(PlaybackQueueItem item) async {
    await _ensurePlaybackAudioSession();
    if (kIsWeb) {
      // На web локальный файл в VideoPlayer не поднимаем — пузырь в чате.
      return;
    }
    _squareEndDispatchedInService = false;
    VideoPlayerController? c;
    try {
      final f = File(item.path);
      if (!f.existsSync()) {
        await _advanceQueue();
        return;
      }
      await _disposeSquareQueueController();
      c = VideoPlayerController.file(f);
      await c.initialize();
      if (_queue.isEmpty ||
          _queuePos < 0 ||
          _queuePos >= _queue.length ||
          _queue[_queuePos].path != item.path) {
        await c.dispose();
        return;
      }
      c.setLooping(false);
      _squareQueueCtrl = c;
      squareQueueVideoPreview.value = c;
      c = null;
      final active = _squareQueueCtrl!;
      final d = active.value.duration;
      if (d.inMilliseconds > 0) {
        playDuration.value = d;
      }
      active.addListener(_onSquareQueueVideoTick);
      await active.seekTo(Duration.zero);
      if (!_sessionPaused) {
        await active.play();
      }
    } catch (e, st) {
      debugPrint('[Voice] square queue start: $e\n$st');
      if (c != null && !identical(c, _squareQueueCtrl)) {
        try {
          await c.dispose();
        } catch (_) {}
      }
      await _disposeSquareQueueController();
      await _advanceQueue();
    }
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
      try {
        await _squareQueueCtrl?.pause();
      } catch (_) {}
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
      try {
        await _squareQueueCtrl?.play();
      } catch (_) {}
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
    playDuration.value = Duration.zero;
  }

  void dispose() {
    unawaited(_disposeSquareQueueController());
    _audioPosSub?.cancel();
    _audioPosSub = null;
    _audioCompleteSub?.cancel();
    _audioCompleteSub = null;
    _player?.dispose();
    _player = null;
    _recorder.dispose();
  }
}
