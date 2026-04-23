import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../services/chat_storage_service.dart';
import '../../services/image_service.dart';
import '../../services/sticker_collection_service.dart';

/// Стикеры из переписки с контактом: просмотр и добавление к себе набором.
class PeerStickersScreen extends StatefulWidget {
  final String peerId;
  final String peerName;

  const PeerStickersScreen({
    super.key,
    required this.peerId,
    required this.peerName,
  });

  @override
  State<PeerStickersScreen> createState() => _PeerStickersScreenState();
}

class _PeerStickersScreenState extends State<PeerStickersScreen> {
  List<ChatMessage> _msgs = [];
  final Set<String> _selectedAbs = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final list = await ChatStorageService.instance
        .getStickerMessagesForPeer(widget.peerId);
    if (mounted) {
      setState(() {
        _msgs = list;
        _loading = false;
      });
    }
  }

  List<String> get _orderedPaths {
    final seen = <String>{};
    final out = <String>[];
    for (final m in _msgs) {
      final ip = m.imagePath;
      if (ip == null) continue;
      final resolved = ImageService.instance.resolveStoredPath(ip) ?? ip;
      if (!File(resolved).existsSync()) continue;
      if (seen.contains(resolved)) continue;
      seen.add(resolved);
      out.add(resolved);
    }
    return out;
  }

  void _selectAll() {
    setState(() {
      _selectedAbs
        ..clear()
        ..addAll(_orderedPaths);
    });
  }

  void _clearSel() {
    setState(() => _selectedAbs.clear());
  }

  Future<void> _addPack() async {
    if (_selectedAbs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отметьте стикеры или нажмите «Все»')),
      );
      return;
    }
    final titleCtrl = TextEditingController(
      text: '${widget.peerName} — набор',
    );
    bool? ok;
    var title = '';
    try {
      ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Добавить набор к себе'),
          content: TextField(
            controller: titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Название',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Добавить'),
            ),
          ],
        ),
      );
      if (ok == true) title = titleCtrl.text.trim();
    } finally {
      titleCtrl.dispose();
    }
    if (ok != true || !mounted) return;
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название')),
      );
      return;
    }
    try {
      await StickerCollectionService.instance.importPackFromAbsolutePaths(
        title: title,
        absPaths: _selectedAbs.toList(),
        sourcePeerId: widget.peerId,
        sourcePeerLabel: widget.peerName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Набор «$title» добавлен')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final paths = _orderedPaths;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Стикеры: ${widget.peerName}'),
        actions: [
          if (paths.isNotEmpty)
            TextButton(
              onPressed: _selectedAbs.length == paths.length
                  ? _clearSel
                  : _selectAll,
              child: Text(
                _selectedAbs.length == paths.length ? 'Снять все' : 'Все',
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: paths.isEmpty ? null : _addPack,
            icon: const Icon(Icons.library_add_outlined),
            label: Text(
              _selectedAbs.isEmpty
                  ? 'Добавить к себе'
                  : 'Добавить выбранные (${_selectedAbs.length})',
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : paths.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'В чате с этим контактом пока нет стикеров '
                      '(картинки с именем stk_…).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(
                        'Нажмите на стикеры, которые хотите сохранить у себя в наборе. '
                        'Они копируются в вашу коллекцию.',
                        style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: paths.length,
                        itemBuilder: (context, i) {
                          final path = paths[i];
                          final on = _selectedAbs.contains(path);
                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                if (on) {
                                  _selectedAbs.remove(path);
                                } else {
                                  _selectedAbs.add(path);
                                }
                              });
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.file(
                                    File(path),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                if (on)
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: cs.primary,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
