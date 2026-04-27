import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../l10n/app_l10n.dart';
import '../../services/app_storage_breakdown_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/group_service.dart';
import '../../services/media_upload_queue.dart';
import '../../services/rlink_app_reset.dart';
import '../../services/runtime_platform.dart';
import '../widgets/message_cache_clear_dialog.dart';
import '../widgets/storage_donut_chart.dart';

/// Раздел «Данные»: диаграмма занятости и выборочная очистка.
class SettingsDataPage extends StatefulWidget {
  const SettingsDataPage({super.key});

  @override
  State<SettingsDataPage> createState() => _SettingsDataPageState();
}

class _SettingsDataPageState extends State<SettingsDataPage> {
  Future<AppStorageBreakdown>? _scan;
  int? _selectedSlice;

  @override
  void initState() {
    super.initState();
    _scan = scanAppStorageBreakdown();
  }

  void _reload() {
    setState(() {
      _selectedSlice = null;
      _scan = scanAppStorageBreakdown();
    });
  }

  Future<void> _confirm({
    required String title,
    required String description,
    required Future<void> Function() action,
    bool destructive = false,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppL10n.t('cancel')),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () async {
              Navigator.pop(ctx);
              await action();
            },
            child: Text(destructive ? AppL10n.t('reset') : AppL10n.t('confirm')),
          ),
        ],
      ),
    );
  }

  Future<Database> _getDb() async {
    if (RuntimePlatform.isWeb) {
      return openDatabase('rlink.db');
    }
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(p.join(dir.path, 'rlink.db'));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8),
      appBar: AppBar(
        title: Text(AppL10n.t('settings_data')),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor:
            isDark ? const Color(0xFF121212) : const Color(0xFFF2F2F2),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Пересчитать',
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<AppStorageBreakdown>(
        future: _scan,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null) {
            return const Center(child: Text('Не удалось загрузить'));
          }
          if (data.isWebPlaceholder) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'В веб-версии оценка места на диске недоступна.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
            children: [
              Text(
                'Нажмите на сектор кольца или выберите пункт в списке, затем «Очистить».',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              StorageDonutChart(
                segments: data.segments,
                selectedIndex: _selectedSlice,
                onSelect: (i) => setState(() => _selectedSlice = i),
              ),
              const SizedBox(height: 20),
              ...data.segments.asMap().entries.map((e) {
                final i = e.key;
                final s = e.value;
                final pct = data.totalBytes > 0
                    ? (100 * s.bytes / data.totalBytes).clamp(0, 100.0)
                    : 0.0;
                final selected = _selectedSlice == i;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  elevation: selected ? 2 : 0,
                  child: ListTile(
                    onTap: () => setState(() {
                      _selectedSlice = selected ? null : i;
                    }),
                    leading: CircleAvatar(
                      backgroundColor: Color(s.argbColor).withValues(alpha: 0.2),
                      child: Icon(Icons.circle, color: Color(s.argbColor), size: 18),
                    ),
                    title: Text(s.title),
                    subtitle: Text(
                      '${pct.toStringAsFixed(1)}% · ${formatStorageBytes(s.bytes)}\n${s.subtitle}',
                      style: const TextStyle(fontSize: 12, height: 1.25),
                    ),
                    isThreeLine: true,
                    trailing: _clearButton(context, s, i),
                  ),
                );
              }),
              const SizedBox(height: 16),
              _SectionHeader(AppL10n.t('settings_danger')),
              ListTile(
                leading: const Icon(Icons.restore, color: Colors.red),
                title: Text(
                  AppL10n.t('settings_reset'),
                  style: const TextStyle(color: Colors.red),
                ),
                subtitle: Text(
                  AppL10n.t('settings_reset_sub'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                onTap: () => _confirm(
                  title: AppL10n.t('settings_reset'),
                  description: AppL10n.t('settings_reset_sub'),
                  destructive: true,
                  action: () async {
                    await rlinkPerformFullAppReset(context);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget? _clearButton(BuildContext context, AppStorageSegment s, int index) {
    if (s.id == 'databases') {
      return FilledButton.tonal(
        onPressed: () => _openDatabaseCleanupSheet(context),
        child: const Text('Очистить…'),
      );
    }
    if (s.id == 'other') {
      return FilledButton.tonal(
        onPressed: () => _openOtherCleanupSheet(context),
        child: const Text('Очистить…'),
      );
    }
    if (s.bytes <= 0) {
      return Text(
        '—',
        style: TextStyle(color: Theme.of(context).hintColor),
      );
    }
    return FilledButton.tonal(
      onPressed: () => _runClear(context, s.id),
      child: const Text('Очистить'),
    );
  }

  Future<void> _runClear(BuildContext context, String id) async {
    if (id == 'databases' || id == 'other') return;
    await _confirm(
      title: 'Очистить данные?',
      description: 'Файлы этого типа будут удалены с устройства.',
      action: () async {
        try {
          await clearStorageSegment(
            id,
            onMessage: (m) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
              }
            },
          );
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
            );
          }
        }
        _reload();
      },
    );
  }

  Future<void> _openDatabaseCleanupSheet(BuildContext ctx) async {
    await showModalBottomSheet<void>(
      context: ctx,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              title: Text('Базы SQLite'),
              subtitle: Text(
                'Выберите, что очистить. Контакты и каналы как объекты можно сохранить — удаляется в основном содержимое.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: Text(AppL10n.t('settings_clear_history')),
              subtitle: Text(AppL10n.t('settings_clear_history_sub'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await _confirm(
                  title: AppL10n.t('settings_clear_history'),
                  description: AppL10n.t('settings_clear_history_sub'),
                  action: () async {
                    final db = await _getDb();
                    await db.delete('messages');
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text(AppL10n.t('snack_history_cleared'))),
                      );
                    }
                    _reload();
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: const Text('Удалить все сообщения групп'),
              subtitle: const Text(
                'Группы и участники останутся',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await _confirm(
                  title: 'Удалить сообщения групп?',
                  description: 'История всех групп будет удалена локально.',
                  action: () async {
                    await GroupService.instance.deleteAllGroupMessages();
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Сообщения групп удалены')),
                      );
                    }
                    _reload();
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: const Text('Удалить посты и комментарии каналов'),
              subtitle: const Text(
                'Список каналов сохранится',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await _confirm(
                  title: 'Удалить посты каналов?',
                  description:
                      'Все посты и комментарии будут удалены локально; каналы останутся.',
                  action: () async {
                    await ChannelService.instance.deleteAllPostsAndComments();
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Посты каналов удалены')),
                      );
                    }
                    _reload();
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Очистить очередь загрузок медиа'),
              subtitle: const Text(
                'Незавершённые отправки файлов в ретранслятор',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await MediaUploadQueue.instance.clearAll();
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Очередь загрузок очищена')),
                  );
                }
                _reload();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_sweep_outlined, color: Theme.of(ctx).colorScheme.error),
              title: Text(AppL10n.t('settings_delete_contacts')),
              subtitle: Text(AppL10n.t('settings_delete_contacts_sub'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await _confirm(
                  title: AppL10n.t('settings_delete_contacts'),
                  description: AppL10n.t('settings_delete_contacts_sub'),
                  action: () async {
                    final db = await _getDb();
                    await db.delete('contacts');
                    await ChatStorageService.instance.loadContacts();
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text(AppL10n.t('snack_contacts_deleted'))),
                      );
                    }
                    _reload();
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openOtherCleanupSheet(BuildContext ctx) async {
    await showModalBottomSheet<void>(
      context: ctx,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Прочее на диске'),
              subtitle: Text(
                'Сюда входят фоны чатов, аватары и файлы вне базы сообщений.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: Text(AppL10n.t('settings_clear_convo_cache')),
              subtitle: Text(AppL10n.t('settings_clear_convo_cache_sub'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(sheetCtx);
                showMessageCacheClearDialog(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).hintColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
