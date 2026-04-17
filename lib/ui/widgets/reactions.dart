import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Единый расширенный набор реакций, используемый по всему приложению:
/// 1:1 чат, каналы, комментарии каналов, группы и истории.
///
/// 30 эмодзи: базовые чувства + реакции поддержки + мемные.
const List<String> kReactionEmojis = [
  '👍', '❤️', '😂', '😮', '😢', '😡',
  '🎉', '🔥', '👎', '🤔', '😴', '🤗',
  '👏', '🙏', '💯', '👀', '🥺', '😍',
  '🤯', '🤣', '🤝', '💪', '🌟', '✨',
  '🚀', '💔', '😎', '🙌', '🍾', '❤️‍🔥',
];

/// Быстрая панель — первые 6 эмодзи, показываются в long-press меню.
const List<String> kQuickReactionEmojis = [
  '👍', '❤️', '😂', '😮', '😢', '🔥',
];

/// Отображает bottom sheet с полной панелью реакций.
///
/// Возвращает выбранный эмодзи или null, если пользователь закрыл sheet.
Future<String?> showReactionPickerSheet(BuildContext context) async {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(
                  'Выберите реакцию',
                  style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: kReactionEmojis.map((e) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.of(ctx).pop(e);
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Компактная «плашка» реакций — показывается под сообщением/постом/историей.
///
/// [reactions] — map emoji → список id участников.
/// [myId] — наш id, нужен чтобы подсветить свои реакции.
/// [onTap] — вызывается при тапе по реакции (toggle).
class ReactionsBar extends StatelessWidget {
  final Map<String, List<String>> reactions;
  final String myId;
  final void Function(String emoji) onTap;
  final bool compact;

  const ReactionsBar({
    super.key,
    required this.reactions,
    required this.myId,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final entries = reactions.entries
        .where((e) => e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: entries.map((e) {
        final mine = e.value.contains(myId);
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onTap(e.key),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 6 : 8,
              vertical: compact ? 2 : 3,
            ),
            decoration: BoxDecoration(
              color: mine
                  ? cs.primary.withValues(alpha: 0.18)
                  : cs.surfaceContainerHighest.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: mine ? cs.primary : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(e.key, style: TextStyle(fontSize: compact ? 13 : 14)),
                const SizedBox(width: 3),
                Text(
                  '${e.value.length}',
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w600,
                    color: mine ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
