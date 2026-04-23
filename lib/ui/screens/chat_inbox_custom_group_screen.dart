import 'package:flutter/material.dart';

import '../../services/chat_inbox_service.dart';

/// Создание пользовательской вкладки: выбор чатов, групп и каналов.
class ChatInboxCustomGroupScreen extends StatefulWidget {
  const ChatInboxCustomGroupScreen({super.key});

  @override
  State<ChatInboxCustomGroupScreen> createState() =>
      _ChatInboxCustomGroupScreenState();
}

class _ChatInboxCustomGroupScreenState extends State<ChatInboxCustomGroupScreen> {
  List<ChatInboxPickRow>? _rows;
  final _selected = <String>{};
  final _nameCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await loadChatInboxPickRows();
    if (mounted) {
      setState(() {
        _rows = r;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите хотя бы один чат')),
      );
      return;
    }
    await ChatInboxService.instance
        .addCustomTab(_nameCtrl.text.trim(), _selected.toList());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Новая группа'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Готово'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Название вкладки',
                      border: OutlineInputBorder(),
                    ),
                    maxLength: 32,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _rows!.length,
                    itemBuilder: (context, i) {
                      final row = _rows![i];
                      final on = _selected.contains(row.storageKey);
                      return CheckboxListTile(
                        value: on,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(row.storageKey);
                            } else {
                              _selected.remove(row.storageKey);
                            }
                          });
                        },
                        secondary: Icon(row.icon),
                        title: Text(row.title),
                        subtitle: Text(
                          switch (row.kind) {
                            ChatInboxItemKind.dm => 'Личный чат',
                            ChatInboxItemKind.group => 'Группа',
                            ChatInboxItemKind.channel => 'Канал',
                            ChatInboxItemKind.saved => 'Избранное',
                          },
                          style: const TextStyle(fontSize: 12),
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
