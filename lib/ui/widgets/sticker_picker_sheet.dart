import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/sticker_pack.dart';
import '../../services/sticker_collection_service.dart';

/// Нижняя панель выбора стикера: вкладки по наборам, сетка файлов.
Future<void> showStickerPickerSheet(
  BuildContext context, {
  required Future<void> Function(String absolutePath) onPickedSticker,
}) async {
  await StickerCollectionService.instance.init();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final h = MediaQuery.sizeOf(ctx).height * 0.58;
      return SafeArea(
        child: SizedBox(
          height: h,
          child: FutureBuilder<List<StickerPack>>(
            future: StickerCollectionService.instance.loadPacks(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final packs = snap.data ?? const <StickerPack>[];
              if (packs.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Нет наборов. Создайте набор в разделе стикеров.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              }
              return DefaultTabController(
                length: packs.length,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: TabBar(
                        isScrollable: true,
                        tabs: [
                          for (final p in packs) Tab(text: _shortPackTitle(p.title)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          for (final pack in packs)
                            _StickerPackPickerGrid(
                              packId: pack.id,
                              onPicked: (abs) async {
                                Navigator.pop(ctx);
                                await onPickedSticker(abs);
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

String _shortPackTitle(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return 'Набор';
  if (s.length <= 16) return s;
  return '${s.substring(0, 14)}…';
}

class _StickerPackPickerGrid extends StatelessWidget {
  final String packId;
  final Future<void> Function(String absolutePath) onPicked;

  const _StickerPackPickerGrid({
    required this.packId,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<File>>(
      future: StickerCollectionService.instance.stickerFilesForPack(packId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snap.data ?? const <File>[];
        if (files.isEmpty) {
          return Center(
            child: Text(
              'В наборе нет файлов',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: files.length,
          itemBuilder: (context, i) {
            final f = files[i];
            return Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onPicked(f.path),
                child: Image.file(
                  f,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Center(
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
