import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Экран обрезки аватарки по круглому шаблону.
/// Пользователь может зумить и перемещать изображение.
/// Возвращает [File] обрезанного круглого изображения.
class AvatarCropScreen extends StatefulWidget {
  final String imagePath;
  const AvatarCropScreen({super.key, required this.imagePath});

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _transformController = TransformationController();
  final _repaintKey = GlobalKey();
  bool _saving = false;

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _crop() async {
    setState(() => _saving = true);
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final bytes = byteData.buffer.asUint8List();
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/avatar_crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);

      if (mounted) Navigator.pop(context, file.path);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width - 48;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Обрезка аватара'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _crop,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Готово',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16)),
          ),
        ],
      ),
      body: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            children: [
              // Repaint boundary captures exactly the circle area
              ClipOval(
                child: RepaintBoundary(
                  key: _repaintKey,
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: InteractiveViewer(
                      transformationController: _transformController,
                      minScale: 0.5,
                      maxScale: 5.0,
                      constrained: false,
                      child: Image.file(
                        File(widget.imagePath),
                        fit: BoxFit.cover,
                        width: size * 2,
                        height: size * 2,
                      ),
                    ),
                  ),
                ),
              ),
              // Circle overlay guide (non-interactive, passes through taps)
              IgnorePointer(
                child: CustomPaint(
                  size: Size(size, size),
                  painter: _CircleOverlayPainter(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2;

    // Draw border around the circle
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
