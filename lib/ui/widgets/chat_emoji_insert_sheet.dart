import 'package:flutter/material.dart';
import 'avatar_widget.dart';

/// Вставка эмодзи в поле чата.
Future<void> showChatEmojiInsertSheet(
  BuildContext context, {
  required void Function(String insert) onInsert,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: AvatarEmojiPicker(
                  selected: '',
                  onSelected: (emoji) {
                    Navigator.pop(ctx);
                    onInsert(emoji);
                  },
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
