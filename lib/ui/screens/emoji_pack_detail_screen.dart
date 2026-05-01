import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/emoji_pack.dart';
import '../../services/emoji_pack_service.dart';

class EmojiPackDetailScreen extends StatefulWidget {
  final String packId;

  const EmojiPackDetailScreen({super.key, required this.packId});

  @override
  State<EmojiPackDetailScreen> createState() => _EmojiPackDetailScreenState();
}

class _EmojiPackDetailScreenState extends State<EmojiPackDetailScreen> {
  EmojiPack? _pack;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    EmojiPackService.instance.version.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    EmojiPackService.instance.version.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final p = await EmojiPackService.instance.packById(widget.packId);
    if (mounted) {
      setState(() {
        _pack = p;
        _loading = false;
      });
    }
  }

  Future<void> _rename() async {
    final pack = _pack;
    if (pack == null) return;
    final ctrl = TextEditingController(text: pack.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Название'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    await EmojiPackService.instance.renamePack(widget.packId, name);
    await _reload();
  }

  Future<void> _deletePack() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить набор?'),
        content: const Text('Файлы эмодзи будут удалены с устройства.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await EmojiPackService.instance.deletePack(widget.packId);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _confirmDeleteEmoji(CustomEmoji e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить :${e.shortcode}:?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await EmojiPackService.instance.deleteEmoji(widget.packId, e.shortcode);
    await _reload();
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
        title: Text(pack.name),
        actions: [
          IconButton(icon: const Icon(Icons.drive_file_rename_outline), onPressed: _rename),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _deletePack,
          ),
        ],
      ),
      body: pack.emojis.isEmpty
          ? Center(
              child: Text(
                'Пусто. Добавьте эмодзи в чате с ботом Emoji:\n'
                '/pack ${pack.id}\n'
                '/add :код:\n'
                'затем отправьте картинку.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.85,
              ),
              itemCount: pack.emojis.length,
              itemBuilder: (context, i) {
                final e = pack.emojis[i];
                return FutureBuilder<String?>(
                  future: _abs(e),
                  builder: (context, snap) {
                    final path = snap.data;
                    return InkWell(
                      onLongPress: () => _confirmDeleteEmoji(e),
                      borderRadius: BorderRadius.circular(10),
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: path != null && File(path).existsSync()
                                  ? Image.file(
                                      File(path),
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                    )
                                  : Container(
                                      color: cs.surfaceContainerHighest,
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.broken_image_outlined),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ':${e.shortcode}:',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Future<String?> _abs(CustomEmoji e) async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, e.relPath);
  }
}
