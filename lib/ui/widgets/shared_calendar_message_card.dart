import 'package:flutter/material.dart';

import '../../models/shared_collab.dart';

class SharedCalendarMessageCard extends StatelessWidget {
  final String encoded;
  final ColorScheme cs;
  final bool isOutgoing;

  const SharedCalendarMessageCard({
    super.key,
    required this.encoded,
    required this.cs,
    required this.isOutgoing,
  });

  @override
  Widget build(BuildContext context) {
    final p = SharedCalendarPayload.tryDecode(encoded);
    if (p == null || p.startMs <= 0) return const SizedBox.shrink();
    final fg = isOutgoing ? cs.onPrimary : cs.onSurface;
    final border = (isOutgoing ? cs.onPrimary : cs.outline).withValues(alpha: 0.25);
    final dt = DateTime.fromMillisecondsSinceEpoch(p.startMs);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isOutgoing
            ? Colors.black.withValues(alpha: 0.12)
            : cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_available_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  p.title.isEmpty ? 'Событие' : p.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${dt.day.toString().padLeft(2, '0')}.'
            '${dt.month.toString().padLeft(2, '0')}.${dt.year} '
            '${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}',
            style: TextStyle(
              fontSize: 13,
              color: fg.withValues(alpha: 0.85),
            ),
          ),
          if (p.note != null && p.note!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              p.note!,
              style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.7)),
            ),
          ],
        ],
      ),
    );
  }
}
