import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../utils/platform_features.dart';

/// Дата: на iOS 26+ — Cupertino в «стеклянном» листе, иначе Material.
Future<DateTime?> showAdaptiveDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  firstDate ??= DateTime(2020);
  lastDate ??= DateTime(2100);
  if (!iosLiquidGlassAndNativePickers || !context.mounted) {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
  }
  var chosen = initialDate;
  return showCupertinoModalPopup<DateTime>(
    context: context,
    builder: (ctx) {
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            color: CupertinoColors.systemBackground.resolveFrom(ctx)
                .withValues(alpha: 0.55),
            height: 320,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Отмена'),
                    ),
                    CupertinoButton(
                      onPressed: () => Navigator.pop(ctx, chosen),
                      child: const Text('Готово'),
                    ),
                  ],
                ),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: initialDate,
                    minimumDate: firstDate,
                    maximumDate: lastDate,
                    onDateTimeChanged: (d) => chosen = d,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Время: на iOS 26+ — колесо Cupertino, иначе Material.
Future<TimeOfDay?> showAdaptiveTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
}) async {
  if (!iosLiquidGlassAndNativePickers || !context.mounted) {
    return showTimePicker(context: context, initialTime: initialTime);
  }
  var dt = DateTime(2020, 1, 1, initialTime.hour, initialTime.minute);
  final pickedTime = await showCupertinoModalPopup<DateTime>(
    context: context,
    builder: (ctx) {
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            color: CupertinoColors.systemBackground.resolveFrom(ctx)
                .withValues(alpha: 0.55),
            height: 280,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Отмена'),
                    ),
                    CupertinoButton(
                      onPressed: () => Navigator.pop(ctx, dt),
                      child: const Text('Готово'),
                    ),
                  ],
                ),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: true,
                    initialDateTime: dt,
                    onDateTimeChanged: (d) => dt = d,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (pickedTime == null) return null;
  return TimeOfDay(hour: pickedTime.hour, minute: pickedTime.minute);
}
