import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';

/// Редактор команды канала: подписи постов, админы ссылок.
class StaffLinksEditorSheet extends StatefulWidget {
  final Channel channel;
  final String myId;
  final void Function(Channel) onChannelRefreshed;

  const StaffLinksEditorSheet({
    super.key,
    required this.channel,
    required this.myId,
    required this.onChannelRefreshed,
  });

  @override
  State<StaffLinksEditorSheet> createState() => _StaffLinksEditorSheetState();
}

class _StaffLinksEditorSheetState extends State<StaffLinksEditorSheet> {
  late Channel _ch;
  late bool _sign;
  final _labelCtrls = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _ch = widget.channel;
    _sign = _ch.signStaffPosts;
    _syncControllers();
  }

  void _syncControllers() {
    final ids = {
      _ch.adminId,
      ..._ch.moderatorIds,
      ..._ch.linkAdminIds,
    };
    for (final id in ids) {
      _labelCtrls.putIfAbsent(
        id,
        () => TextEditingController(text: _ch.staffLabels[id] ?? ''),
      );
    }
    _labelCtrls.removeWhere((id, ctl) {
      if (ids.contains(id)) return false;
      ctl.dispose();
      return true;
    });
  }

  @override
  void dispose() {
    for (final c in _labelCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _nickFor(String id) {
    if (id == widget.myId) return 'Вы';
    return ChatStorageService.instance.contactsNotifier.value
            .where((c) => c.publicKeyHex == id)
            .firstOrNull
            ?.nickname ??
        '${id.substring(0, 8)}…';
  }

  Future<void> _onLinkToggle(String uid, bool val) async {
    final updated =
        await ChannelService.instance.setLinkAdmin(_ch.id, uid, val);
    if (updated != null && mounted) {
      setState(() {
        _ch = updated;
        _syncControllers();
      });
      widget.onChannelRefreshed(updated);
      unawaited(updated.broadcastGossipMeta());
    }
  }

  Future<void> _saveLabels() async {
    final nextLabels = <String, String>{};
    for (final e in _labelCtrls.entries) {
      final t = e.value.text.trim();
      if (t.isNotEmpty) nextLabels[e.key] = t;
    }
    final updated = _ch.copyWith(
      signStaffPosts: _sign,
      staffLabels: nextLabels,
    );
    await ChannelService.instance.updateChannel(updated);
    if (!mounted) return;
    setState(() => _ch = updated);
    widget.onChannelRefreshed(updated);
    Navigator.pop(context);
    unawaited(updated.broadcastGossipMeta());
  }

  @override
  Widget build(BuildContext context) {
    final subscribers =
        _ch.subscriberIds.where((id) => id != _ch.adminId).toList();
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Команда и подписи', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _sign,
                title: const Text('Подписывать посты'),
                subtitle: const Text(
                  'Показывать подпись у авторов с заполненной строкой ниже',
                  style: TextStyle(fontSize: 12),
                ),
                onChanged: (v) => setState(() => _sign = v),
              ),
              const Divider(),
              Text('Админы ссылок', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              if (subscribers.isEmpty)
                const Text('Нет подписчиков',
                    style: TextStyle(color: Colors.grey))
              else
                ...subscribers.map((uid) {
                  final isLink = _ch.linkAdminIds.contains(uid);
                  return SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_nickFor(uid)),
                    subtitle: Text(
                      '${uid.substring(0, 12)}…',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    value: isLink,
                    onChanged: (val) => _onLinkToggle(uid, val),
                  );
                }),
              const Divider(),
              Text('Текст подписи по автору',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...() {
                final ids = [
                  _ch.adminId,
                  ..._ch.moderatorIds,
                  ..._ch.linkAdminIds,
                ].toSet().toList();
                return ids.map((id) {
                  final c = _labelCtrls.putIfAbsent(
                    id,
                    () => TextEditingController(
                        text: _ch.staffLabels[id] ?? ''),
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: c,
                      decoration: InputDecoration(
                        labelText: _nickFor(id),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      maxLength: 80,
                    ),
                  );
                });
              }(),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _saveLabels,
                child: const Text('Сохранить подписи'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
