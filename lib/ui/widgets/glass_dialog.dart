import 'dart:ui';

import 'package:flutter/material.dart';

import '../../utils/platform_features.dart';

/// Обычный диалог или «стеклянный» (iOS 26+): размытие фона под окном.
Future<T?> showAdaptiveGlassDialog<T>({
  required BuildContext context,
  required Widget Function(BuildContext ctx) builder,
}) {
  if (!iosLiquidGlassAndNativePickers) {
    return showDialog<T>(context: context, builder: builder);
  }
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
          child: Material(
            color: Theme.of(ctx)
                .colorScheme
                .surfaceContainerHigh
                .withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: builder(ctx),
          ),
        ),
      ),
    ),
  );
}
