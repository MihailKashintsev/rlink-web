import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/sticker_collection_service.dart';

/// Карточка набора стикеров в пузыре ЛС: превью и импорт.
class StickerPackCardBubble extends StatelessWidget {
  final Map<String, dynamic> payload;
  final bool isOutgoing;
  final ColorScheme colorScheme;
  final String? sourcePeerId;
  final String? sourcePeerLabel;

  const StickerPackCardBubble({
    super.key,
    required this.payload,
    required this.isOutgoing,
    required this.colorScheme,
    this.sourcePeerId,
    this.sourcePeerLabel,
  });

  String get _title {
    final t = (payload['title'] as String?)?.trim();
    if (t == null || t.isEmpty) return 'Набор стикеров';
    return t;
  }

  List<Map<String, dynamic>> get _stickerEntries {
    final raw = payload['stickers'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final fg = isOutgoing ? colorScheme.onPrimary : colorScheme.onSurface;
    final muted =
        isOutgoing ? fg.withValues(alpha: 0.85) : colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('🩵 ', style: TextStyle(fontSize: 18, color: fg)),
            Expanded(
              child: Text(
                _title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _PreviewRow(entries: _stickerEntries, fg: fg),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () => unawaited(_addPack(context)),
          style: FilledButton.styleFrom(
            foregroundColor: isOutgoing ? colorScheme.primary : null,
            backgroundColor: isOutgoing
                ? colorScheme.onPrimary.withValues(alpha: 0.2)
                : null,
          ),
          child: const Text('Добавить пак'),
        ),
        if (sourcePeerLabel != null || sourcePeerId != null) ...[
          const SizedBox(height: 6),
          Text(
            'От: ${sourcePeerLabel ?? sourcePeerId ?? ''}',
            style: TextStyle(fontSize: 11, color: muted),
          ),
        ],
      ],
    );
  }

  Future<void> _addPack(BuildContext context) async {
    final entries = _stickerEntries;
    if (entries.isEmpty) {
      _snack(context, 'В наборе нет данных');
      return;
    }
    final tmp = await getTemporaryDirectory();
    final absPaths = <String>[];
    try {
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        final b64 = e['bytes'] as String?;
        if (b64 == null || b64.isEmpty) continue;
        final rel = (e['rel'] as String?) ?? 'sticker_$i';
        final ext = p.extension(rel);
        final safeExt =
            ext.isNotEmpty && ext.length <= 6 ? ext.toLowerCase() : '.png';
        final f = File(
            '${tmp.path}/import_${DateTime.now().microsecondsSinceEpoch}_$i$safeExt');
        await f.writeAsBytes(base64Decode(b64));
        absPaths.add(f.path);
      }
      if (absPaths.isEmpty) {
        _snack(context, 'Не удалось прочитать стикеры');
        return;
      }
      await StickerCollectionService.instance.importPackFromAbsolutePaths(
        title: _title,
        absPaths: absPaths,
        sourcePeerId: sourcePeerId,
        sourcePeerLabel: sourcePeerLabel,
      );
      if (!context.mounted) return;
      _snack(context, 'Набор добавлен');
    } catch (e) {
      if (!context.mounted) return;
      _snack(context, 'Ошибка: $e');
    }
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _PreviewRow extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final Color fg;

  const _PreviewRow({required this.entries, required this.fg});

  @override
  Widget build(BuildContext context) {
    final n = math.min(4, entries.length);
    if (n == 0) {
      return Text(
        'Нет превью',
        style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.7)),
      );
    }
    return Row(
      children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _PreviewTile(entry: entries[i]),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PreviewTile extends StatelessWidget {
  final Map<String, dynamic> entry;

  const _PreviewTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final b64 = entry['bytes'] as String?;
    if (b64 == null || b64.isEmpty) {
      return ColoredBox(
        color: Colors.grey.shade800,
        child: const Icon(Icons.image_not_supported_outlined, size: 28),
      );
    }
    try {
      final bytes = base64Decode(b64);
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => ColoredBox(
          color: Colors.grey.shade700,
          child: const Icon(Icons.broken_image_outlined),
        ),
      );
    } catch (_) {
      return ColoredBox(
        color: Colors.grey.shade800,
        child: const Icon(Icons.error_outline, size: 28),
      );
    }
  }
}
