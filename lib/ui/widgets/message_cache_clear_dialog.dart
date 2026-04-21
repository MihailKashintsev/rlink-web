import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/conversation_cache_service.dart';
import '../../services/crypto_service.dart';
import '../../services/group_service.dart';

/// Диалог: типы переписок, полная очистка или только медиа, выбор чатов.
Future<void> showMessageCacheClearDialog(BuildContext context) async {
  final myKey = CryptoService.instance.publicKeyHex;
  final dmPeers = await ChatStorageService.instance.getChatPeerIds();
  final groups = await GroupService.instance.getGroups();
  final channels = await ChannelService.instance.getChannels();
  final chClearable = channels.where((c) => c.adminId != myKey).toList();

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => _MessageCacheClearBody(
      dmPeers: dmPeers,
      groups: groups,
      channelsClearable: chClearable,
    ),
  );
}

class _MessageCacheClearBody extends StatefulWidget {
  final List<String> dmPeers;
  final List<Group> groups;
  final List<Channel> channelsClearable;

  const _MessageCacheClearBody({
    required this.dmPeers,
    required this.groups,
    required this.channelsClearable,
  });

  @override
  State<_MessageCacheClearBody> createState() => _MessageCacheClearBodyState();
}

class _MessageCacheClearBodyState extends State<_MessageCacheClearBody> {
  bool _dm = true;
  bool _gr = true;
  bool _ch = true;
  bool _mediaOnly = false;

  late Set<String> _dmSel;
  late Set<String> _grSel;
  late Set<String> _chSel;

  @override
  void initState() {
    super.initState();
    _dmSel = widget.dmPeers.toSet();
    _grSel = widget.groups.map((g) => g.id).toSet();
    _chSel = widget.channelsClearable.map((c) => c.id).toSet();
  }

  Future<void> _run() async {
    final spec = MessageCacheClearSpec(
      includeDm: _dm,
      includeGroups: _gr,
      includeChannels: _ch,
      mediaOnly: _mediaOnly,
      dmPeerIds: _dm && _dmSel.length < widget.dmPeers.length ? _dmSel : null,
      groupIds: _gr && _grSel.length < widget.groups.length ? _grSel : null,
      channelIds: _ch && _chSel.length < widget.channelsClearable.length
          ? _chSel
          : null,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await ConversationCacheService.instance.applyClear(spec);
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(_mediaOnly
              ? AppL10n.t('snack_cache_cleared_media')
              : AppL10n.t('snack_cache_cleared_full')),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
            content: Text('${AppL10n.t('error')}: $e'),
            backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppL10n.t('cache_dialog_title')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppL10n.t('cache_dialog_admin_note'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _dm,
              onChanged: (v) => setState(() => _dm = v ?? false),
              title: Text(AppL10n.t('cache_include_dm')),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: _gr,
              onChanged: (v) => setState(() => _gr = v ?? false),
              title: Text(AppL10n.t('cache_include_groups')),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: _ch,
              onChanged: (v) => setState(() => _ch = v ?? false),
              title: Text(AppL10n.t('cache_include_channels')),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(),
            RadioListTile<bool>(
              value: false,
              groupValue: _mediaOnly,
              onChanged: (_) => setState(() => _mediaOnly = false),
              title: Text(AppL10n.t('cache_radio_full')),
              subtitle: Text(
                AppL10n.t('cache_radio_full_sub'),
                style: const TextStyle(fontSize: 11),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<bool>(
              value: true,
              groupValue: _mediaOnly,
              onChanged: (_) => setState(() => _mediaOnly = true),
              title: Text(AppL10n.t('cache_radio_media_only')),
              subtitle: Text(
                AppL10n.t('cache_radio_media_only_sub'),
                style: const TextStyle(fontSize: 11),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            if (_dm && widget.dmPeers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(AppL10n.t('cache_pick_dm'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              ...widget.dmPeers.map((id) => CheckboxListTile(
                    dense: true,
                    value: _dmSel.contains(id),
                    onChanged: (c) => setState(() {
                      if (c == true) {
                        _dmSel.add(id);
                      } else {
                        _dmSel.remove(id);
                      }
                    }),
                    title: Text(
                      '${id.substring(0, id.length.clamp(0, 8))}…',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                    contentPadding: EdgeInsets.zero,
                  )),
            ],
            if (_gr && widget.groups.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(AppL10n.t('cache_pick_groups'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              ...widget.groups.map((g) => CheckboxListTile(
                    dense: true,
                    value: _grSel.contains(g.id),
                    onChanged: (c) => setState(() {
                      if (c == true) {
                        _grSel.add(g.id);
                      } else {
                        _grSel.remove(g.id);
                      }
                    }),
                    title: Text(g.name),
                    contentPadding: EdgeInsets.zero,
                  )),
            ],
            if (_ch && widget.channelsClearable.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(AppL10n.t('cache_pick_channels'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              ...widget.channelsClearable.map((c) => CheckboxListTile(
                    dense: true,
                    value: _chSel.contains(c.id),
                    onChanged: (cbox) => setState(() {
                      if (cbox == true) {
                        _chSel.add(c.id);
                      } else {
                        _chSel.remove(c.id);
                      }
                    }),
                    title: Text(c.name),
                    contentPadding: EdgeInsets.zero,
                  )),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppL10n.t('cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            if (!_dm && !_gr && !_ch) return;
            if (_dm && _dmSel.isEmpty) return;
            if (_gr && _grSel.isEmpty) return;
            if (_ch &&
                widget.channelsClearable.isNotEmpty &&
                _chSel.isEmpty) {
              return;
            }
            _run();
          },
          child: Text(AppL10n.t('cache_action_clear')),
        ),
      ],
    );
  }
}
