import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/emoji_pack.dart';
import '../../services/emoji_pack_service.dart';
import 'emoji_pack_detail_screen.dart';

/// Список наборов кастомных эмодзи.
class EmojiHubScreen extends StatefulWidget {
  const EmojiHubScreen({super.key});

  @override
  State<EmojiHubScreen> createState() => _EmojiHubScreenState();
}

class _EmojiHubScreenState extends State<EmojiHubScreen> {
  List<EmojiPack> _packs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    EmojiPackService.instance.version.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    EmojiPackService.instance.version.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    await EmojiPackService.instance.ensureInitialized();
    final packs = await EmojiPackService.instance.loadPacks();
    if (mounted) {
      setState(() {
        _packs = packs;
        _loading = false;
      });
    }
  }

  Future<void> _createPack() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый набор'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Название',
            hintText: 'Мои эмодзи',
          ),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final id =
        await EmojiPackService.instance.createPack(name: name.isEmpty ? 'Набор' : name);
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EmojiPackDetailScreen(packId: id),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Эмодзи'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createPack,
        icon: const Icon(Icons.add),
        label: const Text('Новый набор'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _packs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Пока нет наборов.\nСоздайте набор здесь или в чате с ботом Emoji.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                  itemCount: _packs.length,
                  itemBuilder: (context, i) {
                    final p = _packs[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.primaryContainer,
                          child: Icon(Icons.tag_faces, color: cs.onPrimaryContainer),
                        ),
                        title: Text(p.name),
                        subtitle: Text('${p.emojis.length} эмодзи · ${p.id}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => EmojiPackDetailScreen(packId: p.id),
                            ),
                          );
                          await _reload();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
