import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// Одна «логическая» камера на направление (wide в приоритете), как в рекордере каналов.
List<CameraDescription> logicalCamerasForSquareVideo(
    List<CameraDescription> all) {
  int rank(CameraLensType t) {
    switch (t) {
      case CameraLensType.wide:
        return 0;
      case CameraLensType.unknown:
        return 1;
      case CameraLensType.telephoto:
        return 2;
      case CameraLensType.ultraWide:
        return 3;
    }
  }

  CameraDescription? pick(CameraLensDirection dir) {
    final c = all.where((e) => e.lensDirection == dir).toList();
    if (c.isEmpty) return null;
    c.sort((a, b) => rank(a.lensType).compareTo(rank(b.lensType)));
    return c.first;
  }

  final out = <CameraDescription>[];
  final front = pick(CameraLensDirection.front);
  final back = pick(CameraLensDirection.back);
  if (front != null) out.add(front);
  if (back != null) out.add(back);
  if (out.isEmpty && all.isNotEmpty) out.add(all.first);
  return out;
}

class _SquareVideoCameraPreviewInner extends StatefulWidget {
  final CameraController controller;

  const _SquareVideoCameraPreviewInner({required this.controller});

  @override
  State<_SquareVideoCameraPreviewInner> createState() =>
      _SquareVideoCameraPreviewInnerState();
}

class _SquareVideoCameraPreviewInnerState
    extends State<_SquareVideoCameraPreviewInner> {
  double _zoom = 1.0;
  double _scaleStartZoom = 1.0;
  double _maxZoomLevel = 1.0;

  @override
  void initState() {
    super.initState();
    _applyZoomFromController();
  }

  @override
  void didUpdateWidget(covariant _SquareVideoCameraPreviewInner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _applyZoomFromController();
    }
  }

  Future<void> _applyZoomFromController() async {
    final c = widget.controller;
    if (!c.value.isInitialized) return;
    _zoom = 1.0;
    try {
      _maxZoomLevel = await c.getMaxZoomLevel();
      await c.setZoomLevel(_zoom);
    } catch (_) {
      _maxZoomLevel = 1.0;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    if (!ctrl.value.isInitialized || ctrl.value.previewSize == null) {
      return Container(color: const Color(0xFF111111));
    }
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) async {
            try {
              final box = ctx.findRenderObject() as RenderBox?;
              if (box == null) return;
              final local = box.globalToLocal(d.globalPosition);
              final nx = (local.dx / box.size.width).clamp(0.0, 1.0);
              final ny = (local.dy / box.size.height).clamp(0.0, 1.0);
              await ctrl.setFocusPoint(Offset(nx, ny));
              await ctrl.setExposurePoint(Offset(nx, ny));
            } catch (_) {}
          },
          onScaleStart: (_) {
            _scaleStartZoom = _zoom;
          },
          onScaleUpdate: (details) async {
            try {
              final maxZ = _maxZoomLevel;
              if (maxZ <= 1.01) return;
              final next =
                  (_scaleStartZoom * details.scale).clamp(1.0, maxZ);
              await ctrl.setZoomLevel(next);
              _zoom = next;
            } catch (_) {}
          },
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: ctrl.value.previewSize!.height,
              height: ctrl.value.previewSize!.width,
              child: RepaintBoundary(child: CameraPreview(ctrl)),
            ),
          ),
        );
      },
    );
  }
}

/// Квадратное превью с рамкой, прогрессом записи и таймером — как в каналах.
class SquareVideoFramedCameraView extends StatelessWidget {
  final CameraController controller;
  final double squareSize;
  final bool isRecording;
  final ValueListenable<double> recordingSeconds;
  final double maxDuration;
  final bool showFlipButton;
  final VoidCallback? onFlipCamera;
  final bool isSwitchingCamera;
  final AnimationController? pulseController;
  final bool isPaused;
  final VoidCallback? onToggleRecordingPause;
  final bool recordingPaused;

  const SquareVideoFramedCameraView({
    super.key,
    required this.controller,
    required this.squareSize,
    required this.isRecording,
    required this.recordingSeconds,
    this.maxDuration = 15.0,
    this.showFlipButton = false,
    this.onFlipCamera,
    this.isSwitchingCamera = false,
    this.pulseController,
    this.isPaused = false,
    this.onToggleRecordingPause,
    this.recordingPaused = false,
  });

  Color get _borderColor {
    if (!isRecording) return Colors.white24;
    if (recordingPaused || isPaused) return Colors.amber;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: squareSize + 6,
        height: squareSize + 6,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _borderColor, width: 3),
        ),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: SizedBox(
                width: squareSize,
                height: squareSize,
                child: _SquareVideoCameraPreviewInner(controller: controller),
              ),
            ),
            if (isRecording)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ValueListenableBuilder<double>(
                  valueListenable: recordingSeconds,
                  builder: (_, rec, __) {
                    return ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(17),
                      ),
                      child: LinearProgressIndicator(
                        value: (rec / maxDuration).clamp(0.0, 1.0),
                        minHeight: 3,
                        color: Colors.red,
                        backgroundColor: Colors.white24,
                      ),
                    );
                  },
                ),
              ),
            if (showFlipButton && onFlipCamera != null)
              Positioned(
                top: 10,
                right: 10,
                child: GestureDetector(
                  onTap: isSwitchingCamera ? null : onFlipCamera,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: AnimatedRotation(
                      turns: isSwitchingCamera ? 0.5 : 0,
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
            if (isRecording && onToggleRecordingPause != null)
              Positioned(
                bottom: 10,
                right: 10,
                child: Material(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: onToggleRecordingPause,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        recordingPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            if (isRecording)
              Positioned(
                bottom: 10,
                left: 12,
                child: ValueListenableBuilder<double>(
                  valueListenable: recordingSeconds,
                  builder: (_, rec, __) {
                    final secs = rec.floor();
                    final tenths = ((rec % 1) * 10).floor();
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (pulseController != null)
                            AnimatedBuilder(
                              animation: pulseController!,
                              builder: (_, ___) => Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(
                                    alpha: 0.5 +
                                        pulseController!.value * 0.5,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          else
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.85),
                                shape: BoxShape.circle,
                              ),
                            ),
                          const SizedBox(width: 6),
                          Text(
                            '0:${secs.toString().padLeft(2, '0')}.$tenths',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
