import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/emoji_pack_service.dart';

/// Карточка набора эмодзи в пузыре (payload из [invitePayloadJson]).
class EmojiPackCardBubble extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isOutgoing;

  const EmojiPackCardBubble({
    super.key,
    required this.data,
    required this.isOutgoing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = (data['name'] as String?)?.trim().isNotEmpty == true
        ? (data['name'] as String).trim()
        : 'Набор эмодзи';
    final raw = (data['emojis'] as List?) ?? const [];
    final previews = <Uint8List>[];
    for (final e in raw.take(12)) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final b64 = m['data'] as String? ?? '';
      if (b64.isEmpty) continue;
      try {
        previews.add(base64Decode(b64));
      } catch (_) {}
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOutgoing
            ? Colors.black.withValues(alpha: 0.12)
            : cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOutgoing
              ? Colors.white.withValues(alpha: 0.25)
              : cs.outline.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.emoji_emotions_outlined,
                  size: 20,
                  color: isOutgoing ? cs.onPrimary : cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: isOutgoing ? cs.onPrimary : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (previews.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final bytes in previews)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      bytes,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                final id = await EmojiPackService.instance
                    .installFromSharePayload(Map<String, dynamic>.from(data));
                if (!context.mounted) return;
                if (id == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Не удалось установить набор'),
                      backgroundColor: Colors.red,
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Набор установлен (id: $id)')),
                  );
                }
              },
              child: const Text('Установить'),
            ),
          ),
        ],
      ),
    );
  }
}
