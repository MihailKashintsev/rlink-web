import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../../services/channel_backup_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/google_drive_channel_backup.dart';
import '../../services/gossip_router.dart';
import '../widgets/channel_staff_links_sheet.dart';
import 'channel_profile_edit_dialog.dart';

/// Настройки канала для владельца (пункты бывшего меню «⋯» в ленте).
class ChannelAdminSettingsScreen extends StatefulWidget {
  final String channelId;

  const ChannelAdminSettingsScreen({super.key, required this.channelId});

  @override
  State<ChannelAdminSettingsScreen> createState() =>
      _ChannelAdminSettingsScreenState();
}

class _ChannelAdminSettingsScreenState extends State<ChannelAdminSettingsScreen> {
  Channel? _channel;
  GoogleDriveSyncStatus? _driveStatus;
  bool _driveRefreshing = false;

  String get _myId => CryptoService.instance.publicKeyHex;

  @override
  void initState() {
    super.initState();
    _load();
    ChannelService.instance.version.addListener(_load);
  }

  @override
  void dispose() {
    ChannelService.instance.version.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final ch = await ChannelService.instance.getChannel(widget.channelId);
    if (!mounted) return;
    setState(() => _channel = ch);
    if (ch != null &&
        ch.adminId == _myId &&
        ch.driveBackupEnabled) {
      final st =
          await GoogleDriveChannelBackup.getSyncStatus(interactive: false);
      if (mounted) setState(() => _driveStatus = st);
    } else if (mounted) {
      setState(() => _driveStatus = null);
    }
  }

  Future<void> _refreshDriveQuota() async {
    setState(() => _driveRefreshing = true);
    try {
      final st =
          await GoogleDriveChannelBackup.getSyncStatus(interactive: true);
      if (!mounted) return;
      setState(() => _driveStatus = st);
      if (st == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось связаться с Google Drive. Проверьте интернет и '
              'что в аккаунте Google включён доступ к Диску для Rlink.',
            ),
          ),
        );
      } else if (st.email != null &&
          st.email!.isNotEmpty &&
          st.limitBytes == null &&
          st.usageBytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Вход выполнен, но нет доступа к Диску. Нажмите снова и '
              'разрешите доступ к Google Drive в запросе прав.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _driveRefreshing = false);
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} ГБ';
    }
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} МБ';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    }
    return '$bytes Б';
  }

  String _driveFreeSubtitle() {
    final s = _driveStatus;
    if (s == null) return 'Загрузка…';
    if (s.email == null || s.email!.isEmpty) {
      return 'Войдите через кнопку обновления, чтобы увидеть квоту';
    }
    if (s.limitBytes == null || s.limitBytes! <= 0) {
      return 'Размер хранилища недоступен для этого аккаунта';
    }
    if (s.usageBytes == null || s.freeBytes == null) {
      return 'Нажмите «обновить», чтобы загрузить квоту';
    }
    return '${_fmtBytes(s.freeBytes!)} свободно из ${_fmtBytes(s.limitBytes!)} '
        '(занято ${_fmtBytes(s.usageBytes!)})';
  }

  bool get _canTransferOwnership {
    final ch = _channel;
    if (ch == null) return false;
    return ch.subscriberIds.any((id) => id != ch.adminId);
  }

  Future<void> _toggleComments() async {
    final ch = _channel;
    if (ch == null) return;
    final updated = ch.copyWith(commentsEnabled: !ch.commentsEnabled);
    await ChannelService.instance.updateChannel(updated);
    await updated.broadcastGossipMeta();
    await _load();
  }

  Future<void> _requestVerification() async {
    final ch = _channel;
    if (ch == null || ch.verified) return;
    final canAutoVerify = ChannelService.instance.checkAutoVerify(ch);
    if (canAutoVerify) {
      await ChannelService.instance.verifyChannel(ch.id, 'auto');
      await ch
          .copyWith(verified: true, verifiedBy: 'auto')
          .broadcastGossipMeta();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Канал верифицирован!')),
        );
      }
    } else {
      await GossipRouter.instance.sendVerificationRequest(
        channelId: ch.id,
        channelName: ch.name,
        adminId: ch.adminId,
        subscriberCount: ch.subscriberIds.length,
        avatarEmoji: ch.avatarEmoji,
        description: ch.description,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Заявка на верификацию отправлена администраторам сети'),
          ),
        );
      }
    }
    await _load();
  }

  Future<void> _deleteChannel() async {
    final ch = _channel;
    if (ch == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить канал?'),
        content: const Text('Канал и все посты будут удалены навсегда.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await ChannelService.instance.deleteChannel(ch.id);
    if (mounted) Navigator.pop(context);
  }

  void _showLeaveHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Чтобы выйти без удаления канала, сначала передайте владение '
          'ниже, затем откройте профиль канала и нажмите «Отписаться».',
        ),
      ),
    );
  }

  Future<void> _openEditDialog() async {
    final ch = _channel;
    if (ch == null) return;
    await showChannelProfileEditDialog(
      context,
      channel: ch,
      showPolicyToggles: true,
      myId: _myId,
      onChannelUpdated: (updated) {
        if (mounted) setState(() => _channel = updated);
      },
    );
    await _load();
  }

  void _manageSubscribers() {
    final ch = _channel;
    if (ch == null) return;
    final contacts = ChatStorageService.instance.contactsNotifier.value;

    String nickFor(String id) {
      for (final c in contacts) {
        if (c.publicKeyHex == id) return c.nickname;
      }
      return '${id.substring(0, 8)}…';
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setModal) {
          final current = ch.subscriberIds
              .where((id) => id != ch.adminId && id != _myId)
              .toList();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Подписчики канала',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (current.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx2).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: current.length,
                      itemBuilder: (_, i) {
                        final uid = current[i];
                        final isMod = ch.moderatorIds.contains(uid);
                        return ListTile(
                          title: Text(nickFor(uid)),
                          subtitle: Text(
                            isMod
                                ? 'Модератор · ${uid.substring(0, 12)}…'
                                : '${uid.substring(0, 12)}…',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_remove_outlined,
                                color: Colors.red),
                            tooltip: 'Исключить',
                            onPressed: () async {
                              await ChannelService.instance
                                  .removeSubscriber(ch.id, uid);
                              final fresh =
                                  await ChannelService.instance.getChannel(ch.id);
                              if (fresh != null && mounted) {
                                setState(() => _channel = fresh);
                                setModal(() {});
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        });
      },
    );
  }

  void _manageModerators() {
    final ch = _channel;
    if (ch == null) return;
    final subscribers =
        ch.subscriberIds.where((id) => id != ch.adminId).toList();
    final contacts = ChatStorageService.instance.contactsNotifier.value;

    String nickFor(String id) {
      if (id == _myId) return 'Вы';
      for (final c in contacts) {
        if (c.publicKeyHex == id) return c.nickname;
      }
      return '${id.substring(0, 8)}…';
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setModal) {
          final mods = ch.moderatorIds;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Модераторы канала',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (subscribers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков для назначения',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx2).size.height * 0.5,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: subscribers.length,
                      itemBuilder: (_, i) {
                        final uid = subscribers[i];
                        final isMod = mods.contains(uid);
                        return SwitchListTile(
                          title: Text(nickFor(uid)),
                          subtitle: Text(
                            '${uid.substring(0, 12)}…',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                          value: isMod,
                          onChanged: (val) async {
                            final updated = await ChannelService.instance
                                .setModerator(ch.id, uid, val);
                            if (updated != null && mounted) {
                              setState(() => _channel = updated);
                              setModal(() {});
                              unawaited(updated.broadcastGossipMeta());
                            }
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        });
      },
    );
  }

  void _manageStaffAndLinks() {
    final ch = _channel;
    if (ch == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StaffLinksEditorSheet(
        channel: ch,
        myId: _myId,
        onChannelRefreshed: (fresh) {
          if (mounted) setState(() => _channel = fresh);
        },
      ),
    );
  }

  Future<void> _showTransferOwnershipDialog() async {
    final ch = _channel;
    if (ch == null || !_canTransferOwnership) return;

    final candidates =
        ch.subscriberIds.where((id) => id != ch.adminId).toList();
    if (candidates.isEmpty) return;

    final contacts = ChatStorageService.instance.contactsNotifier.value;
    String nickFor(String id) {
      for (final c in contacts) {
        if (c.publicKeyHex == id) return c.nickname;
      }
      return '${id.substring(0, 8)}…';
    }

    String? picked = candidates.first;
    var backupFirst = true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Передать владение'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Новый владелец получит права администратора. '
                  'Рекомендуется сделать полный резерв истории на ваш Google Диск '
                  'пока у вас есть доступ админа — затем данные можно импортировать под новым аккаунтом при необходимости.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: picked,
                  decoration: const InputDecoration(
                    labelText: 'Новый владелец',
                    border: OutlineInputBorder(),
                  ),
                  items: candidates
                      .map((id) => DropdownMenuItem(
                            value: id,
                            child: Text(nickFor(id)),
                          ))
                      .toList(),
                  onChanged: (v) => setD(() => picked = v),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: backupFirst,
                  onChanged: (v) => setD(() => backupFirst = v ?? true),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Сделать резерв на мой Google Диск сейчас'),
                  subtitle: const Text(
                    'Перед передачей прав',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Передать'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || picked == null || !mounted) return;
    final newAdminId = picked!;

    if (backupFirst) {
      try {
        await ChannelBackupService.instance.publishBackup(ch);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Резерв на Google Диск выполнен'),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Ошибка резерва'),
              content: Text('$e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Всё равно передать'),
                ),
              ],
            ),
          );
          if (go != true) return;
        }
      }
    }

    final updated = await ChannelService.instance.transferOwnership(
      channelId: ch.id,
      newAdminId: newAdminId,
      currentAdminId: _myId,
    );
    if (!mounted) return;
    if (updated == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось передать владение')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Владение передано. Откройте профиль канала и нажмите «Отписаться», чтобы выйти.',
        ),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final ch = _channel;
    if (ch == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Настройки канала')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (ch.adminId != _myId) {
      return Scaffold(
        appBar: AppBar(title: const Text('Настройки канала')),
        body: const Center(
          child: Text('Доступно только владельцу канала'),
        ),
      );
    }

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('Настройки: ${ch.name}')),
      body: ListView(
        children: [
          if (ch.driveBackupEnabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Резерв на Google Drive',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Аккаунт синхронизации'),
              subtitle: Text(
                (_driveStatus?.email != null &&
                        _driveStatus!.email!.isNotEmpty)
                    ? _driveStatus!.email!
                    : 'Не подключён — Google откроет вход при следующей выгрузке',
                style: const TextStyle(fontSize: 13),
              ),
              trailing: _driveRefreshing
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Обновить / войти в Google',
                      onPressed: _refreshDriveQuota,
                    ),
            ),
            ListTile(
              leading: const Icon(Icons.pie_chart_outline),
              title: const Text('Место в Google'),
              subtitle: Text(
                _driveFreeSubtitle(),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.file_present_outlined),
              title: const Text('Файл на Диске'),
              subtitle: Text(
                ch.driveFileId != null && ch.driveFileId!.isNotEmpty
                    ? 'Один файл перезаписывается при каждом резерве '
                        '(Rlink_ch_${ChannelService.compactChannelId(ch.id)}.bin)'
                    : 'Появится после первой успешной выгрузки',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Divider(height: 24),
          ],
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Редактировать профиль'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openEditDialog,
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Подписчики'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageSubscribers,
          ),
          ListTile(
            leading: Icon(
              ch.commentsEnabled
                  ? Icons.comments_disabled_outlined
                  : Icons.comment_outlined,
            ),
            title: Text(ch.commentsEnabled
                ? 'Выключить комментарии'
                : 'Включить комментарии'),
            onTap: _toggleComments,
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Модераторы'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageModerators,
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Команда и подписи'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageStaffAndLinks,
          ),
          if (!ch.verified)
            ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: const Text('Подать на верификацию'),
              onTap: _requestVerification,
            ),
          if (_canTransferOwnership)
            ListTile(
              leading: const Icon(Icons.swap_horiz_outlined),
              title: const Text('Передать владение'),
              subtitle: const Text(
                'Другой подписчик станет администратором',
                style: TextStyle(fontSize: 12),
              ),
              onTap: _showTransferOwnershipDialog,
            ),
          ListTile(
            leading: const Icon(Icons.logout_outlined),
            title: const Text('Покинуть канал'),
            subtitle: const Text(
              'После передачи владения — через «Отписаться» в профиле',
              style: TextStyle(fontSize: 12),
            ),
            onTap: _showLeaveHint,
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Удалить канал',
                style: TextStyle(color: Colors.red)),
            onTap: _deleteChannel,
          ),
        ],
      ),
    );
  }
}
