import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/channel.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../utils/rlink_deep_link.dart';
import '../widgets/avatar_widget.dart';
import 'channel_admin_settings_screen.dart';

/// Профиль канала (баннер, аватар, описание) — доступен подписчикам.
class ChannelProfileScreen extends StatefulWidget {
  final String channelId;

  const ChannelProfileScreen({super.key, required this.channelId});

  @override
  State<ChannelProfileScreen> createState() => _ChannelProfileScreenState();
}

class _ChannelProfileScreenState extends State<ChannelProfileScreen> {
  Channel? _channel;

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
    if (mounted) setState(() => _channel = ch);
  }

  Future<void> _toggleSubscribe() async {
    final ch = _channel;
    if (ch == null) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    if (ch.adminId == myId) return;
    if (ch.subscriberIds.contains(myId)) {
      await ChannelService.instance.unsubscribe(ch.id, myId);
      await GossipRouter.instance.broadcastChannelSubscribe(
        channelId: ch.id,
        userId: myId,
        unsubscribe: true,
      );
    } else {
      await ChannelService.instance.subscribe(ch.id, myId);
      await GossipRouter.instance.broadcastChannelSubscribe(
        channelId: ch.id,
        userId: myId,
        unsubscribe: false,
      );
      final lastPost = await ChannelService.instance.getLastPost(ch.id);
      unawaited(GossipRouter.instance.sendChannelHistoryRequest(
        channelId: ch.id,
        requesterId: myId,
        adminId: ch.adminId,
        sinceTs: lastPost?.timestamp ?? 0,
      ));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ch = _channel;
    if (ch == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Канал')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final myId = CryptoService.instance.publicKeyHex;
    final isAdmin = ch.adminId == myId;
    final subscribed = ch.subscriberIds.contains(myId) || isAdmin;
    final banner = ImageService.instance.resolveStoredPath(ch.bannerImagePath);
    final hasBanner = banner != null && File(banner).existsSync();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: hasBanner ? 200 : 120,
            pinned: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.share_outlined),
                tooltip: 'Поделиться каналом',
                onPressed: () {
                  unawaited(RlinkDeepLink.shareChannelInvite(
                    context: context,
                    channelTitle: ch.name,
                    channelId: ch.id,
                  ));
                },
              ),
              IconButton(
                icon: const Icon(Icons.link_rounded),
                tooltip: 'Копировать ссылку',
                onPressed: () {
                  final uri = RlinkDeepLink.channelInviteWebUri(ch.id);
                  Clipboard.setData(ClipboardData(text: uri.toString()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Ссылка скопирована: $uri'),
                    ),
                  );
                },
              ),
              if (isAdmin)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Настройки канала',
                  onPressed: () {
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ChannelAdminSettingsScreen(
                          channelId: ch.id,
                        ),
                      ),
                    ).then((_) => _load());
                  },
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              title: Text(ch.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasBanner)
                    Image.file(
                      File(banner),
                      key: ValueKey(banner),
                      fit: BoxFit.cover,
                    )
                  else
                    Container(color: Color(ch.avatarColor).withValues(alpha: 0.35)),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.15),
                          Colors.black.withValues(alpha: 0.55),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    bottom: 52,
                    child: AvatarWidget(
                      key: ValueKey(
                          'ch_prof_av_${ch.id}_${ch.avatarImagePath ?? ''}'),
                      initials: ch.name.isNotEmpty ? ch.name[0].toUpperCase() : '?',
                      color: ch.avatarColor,
                      emoji: ch.avatarEmoji,
                      imagePath: ch.avatarImagePath,
                      size: 88,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    if (ch.verified) ...[
                      const Icon(Icons.verified, color: Colors.blue, size: 22),
                      const SizedBox(width: 6),
                    ],
                    Text('${ch.subscriberIds.length} подписчиков',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  ]),
                  if (ch.universalCode.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText('Код: ${ch.universalCode}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13)),
                  ],
                  if (ch.description != null && ch.description!.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text('О канале',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, color: cs.primary)),
                    const SizedBox(height: 6),
                    Text(ch.description!,
                        style: TextStyle(
                            fontSize: 15,
                            height: 1.35,
                            color: cs.onSurface)),
                  ],
                  const SizedBox(height: 24),
                  if (!isAdmin)
                    FilledButton.tonalIcon(
                      onPressed: _toggleSubscribe,
                      icon: Icon(subscribed
                          ? Icons.notifications_off_outlined
                          : Icons.notifications_active_outlined),
                      label: Text(subscribed ? 'Отписаться' : 'Подписаться'),
                    ),
                  if (isAdmin)
                    Text('Вы администратор этого канала',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
