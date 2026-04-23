import 'package:flutter/material.dart';

import '../../services/chat_inbox_service.dart';
import '../rlink_nav_routes.dart';
import 'chat_inbox_custom_group_screen.dart';

/// Упорядочивание и удаление вкладок фильтров; добавление своей группы.
class ChatInboxFiltersManageScreen extends StatelessWidget {
  const ChatInboxFiltersManageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inbox = ChatInboxService.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Фильтры чатов'),
        actions: [
          TextButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Сбросить фильтры?'),
                  content: const Text(
                    'Вернётся набор «Все», «Чаты», «Каналы», «Группы».',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Отмена'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Сбросить'),
                    ),
                  ],
                ),
              );
              if (ok == true) await inbox.resetDefaultTabs();
            },
            child: const Text('Сброс'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: inbox,
        builder: (context, _) {
          final tabs = inbox.tabs;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Удерживайте и перетащите, чтобы изменить порядок вкладок на главном экране. '
                  'Свайп влево или кнопка удаляет вкладку.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: tabs.length,
                  onReorder: (o, n) => inbox.reorderTabs(o, n),
                  itemBuilder: (context, i) {
                    final t = tabs[i];
                    final label = inbox.tabLabel(t);
                    return ListTile(
                      key: ValueKey('tile_${t.id}'),
                      leading: const Icon(Icons.drag_handle),
                      title: Text(label),
                      subtitle: t.preset == null
                          ? Text(
                              '${t.customMemberKeys.length} чатов',
                              style: const TextStyle(fontSize: 12),
                            )
                          : const Text('Встроенный фильтр',
                              style: TextStyle(fontSize: 12)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Удалить вкладку?'),
                              content: Text('«$label»'),
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
                          if (ok == true) await inbox.removeTab(t.id);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push<void>(
            context,
            rlinkPushRoute(const ChatInboxCustomGroupScreen()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('Своя группа'),
      ),
    );
  }
}
