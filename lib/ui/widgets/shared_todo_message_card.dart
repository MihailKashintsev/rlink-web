import 'package:flutter/material.dart';

import '../../models/shared_collab.dart';

/// Совместный список дел в сообщении чата / группы.
class SharedTodoMessageCard extends StatelessWidget {
  final String encoded;
  final ColorScheme cs;
  final bool isOutgoing;
  final Future<void> Function(String newEncoded) onPersist;

  const SharedTodoMessageCard({
    super.key,
    required this.encoded,
    required this.cs,
    required this.isOutgoing,
    required this.onPersist,
  });

  @override
  Widget build(BuildContext context) {
    final p = SharedTodoPayload.tryDecode(encoded);
    if (p == null) return const SizedBox.shrink();
    final fg = isOutgoing ? cs.onPrimary : cs.onSurface;
    final border = (isOutgoing ? cs.onPrimary : cs.outline).withValues(alpha: 0.25);

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
              Icon(Icons.checklist_rtl, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  p.title.isEmpty ? 'Список дел' : p.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...p.items.map((e) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () => onPersist(p.withToggled(e.id).encode()),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: e.done,
                        onChanged: (_) => onPersist(p.withToggled(e.id).encode()),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        e.text,
                        style: TextStyle(
                          fontSize: 14,
                          decoration:
                              e.done ? TextDecoration.lineThrough : null,
                          color: e.done
                              ? fg.withValues(alpha: 0.45)
                              : fg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
