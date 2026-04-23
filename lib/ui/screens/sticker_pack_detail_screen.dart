import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/sticker_pack.dart';
import '../../services/sticker_collection_service.dart';
import 'sticker_pack_editor_screen.dart';

class StickerPackDetailScreen extends StatefulWidget {
  final String packId;

  const StickerPackDetailScreen({super.key, required this.packId});

  @override
  State<StickerPackDetailScreen> createState() =>
      _StickerPackDetailScreenState();
}

class _StickerPackDetailScreenState extends State<StickerPackDetailScreen> {
  StickerPack? _pack;
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    StickerCollectionService.instance.version.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    StickerCollectionService.instance.version.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final p = await StickerCollectionService.instance.packById(widget.packId);
    final files =
        await StickerCollectionService.instance.stickerFilesForPack(widget.packId);
    if (mounted) {
      setState(() {
        _pack = p;
        _files = files;
        _loading = false;
      });
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить набор?'),
        content: const Text(
          'Стикеры останутся в общей коллекции, удалится только группировка.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await StickerCollectionService.instance.deletePack(widget.packId);
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Набор')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final pack = _pack;
    if (pack == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Набор')),
        body: const Center(child: Text('Набор не найден')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(pack.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => StickerPackEditorScreen(packId: pack.id),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pack.sourcePeerLabel != null ||
              pack.sourcePeerId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Источник: ${pack.sourcePeerLabel ?? pack.sourcePeerId ?? ''}',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '${_files.length} стикеров',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: _files.length,
              itemBuilder: (context, i) {
                final f = _files[i];
                return ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(f, fit: BoxFit.cover),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
