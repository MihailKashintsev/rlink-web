import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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
  double _recordingSeconds = 0;
  Timer? _recordingTimer;
  bool _isInitializing = true;
  bool _isSwitching = false;
  String? _initError;

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
      final camStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();
      if (!camStatus.isGranted || !micStatus.isGranted) {
        setState(() {
          _initError = 'Нет доступа к камере или микрофону';
          _isInitializing = false;
        });
        return;
      }
      _cameras = await availableCameras();
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
      ResolutionPreset.medium,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
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
    if (_cameras.length < 2 || _isRecording || _isSwitching) return;
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

  Future<void> _startRecording() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isRecording) return;
    try {
      await ctrl.startVideoRecording();
      _pulseController.repeat(reverse: true);
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
      });
      _recordingTimer?.cancel();
      _recordingTimer =
          Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted || !_isRecording) return;
        setState(() => _recordingSeconds += 0.1);
        if (_recordingSeconds >= _maxDuration) _stopAndSend();
      });
    } catch (e) {
      debugPrint('[SquareVideo] startVideoRecording error: $e');
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
      setState(() => _isRecording = false);
      if (!mounted) return;
      if (_recordingSeconds >= 0.5) {
        Navigator.pop(context, file.path);
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('[SquareVideo] stopVideoRecording error: $e');
      setState(() => _isRecording = false);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final squareSize = screenWidth * 0.82;
    final secs = _recordingSeconds.floor();
    final tenths = ((_recordingSeconds % 1) * 10).floor();
    final progress = _recordingSeconds / _maxDuration;

    return Material(
      type: MaterialType.transparency,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          color: Colors.black.withValues(alpha: 0.5),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Square camera preview
                Center(
                  child: Container(
                    width: squareSize + 6,
                    height: squareSize + 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isRecording ? Colors.red : Colors.white24,
                        width: 3,
                      ),
                    ),
                    child: Stack(
                      children: [
                        // Square preview
                        ClipRRect(
                          borderRadius: BorderRadius.circular(17),
                          child: SizedBox(
                            width: squareSize,
                            height: squareSize,
                            child: _buildPreview(squareSize),
                          ),
                        ),
                        // Progress bar at top
                        if (_isRecording)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(17)),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                                color: Colors.red,
                                backgroundColor: Colors.white24,
                              ),
                            ),
                          ),
                        // Camera switch button (top right)
                        if (_cameras.length > 1 && !_isRecording)
                          Positioned(
                            top: 10,
                            right: 10,
                            child: GestureDetector(
                              onTap: _switchCamera,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.white24, width: 1),
                                ),
                                child: AnimatedRotation(
                                  turns: _isSwitching ? 0.5 : 0,
                                  duration: const Duration(milliseconds: 300),
                                  child: const Icon(
                                    Icons.flip_camera_ios_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // Recording timer overlay (bottom left)
                        if (_isRecording)
                          Positioned(
                            bottom: 10,
                            left: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedBuilder(
                                    animation: _pulseController,
                                    builder: (_, __) => Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        color: Colors.red.withValues(
                                            alpha: 0.5 +
                                                _pulseController.value * 0.5),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '0:${secs.toString().padLeft(2, '0')}.$tenths',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      fontFeatures: [
                                        FontFeature.tabularFigures()
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Close
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
                    // Record button
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
                    // Spacer
                    const SizedBox(width: 52, height: 52),
                  ],
                ),
                const SizedBox(height: 14),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _isRecording
                        ? 'Нажмите для остановки'
                        : 'Нажмите для записи',
                    key: ValueKey(_isRecording),
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(double size) {
    if (_isInitializing) {
      return Container(
        color: const Color(0xFF111111),
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
        color: const Color(0xFF111111),
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
              ],
            ),
          ),
        ),
      );
    }
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return Container(color: const Color(0xFF111111));
    }
    // Cover-crop: fill the square, clip overflow (no stretching!)
    final previewAspect = ctrl.value.aspectRatio;
    // aspectRatio = previewSize.width / previewSize.height
    // Camera in portrait: aspect might be >1 (raw sensor) or <1 depending on platform.
    // We scale so the SMALLER dimension matches the square, the larger overflows.
    final double w, h;
    if (previewAspect >= 1.0) {
      // Landscape-ish: wider than tall → match height to square, width overflows
      w = size * previewAspect;
      h = size;
    } else {
      // Portrait-ish: taller than wide → match width to square, height overflows
      w = size;
      h = size / previewAspect;
    }
    return OverflowBox(
      maxWidth: w,
      maxHeight: h,
      child: SizedBox(
        width: w,
        height: h,
        child: CameraPreview(ctrl),
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
