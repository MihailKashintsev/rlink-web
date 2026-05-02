import 'package:flutter/material.dart';

/// Вертикальная позиция глобального [AudioQueueMiniPlayer]: верхний край в логических px.
///
/// Экраны с особой шапкой (чат, список чатов с фильтрами) задают [barTop] через якорь
/// или [setBarTopBelowAppBar]. Остальные маршруты оставляют null — в [main] подставляется
/// отступ под стандартный [AppBar].
class AudioQueueMiniPlayerLayout {
  AudioQueueMiniPlayerLayout._();
  static final instance = AudioQueueMiniPlayerLayout._();

  final ValueNotifier<double?> barTop = ValueNotifier<double?>(null);

  void setBarTop(double? top) {
    if (barTop.value == top) return;
    barTop.value = top;
  }

  void clearBarTop() => setBarTop(null);

  /// Сразу под системной плашкой и типовым [AppBar] (56dp).
  void setBarTopBelowAppBar(BuildContext context) {
    final mq = MediaQuery.of(context);
    setBarTop(mq.padding.top + kToolbarHeight);
  }

  static double defaultBarTop(BuildContext context) {
    final mq = MediaQuery.of(context);
    return mq.padding.top + kToolbarHeight;
  }

  /// [key] — виджет нулевой высоты сразу под зоной, над которой должен быть плеер.
  void scheduleBarTopFromAnchor(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      setBarTop(box.localToGlobal(Offset.zero).dy);
    });
  }
}
