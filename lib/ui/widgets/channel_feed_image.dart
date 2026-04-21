import 'dart:io';

import 'package:flutter/material.dart';

import 'platform_layout.dart';

/// Картинка в ленте канала / шапке поста: на ПК — компактнее, без полноэкранной ширины.
class ChannelFeedImage extends StatelessWidget {
  final String resolvedPath;

  const ChannelFeedImage({super.key, required this.resolvedPath});

  @override
  Widget build(BuildContext context) {
    final file = File(resolvedPath);
    if (!file.existsSync()) return const SizedBox.shrink();
    final pc = isDesktopShell();
    final sw = MediaQuery.sizeOf(context).width;
    if (!pc) {
      return Image.file(
        file,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    final maxW = (sw * 0.38).clamp(200.0, 360.0);
    const maxH = 280.0;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Вложение-картинка в пузырьке комментария (уже узкий; на ПК чуть меньше и без жёсткого кропа).
class ChannelCommentImage extends StatelessWidget {
  final String resolvedPath;

  const ChannelCommentImage({super.key, required this.resolvedPath});

  @override
  Widget build(BuildContext context) {
    final file = File(resolvedPath);
    if (!file.existsSync()) return const SizedBox.shrink();
    final pc = isDesktopShell();
    final maxW = pc ? 168.0 : 200.0;
    final maxH = pc ? 200.0 : 240.0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}
