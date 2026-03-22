import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Экран быстрой записи квадратного видео (аналог кружков Telegram, но квадрат).
/// Возвращает путь к записанному файлу через Navigator.pop(context, path).
class SquareVideoRecorderScreen extends StatefulWidget {
  const SquareVideoRecorderScreen({super.key});

  @override
  State<SquareVideoRecorderScreen> createState() =>
      _SquareVideoRecorderScreenState();
}

class _SquareVideoRecorderScreenState
    extends State<SquareVideoRecorderScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCamera = 0;
  bool _isRecording = false;
  double _recordingSeconds = 0;
  Timer? _recordingTimer;
  bool _isInitializing = true;
  String? _initError;

  static const _maxDuration = 15.0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera([int cameraIndex = 0]) async {
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
      final idx = cameraIndex.clamp(0, _cameras.length - 1);
      final controller = CameraController(
        _cameras[idx],
        ResolutionPreset.low,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller?.dispose();
      setState(() {
        _controller = controller;
        _selectedCamera = idx;
        _isInitializing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = 'Ошибка камеры: $e';
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isRecording) return;
    final next = (_selectedCamera + 1) % _cameras.length;
    await _initCamera(next);
  }

  Future<void> _startRecording() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isRecording) return;
    try {
      await ctrl.startVideoRecording();
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
    final previewSize = screenWidth * 0.85;
    final secs = _recordingSeconds.floor();
    final tenths = ((_recordingSeconds % 1) * 10).floor();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Square camera preview
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: previewSize,
                  height: previewSize,
                  child: _buildPreview(previewSize),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Timer
            AnimatedOpacity(
              opacity: _isRecording ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$secs.${tenths}s / ${_maxDuration.toInt()}s',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Close
                _CircleIconButton(
                  onTap: _isRecording ? null : () => Navigator.pop(context),
                  icon: Icons.close,
                  size: 52,
                  bgColor: Colors.grey.shade800,
                ),
                const SizedBox(width: 28),
                // Record button (hold or tap)
                GestureDetector(
                  onTapDown: (_) => _startRecording(),
                  onTapUp: (_) => _stopAndSend(),
                  onLongPressStart: (_) => _startRecording(),
                  onLongPressEnd: (_) => _stopAndSend(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: _isRecording
                          ? Colors.red
                          : const Color(0xFF1DB954),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: Icon(
                      _isRecording ? Icons.stop_rounded : Icons.videocam,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
                const SizedBox(width: 28),
                // Switch camera
                _CircleIconButton(
                  onTap: _cameras.length > 1 && !_isRecording
                      ? _switchCamera
                      : null,
                  icon: Icons.flip_camera_ios_outlined,
                  size: 52,
                  bgColor: Colors.grey.shade800,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _isRecording
                  ? 'Отпустите для отправки'
                  : 'Удерживайте кнопку для записи',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(double size) {
    if (_isInitializing) {
      return const ColoredBox(
        color: Color(0xFF1A1A1A),
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFF1DB954)),
        ),
      );
    }
    if (_initError != null) {
      return ColoredBox(
        color: const Color(0xFF1A1A1A),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _initError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ),
      );
    }
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF1A1A1A));
    }
    // Crop preview to square
    final previewAspect = ctrl.value.aspectRatio;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: previewAspect > 1 ? size * previewAspect : size,
        height: previewAspect > 1 ? size : size / previewAspect,
        child: CameraPreview(ctrl),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final VoidCallback? onTap;
  final IconData icon;
  final double size;
  final Color bgColor;

  const _CircleIconButton({
    required this.onTap,
    required this.icon,
    required this.size,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onTap == null ? bgColor.withValues(alpha: 0.4) : bgColor,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: onTap == null ? Colors.grey : Colors.white,
          size: size * 0.45,
        ),
      ),
    );
  }
}
