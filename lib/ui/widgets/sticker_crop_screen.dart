import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

/// Квадратная обрезка изображения под стикер (как в Telegram).
class StickerCropScreen extends StatefulWidget {
  final Uint8List imageBytes;

  const StickerCropScreen({super.key, required this.imageBytes});

  @override
  State<StickerCropScreen> createState() => _StickerCropScreenState();
}

class _StickerCropScreenState extends State<StickerCropScreen> {
  final _cropController = CropController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Стикер'),
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    setState(() => _busy = true);
                    _cropController.crop();
                  },
            child: Text('Готово', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Crop(
              controller: _cropController,
              image: widget.imageBytes,
              aspectRatio: 1,
              onCropped: (result) {
                setState(() => _busy = false);
                switch (result) {
                  case CropSuccess(:final croppedImage):
                    Navigator.pop(context, croppedImage);
                  case CropFailure(:final cause):
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$cause'), backgroundColor: Colors.red),
                    );
                }
              },
              onStatusChanged: (s) {
                if (s == CropStatus.cropping) {
                  setState(() => _busy = true);
                }
              },
              baseColor: Colors.black,
              maskColor: Colors.black.withValues(alpha: 0.55),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Перемещайте и масштабируйте область. Стикер будет квадратным.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
