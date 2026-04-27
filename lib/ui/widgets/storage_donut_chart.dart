import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/app_storage_breakdown_service.dart';

String formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0
      ? '${v.toStringAsFixed(0)} ${u[i]}'
      : '${v.toStringAsFixed(i >= 2 ? 2 : 1)} ${u[i]}';
}

/// Кольцевая диаграмма: тап по сектору выделяет сегмент (индекс в [onSelect]).
class StorageDonutChart extends StatelessWidget {
  final List<AppStorageSegment> segments;
  final int? selectedIndex;
  final ValueChanged<int?> onSelect;

  const StorageDonutChart({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<int>(0, (a, s) => a + s.bytes);
    if (total <= 0) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(
            'Нет данных для диаграммы',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, 240.0);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final hit = _hitTestSlice(
                  local: d.localPosition,
                  size: size,
                  segments: segments,
                  totalBytes: total,
                );
                onSelect(hit == selectedIndex ? null : hit);
              },
              child: CustomPaint(
                painter: _DonutPainter(
                  segments: segments,
                  totalBytes: total,
                  selectedIndex: selectedIndex,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatStorageBytes(total),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Text(
                        'всего',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

int? _hitTestSlice({
  required Offset local,
  required double size,
  required List<AppStorageSegment> segments,
  required int totalBytes,
}) {
  final cx = size / 2;
  final cy = size / 2;
  final dx = local.dx - cx;
  final dy = local.dy - cy;
  final r = math.sqrt(dx * dx + dy * dy);
  final outer = size * 0.42;
  final inner = size * 0.26;
  if (r < inner || r > outer) return null;

  var ang = math.atan2(dy, dx);
  ang += math.pi / 2;
  if (ang < 0) ang += 2 * math.pi;

  var start = 0.0;
  const twoPi = 2 * math.pi;
  for (var i = 0; i < segments.length; i++) {
    final sweep = twoPi * (segments[i].bytes / totalBytes);
    final end = start + sweep;
    if (sweep > 0 && ang >= start && ang < end) return i;
    start = end;
  }
  return null;
}

class _DonutPainter extends CustomPainter {
  final List<AppStorageSegment> segments;
  final int totalBytes;
  final int? selectedIndex;

  _DonutPainter({
    required this.segments,
    required this.totalBytes,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);
    final outer = size.shortestSide * 0.42;
    final inner = size.shortestSide * 0.26;
    final rect = Rect.fromCircle(center: center, radius: outer);
    final innerRect = Rect.fromCircle(center: center, radius: inner);

    var startAngle = -math.pi / 2;
    const twoPi = 2 * math.pi;

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final sweep = twoPi * (seg.bytes / totalBytes);
      if (sweep > 0) {
        final paint = Paint()
          ..style = PaintingStyle.fill
          ..color = Color(seg.argbColor).withValues(
            alpha: selectedIndex == null || selectedIndex == i ? 1 : 0.35,
          );

        final path = Path()
          ..moveTo(
            cx + outer * math.cos(startAngle),
            cy + outer * math.sin(startAngle),
          )
          ..arcTo(rect, startAngle, sweep, false)
          ..lineTo(
            cx + inner * math.cos(startAngle + sweep),
            cy + inner * math.sin(startAngle + sweep),
          )
          ..arcTo(innerRect, startAngle + sweep, -sweep, false)
          ..close();

        canvas.drawPath(path, paint);

        if (selectedIndex == i) {
          final border = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = Colors.white.withValues(alpha: 0.9);
          canvas.drawPath(path, border);
        }
      }
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) {
    return oldDelegate.segments != segments ||
        oldDelegate.totalBytes != totalBytes ||
        oldDelegate.selectedIndex != selectedIndex;
  }
}
