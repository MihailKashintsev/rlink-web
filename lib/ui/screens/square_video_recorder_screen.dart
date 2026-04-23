import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../services/image_service.dart';
import '../../services/embedded_video_pause_bus.dart';
import '../../services/voice_service.dart';
import '../widgets/hold_square_video_review_screen.dart';
import '../widgets/square_video_recording_widgets.dart';

/// Показывает квадратный видеорекордер-оверлей поверх чата с блюром.
/// Возвращает путь к файлу или null.
Future<String?> showSquareVideoRecorder(BuildContext context) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 250),
    transitionBuilder: (ctx, anim, secondAnim, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (ctx, anim, secondAnim) => const _VideoOverlay(),
  );
}

class _VideoOverlay extends StatefulWidget {
  const _VideoOverlay();
  @override
  State<_VideoOverlay> createState() => _VideoOverlayState();
}

class _VideoOverlayState extends State<_VideoOverlay>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCamera = -1;
  bool _isRecording = false;
  bool _recordingPaused = false;
  /// Прогресс записи без setState на каждый тик — меньше лагов превью.
  final ValueNotifier<double> _recordingSeconds = ValueNotifier(0);
  Timer? _recordingTimer;
  bool _isInitializing = true;
  bool _isSwitching = false;
  String? _initError;

  /// Уже завершённые фрагменты записи (склейка при остановке, если сменили камеру).
  final List<String> _recordedSegmentPaths = [];

  late AnimationController _pulseController;

  static const _maxDuration = 15.0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _initCamera();
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingSeconds.dispose();
    _pulseController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    setState(() {
      _isInitializing = true;
      _initError = null;
    });
    try {
      // Разрешения запрашивает ОС при инициализации камеры / старте записи
      // (отдельный чек через permission_handler на iOS мешал записи квадратика).
      final raw = await availableCameras();
      _cameras = logicalCamerasForSquareVideo(raw);
      if (_cameras.isEmpty) {
        setState(() {
          _initError = 'Камера недоступна';
          _isInitializing = false;
        });
        return;
      }
      // Default to front camera
      int idx = _cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.front);
      if (idx < 0) idx = 0;
      await _setupController(idx);
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = 'Ошибка камеры: $e';
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _setupController(int cameraIndex) async {
    final controller = CameraController(
      _cameras[cameraIndex],
      ResolutionPreset.low,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {}
    if (!mounted) {
      controller.dispose();
      return;
    }
    // Dispose any existing controller (for initial setup; _switchCamera pre-disposes)
    final old = _controller;
    setState(() {
      _controller = controller;
      _selectedCamera = cameraIndex;
      _isInitializing = false;
      _isSwitching = false;
    });
    if (old != null && old != controller) {
      try { await old.dispose(); } catch (_) {}
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isSwitching) return;
    if (_isRecording) {
      await _switchCameraWhileRecording();
      return;
    }
    setState(() => _isSwitching = true);
    final next = (_selectedCamera + 1) % _cameras.length;
    try {
      // Dispose old controller first — two controllers can't share the camera
      final old = _controller;
      _controller = null;
      await old?.dispose();
      await _setupController(next);
    } catch (e) {
      debugPrint('[SquareVideo] switchCamera error: $e');
      if (mounted) setState(() => _isSwitching = false);
    }
  }

  Future<void> _switchCameraWhileRecording() async {
    final ctrl = _controller;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        !ctrl.value.isRecordingVideo ||
        _isSwitching) {
      return;
    }
    setState(() => _isSwitching = true);
    try {
      final file = await ctrl.stopVideoRecording();
      _recordedSegmentPaths.add(file.path);
      final next = (_selectedCamera + 1) % _cameras.length;
      final old = _controller;
      _controller = null;
      await old?.dispose();
      await _setupController(next);
      final c2 = _controller;
      if (c2 != null && c2.value.isInitialized) {
        await c2.startVideoRecording();
      }
    } catch (e) {
      debugPrint('[SquareVideo] switchCamera while recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сменить камеру: $e')),
        );
      }
      _recordingTimer?.cancel();
      if (mounted) {
        setState(() => _isRecording = false);
      }
    } finally {
      if (mounted) setState(() => _isSwitching = false);
    }
  }

  Future<void> _deleteTempVideos(List<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _startRecording() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isRecording) return;
    try {
      EmbeddedVideoPauseBus.instance.bump();
      await VoiceService.instance.stopPlayback();
      _recordedSegmentPaths.clear();
      _recordingPaused = false;
      await ctrl.startVideoRecording();
      _pulseController.repeat(reverse: true);
      _recordingSeconds.value = 0;
      setState(() => _isRecording = true);
      _recordingTimer?.cancel();
      _recordingTimer =
          Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || !_isRecording) return;
        if (_recordingPaused) return;
        _recordingSeconds.value += 0.25;
        if (_recordingSeconds.value >= _maxDuration) _stopAndSend();
      });
    } catch (e) {
      debugPrint('[SquareVideo] startVideoRecording error: $e');
    }
  }

  Future<void> _toggleRecordingPause() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || !_isRecording) return;
    try {
      if (_recordingPaused) {
        await ctrl.resumeVideoRecording();
        if (mounted) setState(() => _recordingPaused = false);
      } else {
        await ctrl.pauseVideoRecording();
        if (mounted) setState(() => _recordingPaused = true);
      }
    } catch (e) {
      debugPrint('[SquareVideo] pause toggle: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Пауза записи недоступна: $e')),
        );
      }
    }
  }

  Future<void> _stopAndSend() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _pulseController.stop();
    _pulseController.reset();
    final ctrl = _controller;
    if (ctrl == null) return;
    try {
      final file = await ctrl.stopVideoRecording();
      if (!mounted) return;

      final paths = [..._recordedSegmentPaths, file.path];
      _recordedSegmentPaths.clear();

      String outPath;
      if (paths.length == 1) {
        outPath = paths.single;
      } else {
        final merged = await ImageService.instance.mergeVideoSegments(paths);
        if (merged != null) {
          outPath = merged;
          await _deleteTempVideos(paths);
        } else {
          outPath = paths.last;
          await _deleteTempVideos(paths.sublist(0, paths.length - 1));
        }
      }

      if (!mounted) return;
      final recLen = _recordingSeconds.value;
      setState(() {
        _isRecording = false;
        _recordingPaused = false;
      });
      if (recLen < 0.5) {
        await _deleteTempVideos([outPath]);
        if (!mounted) return;
        return;
      }

      if (!mounted) return;
      final nav = Navigator.of(context);
      final chosen = await nav.push<String?>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (ctx) => HoldSquareVideoReviewScreen(
            videoPath: outPath,
            allowTrim: true,
          ),
        ),
      );
      if (!mounted) return;
      if (chosen == null || chosen.isEmpty) {
        await _deleteTempVideos([outPath]);
        return;
      }
      if (chosen != outPath) {
        await _deleteTempVideos([outPath]);
      }
      if (!mounted) return;
      Navigator.pop(context, chosen);
    } catch (e) {
      debugPrint('[SquareVideo] stopVideoRecording error: $e');
      setState(() {
        _isRecording = false;
        _recordingPaused = false;
      });
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final squareSize = screenWidth * 0.82;

    return Material(
      type: MaterialType.transparency,
      child: _isRecording
          ? Container(
              color: Colors.black.withValues(alpha: 0.72),
              child: SafeArea(
                child: _buildRecorderColumn(context, squareSize),
              ),
            )
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
                child: SafeArea(
                  child: _buildRecorderColumn(context, squareSize),
                ),
              ),
            ),
    );
  }

  Widget _buildRecorderColumn(BuildContext context, double squareSize) {
    final ctrl = _controller;
    final previewReady = ctrl != null &&
        ctrl.value.isInitialized &&
        !_isInitializing &&
        _initError == null;

    return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              previewReady
                  ? SquareVideoFramedCameraView(
                      controller: ctrl,
                      squareSize: squareSize,
                      isRecording: _isRecording,
                      recordingSeconds: _recordingSeconds,
                      maxDuration: _maxDuration,
                      showFlipButton: _cameras.length > 1,
                      onFlipCamera: _switchCamera,
                      isSwitchingCamera: _isSwitching,
                      pulseController: _pulseController,
                      isPaused: _recordingPaused,
                      onToggleRecordingPause: _isRecording
                          ? () => unawaited(_toggleRecordingPause())
                          : null,
                      recordingPaused: _recordingPaused,
                    )
                  : SizedBox(
                      width: squareSize + 6,
                      height: squareSize + 6,
                      child: Center(child: _buildPlaceholderPreview()),
                    ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _isRecording ? null : () => Navigator.pop(context),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: _isRecording
                            ? Colors.grey.shade800.withValues(alpha: 0.3)
                            : Colors.grey.shade800,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        color:
                            _isRecording ? Colors.grey.shade700 : Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 32),
                  GestureDetector(
                    onTapDown: (_) => _startRecording(),
                    onTapUp: (_) {
                      if (_isRecording) _stopAndSend();
                    },
                    onTapCancel: () {
                      if (_isRecording) _stopAndSend();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _isRecording ? 80 : 72,
                      height: _isRecording ? 80 : 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _isRecording ? Colors.red : Colors.white,
                          width: _isRecording ? 4 : 3,
                        ),
                      ),
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: _isRecording ? 32 : 58,
                          height: _isRecording ? 32 : 58,
                          decoration: BoxDecoration(
                            color: _isRecording
                                ? Colors.red
                                : const Color(0xFF1DB954),
                            borderRadius:
                                BorderRadius.circular(_isRecording ? 8 : 29),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 32),
                  const SizedBox(width: 52, height: 52),
                ],
              ),
              const SizedBox(height: 14),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  _isRecording
                      ? 'Нажмите для остановки · пауза на превью'
                      : 'Нажмите для записи',
                  key: ValueKey(_isRecording),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          );
  }

  Widget _buildPlaceholderPreview() {
    if (_isInitializing) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24, width: 3),
        ),
        child: const Center(
          child: CircularProgressIndicator(
            color: Color(0xFF1DB954),
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_initError != null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24, width: 3),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off_rounded,
                    color: Colors.white38, size: 36),
                const SizedBox(height: 12),
                Text(
                  _initError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _initCamera,
                  child: const Text('Повторить',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24, width: 3),
      ),
    );
  }
}

// Keep the old class as an alias for backwards compat (used in imports)
class SquareVideoRecorderScreen extends StatelessWidget {
  const SquareVideoRecorderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.pop(context);
    });
    return const SizedBox.shrink();
  }
}
