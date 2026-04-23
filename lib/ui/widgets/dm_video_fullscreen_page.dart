import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../../services/embedded_video_pause_bus.dart';
import '../../services/voice_service.dart';

/// Полноэкранное воспроизведение DM-видео (в т.ч. квадратиков) с [VideoPlayer] в дереве.
class DmVideoFullscreenPage extends StatefulWidget {
  final String path;

  /// Если true — при [VoiceService.stopPlayback] (сессия очереди сброшена) закрыть экран.
  /// Для открытия из чата без очереди оставлять false.
  final bool closeWhenPlaybackSessionCleared;

  const DmVideoFullscreenPage({
    super.key,
    required this.path,
    this.closeWhenPlaybackSessionCleared = false,
  });

  @override
  State<DmVideoFullscreenPage> createState() => _DmVideoFullscreenPageState();
}

class _DmVideoFullscreenPageState extends State<DmVideoFullscreenPage> {
  late VideoPlayerController _ctrl;
  bool _initialized = false;
  bool _error = false;
  Timer? _hideTopTimer;
  bool _showTopBar = true;
  String? _seekFlash;
  Timer? _seekFlashTimer;
  bool _speedBoost = false;
  int _embedPauseGen = 0;
  bool _completeScheduled = false;

  void _onEmbedPauseBus() {
    if (!mounted) return;
    final g = EmbeddedVideoPauseBus.instance.generation.value;
    if (g != _embedPauseGen) {
      _embedPauseGen = g;
      try {
        _ctrl.pause();
      } catch (_) {}
      setState(() {});
    }
  }

  void _onPlaybackSessionChanged() {
    if (!widget.closeWhenPlaybackSessionCleared || !mounted) return;
    if (VoiceService.instance.playbackSession.value == null) {
      Navigator.of(context).maybePop();
    }
  }

  void _onPausePulse() {
    if (!mounted || !_initialized) return;
    try {
      _ctrl.pause();
    } catch (_) {}
  }

  void _onResumePulse() {
    if (!mounted || !_initialized) return;
    try {
      _ctrl.play();
    } catch (_) {}
  }

  void _onCtrlTick() {
    if (!mounted) return;
    final v = _ctrl.value;
    if (!v.isInitialized) return;
    final totalMs = v.duration.inMilliseconds;
    if (totalMs <= 0) return;
    VoiceService.instance.reportSquarePlaybackProgress(
      v.position.inMilliseconds / totalMs,
    );
    if (_completeScheduled) return;
    if (v.position.inMilliseconds >= totalMs - 80) {
      _completeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    if (widget.closeWhenPlaybackSessionCleared) {
      VoiceService.instance.playbackSession
          .addListener(_onPlaybackSessionChanged);
      VoiceService.instance.squareVideoUiPausePulse.addListener(_onPausePulse);
      VoiceService.instance.squareVideoUiResumePulse
          .addListener(_onResumePulse);
    }

    _ctrl = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          _ctrl.addListener(_onCtrlTick);
          _ctrl.play();
          _armHideTopBar();
        }
      }).catchError((e) {
        debugPrint('[VideoPlayer] init error: $e');
        if (mounted) setState(() => _error = true);
      });
  }

  @override
  void dispose() {
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    if (widget.closeWhenPlaybackSessionCleared) {
      VoiceService.instance.playbackSession
          .removeListener(_onPlaybackSessionChanged);
      VoiceService.instance.squareVideoUiPausePulse
          .removeListener(_onPausePulse);
      VoiceService.instance.squareVideoUiResumePulse
          .removeListener(_onResumePulse);
    }
    _hideTopTimer?.cancel();
    _seekFlashTimer?.cancel();
    try {
      _ctrl.removeListener(_onCtrlTick);
    } catch (_) {}
    try {
      _ctrl.setPlaybackSpeed(1.0);
    } catch (_) {}
    _ctrl.dispose();
    super.dispose();
  }

  void _armHideTopBar() {
    _hideTopTimer?.cancel();
    _hideTopTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_ctrl.value.isPlaying) {
        setState(() => _showTopBar = false);
      }
    });
  }

  void _flashSeek(String label) {
    _seekFlashTimer?.cancel();
    setState(() => _seekFlash = label);
    _seekFlashTimer = Timer(const Duration(milliseconds: 550), () {
      if (mounted) setState(() => _seekFlash = null);
    });
  }

  void _seekRelative(int deltaSec) {
    final end = _ctrl.value.duration;
    var p = _ctrl.value.position + Duration(seconds: deltaSec);
    if (p < Duration.zero) p = Duration.zero;
    if (p > end) p = end;
    _ctrl.seekTo(p);
    _flashSeek(deltaSec > 0 ? '+5 с' : '−5 с');
  }

  void _setSpeedBoost(bool on) {
    if (!_initialized) return;
    try {
      _ctrl.setPlaybackSpeed(on ? 2.0 : 1.0);
    } catch (_) {}
    setState(() => _speedBoost = on);
  }

  void _togglePlayPause() {
    if (_ctrl.value.isPlaying) {
      _ctrl.pause();
    } else {
      _ctrl.play();
    }
    setState(() {});
    setState(() => _showTopBar = true);
    _armHideTopBar();
  }

  String _fmtDur(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    if (_error) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Text('Ошибка воспроизведения',
              style: TextStyle(color: Colors.white)),
        ),
      );
    }

    if (!_initialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Color(0xFF1DB954)),
              const SizedBox(height: 16),
              Text(
                p.basename(widget.path),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final videoW = _ctrl.value.size.width;
    final videoH = _ctrl.value.size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: videoW,
                  height: videoH,
                  child: VideoPlayer(_ctrl),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 112 + bottomInset,
              child: Row(
                children: [
                  Expanded(
                    flex: 35,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () => _seekRelative(-5),
                      onLongPressStart: (_) => _setSpeedBoost(true),
                      onLongPressEnd: (_) => _setSpeedBoost(false),
                      onLongPressCancel: () => _setSpeedBoost(false),
                    ),
                  ),
                  Expanded(
                    flex: 30,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _togglePlayPause,
                    ),
                  ),
                  Expanded(
                    flex: 35,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () => _seekRelative(5),
                      onLongPressStart: (_) => _setSpeedBoost(true),
                      onLongPressEnd: (_) => _setSpeedBoost(false),
                      onLongPressCancel: () => _setSpeedBoost(false),
                    ),
                  ),
                ],
              ),
            ),
            if (_seekFlash != null)
              Center(
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _seekFlash!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            if (_speedBoost)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Text(
                    '×2',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            if (_showTopBar)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: Colors.black54,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: _ctrl,
                        builder: (_, val, __) => IconButton(
                          icon: Icon(
                            val.isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                          ),
                          onPressed: _togglePlayPause,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Material(
                color: Colors.black87,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 8, 8 + bottomInset),
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _ctrl,
                    builder: (_, val, __) {
                      final totalMs = val.duration.inMilliseconds;
                      final posMs = totalMs > 0
                          ? val.position.inMilliseconds.clamp(0, totalMs)
                          : 0;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                              overlayShape: SliderComponentShape.noOverlay,
                            ),
                            child: Slider(
                              value: totalMs > 0 ? posMs.toDouble() : 0,
                              max: totalMs > 0 ? totalMs.toDouble() : 1,
                              onChangeStart: (_) {
                                _ctrl.pause();
                                setState(() => _showTopBar = true);
                              },
                              onChangeEnd: (_) {
                                _ctrl.play();
                                _armHideTopBar();
                              },
                              onChanged: (v) {
                                _ctrl
                                    .seekTo(Duration(milliseconds: v.round()));
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _fmtDur(Duration(milliseconds: posMs)),
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                                Text(
                                  _fmtDur(val.duration),
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
