import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/sticker_collection_service.dart';

/// Создание набора ([packId] == null) или редактирование.
class StickerPackEditorScreen extends StatefulWidget {
  final String? packId;

  const StickerPackEditorScreen({super.key, this.packId});

  @override
  State<StickerPackEditorScreen> createState() =>
      _StickerPackEditorScreenState();
}

class _StickerPackEditorScreenState extends State<StickerPackEditorScreen> {
  final _titleCtrl = TextEditingController();
  List<String> _selectedRels = [];
  List<File> _allLibraryFiles = [];
  bool _loading = true;

  bool get _isEdit => widget.packId != null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await StickerCollectionService.instance.init();
    final files =
        await StickerCollectionService.instance.stickerFilesNewestFirst();
    List<String> initial = [];
    String title = '';
    if (widget.packId != null) {
      final pack =
          await StickerCollectionService.instance.packById(widget.packId!);
      if (pack != null) {
        title = pack.title;
        initial = List<String>.from(pack.stickerRelPaths);
      }
    }
    if (mounted) {
      setState(() {
        _allLibraryFiles = files;
        _selectedRels = initial;
        _titleCtrl.text = title;
        _loading = false;
      });
    }
  }

  Future<String?> _relForFile(File f) async {
    final docs = await getApplicationDocumentsDirectory();
    final norm = p.normalize(f.path);
    if (!norm.startsWith(docs.path)) return null;
    return p.relative(norm, from: docs.path);
  }

  Future<void> _openMultiPicker() async {
    final relByFile = <String, String>{};
    for (final f in _allLibraryFiles) {
      final r = await _relForFile(f);
      if (r != null) relByFile[f.path] = r;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final sel = Set<String>.from(_selectedRels);
        return StatefulBuilder(
          builder: (ctx, setModal) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              minChildSize: 0.5,
              builder: (_, scrollCtrl) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, sel),
                            child: const Text('Готово'),
                          ),
                          const Spacer(),
                          Text(
                            '${sel.length} выбрано',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: _allLibraryFiles.length,
                        itemBuilder: (context, i) {
                          final f = _allLibraryFiles[i];
                          final rel = relByFile[f.path];
                          if (rel == null) {
                            return const SizedBox.shrink();
                          }
                          final on = sel.contains(rel);
                          return GestureDetector(
                            onTap: () {
                              setModal(() {
                                if (on) {
                                  sel.remove(rel);
                                } else {
                                  sel.add(rel);
                                }
                              });
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.file(f, fit: BoxFit.cover),
                                ),
                                if (on)
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Theme.of(ctx).colorScheme.primary,
                                        width: 3,
                                      ),
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.2),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
    if (chosen != null && mounted) {
      final ordered = <String>[];
      for (final f in _allLibraryFiles) {
        final r = relByFile[f.path];
        if (r != null && chosen.contains(r)) ordered.add(r);
      }
      setState(() => _selectedRels = ordered);
    }
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название набора')),
      );
      return;
    }
    if (_selectedRels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите хотя бы один стикер')),
      );
      return;
    }
    if (_isEdit) {
      await StickerCollectionService.instance.renamePack(
        widget.packId!,
        title,
      );
      await StickerCollectionService.instance.setPackStickerRels(
        widget.packId!,
        _selectedRels,
      );
    } else {
      await StickerCollectionService.instance.createPack(
        title: title,
        relPaths: _selectedRels,
      );
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_isEdit ? 'Редактировать набор' : 'Новый набор'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Редактировать набор' : 'Новый набор'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Название набора',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _allLibraryFiles.isEmpty ? null : _openMultiPicker,
            icon: const Icon(Icons.grid_view),
            label: Text(
              _selectedRels.isEmpty
                  ? 'Выбрать стикеры из коллекции'
                  : 'Изменить выбор (${_selectedRels.length})',
            ),
          ),
          if (_allLibraryFiles.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                'В коллекции пока нет стикеров. Отправьте или сохраните стикер из чата.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
