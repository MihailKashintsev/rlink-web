import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../models/channel.dart';
import '../../models/contact.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/ether_service.dart';
import '../../services/group_service.dart';
import '../../models/user_profile.dart';
import '../../services/profile_service.dart';
import '../../l10n/app_l10n.dart';
import '../../services/gossip_router.dart';
import '../../services/relay_service.dart';
import '../../services/story_service.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/mesh_radar_widget.dart';
import '../widgets/update_available_banner.dart';
import '../../utils/message_preview_formatter.dart';
import 'channels_screen.dart';
import 'chat_screen.dart';
import 'ether_screen.dart';
import 'groups_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'story_creator_screen.dart';
import 'story_viewer_screen.dart';


// ── Slide + fade page transition helper ─────────────────────────
Route<T> slideRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) {
      return SlideTransition(
        position: Tween(begin: const Offset(0.3, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
    transitionDuration: const Duration(milliseconds: 300),
  );
}

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with UpdateAvailableBannerMixin {
  int _currentTab = 0; // 0=Чаты, 1=Рядом, 2=Эфир
  bool _searchActive = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    registerUpdateBannerListener();
    ChatStorageService.instance.loadContacts();
  }

  @override
  void dispose() {
    unregisterUpdateBannerListener();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _rescan() async {
    BleService.instance.clearMappings();
    await ChatStorageService.instance.loadContacts();
    await BleService.instance.refreshProfiles();
    await BleService.instance.rescan();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Поиск устройств...'), duration: Duration(seconds: 2)),
    );
    setState(() => _currentTab = 1);
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchController.clear();
        RelayService.instance.searchResults.value = [];
      }
    });
  }

  void _createChannel() {
    final nameCtrl = TextEditingController();
    final usernameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    bool isPublic = true;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Новый канал'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Название канала'),
                maxLength: 30,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(
                  hintText: 'Юзернейм (необязательно)',
                  prefixText: '@',
                ),
                maxLength: 24,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_\.]')),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(hintText: 'Описание (необязательно)'),
                maxLength: 100,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: isPublic,
                onChanged: (v) => setLocal(() => isPublic = v),
                contentPadding: EdgeInsets.zero,
                title: Text(isPublic ? 'Публичный' : 'Скрытый'),
                subtitle: Text(
                  isPublic
                      ? 'Находится по названию, юзернейму и универсальному коду'
                      : 'Админ сам добавляет подписчиков. В поиске не виден.',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final uname = usernameCtrl.text.trim().toLowerCase();
                if (uname.isNotEmpty) {
                  final taken = await ChannelService.instance.isUsernameTaken(uname);
                  if (taken) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Этот юзернейм уже занят')),
                      );
                    }
                    return;
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
                try {
                  final myId = CryptoService.instance.publicKeyHex;
                  final ch = await ChannelService.instance.createChannel(
                    name: name,
                    adminId: myId,
                    username: uname,
                    isPublic: isPublic,
                    description: descCtrl.text.trim().isNotEmpty ? descCtrl.text.trim() : null,
                  );
                  GossipRouter.instance.broadcastChannelMeta(
                    channelId: ch.id,
                    name: ch.name,
                    adminId: ch.adminId,
                    avatarColor: ch.avatarColor,
                    avatarEmoji: ch.avatarEmoji,
                    description: ch.description,
                    commentsEnabled: ch.commentsEnabled,
                    createdAt: ch.createdAt,
                    username: ch.username,
                    universalCode: ch.universalCode,
                    isPublic: ch.isPublic,
                  );
                  if (mounted) {
                    Navigator.push(context, slideRoute(
                      ChannelViewScreen(channel: ch),
                    ));
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Ошибка: $e')),
                    );
                  }
                }
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  void _createGroup() {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая группа'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Название группы'),
          maxLength: 30,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              try {
                final myId = CryptoService.instance.publicKeyHex;
                final group = await GroupService.instance.createGroup(
                  name: name,
                  creatorId: myId,
                  memberIds: [myId],
                );
                if (mounted) {
                  Navigator.push(context, slideRoute(
                    GroupChatScreen(group: group),
                  ));
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Ошибка: $e')),
                  );
                }
              }
            },
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;

    return Scaffold(
      appBar: AppBar(
        title: _searchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Поиск контактов, каналов, людей...',
                  hintStyle: TextStyle(color: Colors.grey.shade500),
                  border: InputBorder.none,
                ),
                onChanged: (_) {
                  setState(() {});
                  _triggerGlobalSearch(_searchController.text);
                },
              )
            : const Text('Rlink',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22)),
        leading: _searchActive
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _toggleSearch,
              )
            : GestureDetector(
                onTap: () => Navigator.push(context, slideRoute(const ProfileScreen())),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: profile != null
                      ? Hero(
                          tag: 'avatar_my_profile',
                          child: AvatarWidget(
                            initials: profile.initials,
                            color: profile.avatarColor,
                            emoji: profile.avatarEmoji,
                            imagePath: profile.avatarImagePath,
                            size: 36,
                          ),
                        )
                      : const Icon(Icons.account_circle),
                ),
              ),
        actions: [
          if (_currentTab == 1 && !_searchActive)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Обновить',
              onPressed: _rescan,
            ),
          if (_currentTab == 0)
            IconButton(
              icon: Icon(_searchActive ? Icons.close : Icons.search),
              tooltip: _searchActive ? 'Закрыть' : 'Поиск',
              onPressed: _toggleSearch,
            ),
          if (!_searchActive)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                switch (v) {
                  case 'group': _createGroup();
                  case 'channel': _createChannel();
                  case 'settings': Navigator.push(context, slideRoute(const SettingsScreen()));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'group', child: ListTile(
                  leading: Icon(Icons.group_add), title: Text('Новая группа'),
                  dense: true, contentPadding: EdgeInsets.zero,
                )),
                const PopupMenuItem(value: 'channel', child: ListTile(
                  leading: Icon(Icons.campaign), title: Text('Новый канал'),
                  dense: true, contentPadding: EdgeInsets.zero,
                )),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'settings', child: ListTile(
                  leading: Icon(Icons.settings_outlined), title: Text('Настройки'),
                  dense: true, contentPadding: EdgeInsets.zero,
                )),
              ],
            ),
        ],
      ),
      body: IndexedStack(
        index: _currentTab,
        children: [
          _UnifiedChatsTab(searchQuery: _searchActive ? _searchController.text : ''),
          _NearbyTab(),
          const EtherScreen(),
        ],
      ),
      bottomNavigationBar: _AnimatedNavBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() {
          _currentTab = i;
          if (_searchActive) {
            _searchActive = false;
            _searchController.clear();
            RelayService.instance.searchResults.value = [];
          }
          if (i == 2) EtherService.instance.markRead();
        }),
      ),
    );
  }

  // ── Глобальный поиск (контакты + каналы + люди) ──
  Timer? _globalSearchDebounce;
  void _triggerGlobalSearch(String query) {
    _globalSearchDebounce?.cancel();
    final raw = query.trim();
    if (raw.length < 2) {
      RelayService.instance.searchResults.value = [];
      return;
    }
    _globalSearchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (RelayService.instance.isConnected) {
        RelayService.instance.searchUsers(raw);
      }
    });
  }
}

// ── Animated bottom nav bar (4 tabs) ──────────────────────────────

class _AnimatedNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const _AnimatedNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      animationDuration: const Duration(milliseconds: 400),
      indicatorColor: theme.colorScheme.primary.withValues(alpha: 0.15),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.chat_bubble_outline),
          selectedIcon: const Icon(Icons.chat_bubble),
          label: AppL10n.t('nav_chats'),
        ),
        NavigationDestination(
          icon: ValueListenableBuilder<int>(
            valueListenable: BleService.instance.peersCount,
            builder: (_, count, __) =>
                count > 0 && AppSettings.instance.connectionMode != 1
                ? Badge(
                    label: Text('$count'),
                    child: const Icon(Icons.radar))
                : const Icon(Icons.radar_outlined),
          ),
          selectedIcon: ValueListenableBuilder<int>(
            valueListenable: BleService.instance.peersCount,
            builder: (_, count, __) =>
                count > 0 && AppSettings.instance.connectionMode != 1
                ? Badge(
                    label: Text('$count'),
                    child: const Icon(Icons.radar))
                : const Icon(Icons.radar),
          ),
          label: AppL10n.t('nav_nearby'),
        ),
        NavigationDestination(
          icon: ValueListenableBuilder<int>(
            valueListenable: EtherService.instance.unreadCount,
            builder: (_, count, __) => count > 0
                ? Badge(
                    label: Text('$count'),
                    child: const Icon(Icons.cell_tower))
                : const Icon(Icons.cell_tower),
          ),
          selectedIcon: const Icon(Icons.cell_tower),
          label: AppL10n.t('nav_ether'),
        ),
      ],
    );
  }
}

// ── Единый список: чаты + группы + каналы (Telegram-style) ──────

enum _ChatItemType { personal, group, channel }

class _UnifiedChatsTab extends StatefulWidget {
  final String searchQuery;
  const _UnifiedChatsTab({this.searchQuery = ''});

  @override
  State<_UnifiedChatsTab> createState() => _UnifiedChatsTabState();
}

class _UnifiedChatsTabState extends State<_UnifiedChatsTab> {
  List<_ChatItem> _items = [];
  StreamSubscription<IncomingMessage>? _sub;
  Timer? _loadDebounce;
  VoidCallback? _groupListener;
  VoidCallback? _channelListener;
  VoidCallback? _bleListener;   // fires on BLE peer connect/disconnect
  VoidCallback? _contactListener; // fires when contactsNotifier updates
  VoidCallback? _readStateListener;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = incomingMessageController.stream.listen((_) {
      _loadDebounce?.cancel();
      _loadDebounce = Timer(const Duration(milliseconds: 300), _load);
    });
    _groupListener = () => _debouncedLoad();
    _channelListener = () => _debouncedLoad();
    // Rebuild when BLE peers connect/disconnect so the green dot updates live.
    _bleListener = () => _debouncedLoad();
    // Also rebuild when contacts change (avatar/banner/nickname updates).
    _contactListener = () => _debouncedLoad();
    GroupService.instance.version.addListener(_groupListener!);
    ChannelService.instance.version.addListener(_channelListener!);
    BleService.instance.peersCount.addListener(_bleListener!);
    ChatStorageService.instance.contactsNotifier.addListener(_contactListener!);
    _readStateListener = () => _debouncedLoad();
    ChatStorageService.instance.readStateVersion.addListener(_readStateListener!);
  }

  void _debouncedLoad() {
    _loadDebounce?.cancel();
    _loadDebounce = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  void dispose() {
    _loadDebounce?.cancel();
    _sub?.cancel();
    if (_groupListener != null) GroupService.instance.version.removeListener(_groupListener!);
    if (_channelListener != null) ChannelService.instance.version.removeListener(_channelListener!);
    if (_bleListener != null) BleService.instance.peersCount.removeListener(_bleListener!);
    if (_contactListener != null) ChatStorageService.instance.contactsNotifier.removeListener(_contactListener!);
    if (_readStateListener != null) {
      ChatStorageService.instance.readStateVersion.removeListener(_readStateListener!);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final items = <_ChatItem>[];
    final myId = CryptoService.instance.publicKeyHex;
    final showOnline = AppSettings.instance.showOnlineStatus;
    final dmUnread = await ChatStorageService.instance.getDmUnreadCounts();
    final groupUnread = await GroupService.instance.getGroupUnreadCounts();
    final channelUnread = await ChannelService.instance.getChannelUnreadCounts();

    // 1) Личные чаты
    final summaries = await ChatStorageService.instance.getChatSummaries();
    final summaryIds = <String>{};
    for (final s in summaries) {
      summaryIds.add(s.peerId);
      items.add(_ChatItem(
        type: _ChatItemType.personal,
        id: s.peerId,
        nickname: s.nickname ?? '${s.peerId.substring(0, s.peerId.length.clamp(0, 8))}...',
        avatarColor: s.avatarColor ?? 0xFF607D8B,
        avatarEmoji: s.avatarEmoji ?? '',
        avatarImagePath: s.avatarImagePath,
        lastMessage: s.displayText,
        lastTime: s.timestamp,
        isOnline: showOnline && BleService.instance.isPeerConnected(s.peerId),
        unreadCount: dmUnread[s.peerId] ?? 0,
      ));
    }

    // 1б) Контакты без переписки — добавляем с пустым lastMessage
    final contacts = await ChatStorageService.instance.getContacts();
    for (final c in contacts) {
      if (summaryIds.contains(c.publicKeyHex)) continue;
      items.add(_ChatItem(
        type: _ChatItemType.personal,
        id: c.publicKeyHex,
        nickname: c.nickname.isNotEmpty
            ? c.nickname
            : '${c.publicKeyHex.substring(0, 8)}...',
        avatarColor: c.avatarColor,
        avatarEmoji: c.avatarEmoji,
        avatarImagePath: c.avatarImagePath,
        lastMessage: '',
        lastTime: c.addedAt,
        isOnline: showOnline && BleService.instance.isPeerConnected(c.publicKeyHex),
        unreadCount: 0,
      ));
    }

    // 2) Группы — только те, где я участник или создатель.
    final groups = await GroupService.instance.getGroups();
    for (final g in groups) {
      if (g.creatorId != myId && !g.memberIds.contains(myId)) continue;
      final lastMsg = await GroupService.instance.getLastMessage(g.id);
      items.add(_ChatItem(
        type: _ChatItemType.group,
        id: g.id,
        nickname: g.name,
        avatarColor: g.avatarColor,
        avatarEmoji: g.avatarEmoji,
        avatarImagePath: g.avatarImagePath,
        lastMessage: lastMsg == null
            ? 'Группа создана'
            : formatGroupMessagePreview(lastMsg),
        lastTime: lastMsg != null
            ? DateTime.fromMillisecondsSinceEpoch(lastMsg.timestamp)
            : DateTime.fromMillisecondsSinceEpoch(g.createdAt),
        isOnline: false,
        unreadCount: groupUnread[g.id] ?? 0,
      ));
    }

    // 3) Каналы — только те, где я подписан или являюсь админом.
    final channels = await ChannelService.instance.getChannels();
    for (final ch in channels) {
      if (ch.adminId != myId && !ch.subscriberIds.contains(myId)) continue;
      final lastPost = await ChannelService.instance.getLastPost(ch.id);
      items.add(_ChatItem(
        type: _ChatItemType.channel,
        id: ch.id,
        nickname: ch.name,
        avatarColor: ch.avatarColor,
        avatarEmoji: ch.avatarEmoji,
        avatarImagePath: ch.avatarImagePath,
        lastMessage: lastPost == null
            ? 'Канал создан'
            : formatChannelPostPreview(lastPost),
        lastTime: lastPost != null
            ? DateTime.fromMillisecondsSinceEpoch(lastPost.timestamp)
            : DateTime.fromMillisecondsSinceEpoch(ch.createdAt),
        isOnline: false,
        unreadCount: channelUnread[ch.id] ?? 0,
      ));
    }

    // Сортируем по последнему сообщению (новые сверху)
    items.sort((a, b) => b.lastTime.compareTo(a.lastTime));

    if (!mounted) return;
    setState(() => _items = items);
  }

  Future<void> _navigate(BuildContext context, _ChatItem item) async {
    switch (item.type) {
      case _ChatItemType.personal:
        await Navigator.push(context, slideRoute(ChatScreen(
          peerId: item.id,
          peerNickname: item.nickname,
          peerAvatarColor: item.avatarColor,
          peerAvatarEmoji: item.avatarEmoji,
          peerAvatarImagePath: item.avatarImagePath,
        )));
      case _ChatItemType.group:
        final group = await GroupService.instance.getGroup(item.id);
        if (group == null || !context.mounted) return;
        await Navigator.push(context, slideRoute(
          GroupChatScreen(group: group),
        ));
      case _ChatItemType.channel:
        final channel = await ChannelService.instance.getChannel(item.id);
        if (channel == null || !context.mounted) return;
        await Navigator.push(context, slideRoute(
          ChannelViewScreen(channel: channel),
        ));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.searchQuery.toLowerCase().trim();

    if (_items.isEmpty && q.isEmpty) {
      return Column(children: [
        _StoriesStrip(chatItems: _items),
        const Expanded(child: _EmptyChatsState()),
      ]);
    }

    if (q.isEmpty) {
      return Column(children: [
        _StoriesStrip(chatItems: _items),
        Expanded(
            child: ListView.separated(
          itemCount: _items.length,
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          separatorBuilder: (_, __) => Divider(
            height: 1,
            indent: 68,
            endIndent: 12,
            color: Theme.of(context)
                .dividerColor
                .withValues(alpha: 0.22),
          ),
          itemBuilder: (_, i) {
            final item = _items[i];
            return RepaintBoundary(
              child: _TelegramChatRow(
                item: item,
                onTap: () => _navigate(context, item),
                timeLabel: _fmtTime(item.lastTime),
              ),
            );
          },
        )),
      ]);
    }

    // Режим поиска — секции «Чаты», «Контакты», «Каналы», «Люди в сети».
    return _UnifiedSearchResults(
      query: q,
      localItems: _items,
      onOpenItem: (item) => _navigate(context, item),
    );
  }

  String _fmtTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}.${dt.month}';
  }
}

// ── Строка списка чатов (в духе Telegram: плоский список, разделители) ──

class _TelegramChatRow extends StatelessWidget {
  final _ChatItem item;
  final VoidCallback onTap;
  final String timeLabel;

  const _TelegramChatRow({
    required this.item,
    required this.onTap,
    required this.timeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final subColor = theme.brightness == Brightness.dark
        ? const Color(0xFF8E8E93)
        : const Color(0xFF8E8E93);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Hero(
                tag: 'avatar_${item.peerId}',
                child: AvatarWidget(
                  initials: item.nickname.isNotEmpty
                      ? item.nickname[0].toUpperCase()
                      : '?',
                  color: item.avatarColor,
                  emoji: item.avatarEmoji,
                  imagePath: item.avatarImagePath,
                  size: 52,
                  isOnline: item.isOnline,
                  hasStory: item.type == _ChatItemType.personal &&
                      StoryService.instance.hasActiveStory(item.peerId),
                  hasUnviewedStory: item.type == _ChatItemType.personal &&
                      StoryService.instance.hasUnviewedStory(item.peerId),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (item.type == _ChatItemType.group)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Icon(Icons.group_outlined,
                                size: 18, color: cs.primary.withValues(alpha: 0.75)),
                          ),
                        if (item.type == _ChatItemType.channel)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Icon(Icons.campaign_outlined,
                                size: 18, color: cs.primary.withValues(alpha: 0.75)),
                          ),
                        Expanded(
                          child: Text(
                            item.nickname,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.unreadCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Text(
                              item.unreadCount > 99 ? '99+' : '${item.unreadCount}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: cs.onPrimary,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          timeLabel,
                          style: TextStyle(
                            fontSize: 13,
                            color: subColor,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 15,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Empty chats animation ───────────────────────────────────────

class _EmptyChatsState extends StatefulWidget {
  const _EmptyChatsState();
  @override
  State<_EmptyChatsState> createState() => _EmptyChatsStateState();
}

class _EmptyChatsStateState extends State<_EmptyChatsState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Transform.scale(
              scale: _pulseAnimation.value,
              child: child,
            );
          },
          child: Icon(Icons.chat_bubble_outline,
              size: 64, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 16),
        Text('Нет чатов',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
        const SizedBox(height: 8),
        Text('Найди устройства на вкладке "Рядом"',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
      ]),
    );
  }
}

class _ChatItem {
  final _ChatItemType type;
  final String id; // peerId for personal, groupId for group, channelId for channel
  final String nickname, lastMessage, avatarEmoji;
  final int avatarColor;
  final String? avatarImagePath;
  final DateTime lastTime;
  final bool isOnline;
  final int unreadCount;
  _ChatItem({
    this.type = _ChatItemType.personal,
    required this.id,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    required this.lastMessage,
    required this.lastTime,
    required this.isOnline,
    this.unreadCount = 0,
  });
  // Backward compat
  String get peerId => id;
}

// ── Единый блок результатов поиска (чаты + контакты + каналы + люди) ──

class _UnifiedSearchResults extends StatefulWidget {
  final String query;
  final List<_ChatItem> localItems;
  final void Function(_ChatItem) onOpenItem;
  const _UnifiedSearchResults({
    required this.query,
    required this.localItems,
    required this.onOpenItem,
  });

  @override
  State<_UnifiedSearchResults> createState() => _UnifiedSearchResultsState();
}

class _UnifiedSearchResultsState extends State<_UnifiedSearchResults> {
  List<Channel> _channelMatches = [];

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  @override
  void didUpdateWidget(_UnifiedSearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _loadChannels();
  }

  Future<void> _loadChannels() async {
    final matches = await ChannelService.instance.searchChannels(widget.query);
    if (!mounted) return;
    setState(() => _channelMatches = matches);
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.query;

    // 1) Чаты (из localItems)
    final chatMatches = widget.localItems.where((item) =>
        item.nickname.toLowerCase().contains(q) ||
        item.lastMessage.toLowerCase().contains(q)).toList();

    return ValueListenableBuilder<List<Contact>>(
      valueListenable: ChatStorageService.instance.contactsNotifier,
      builder: (_, contacts, __) {
        // 2) Контакты (без дубликатов с чатами)
        final chatIds = chatMatches.map((c) => c.id).toSet();
        final contactMatches = contacts.where((c) {
          if (chatIds.contains(c.publicKeyHex)) return false;
          final short = c.publicKeyHex.length > 8 ? c.publicKeyHex.substring(0, 8) : c.publicKeyHex;
          return c.nickname.toLowerCase().contains(q) ||
              c.username.toLowerCase().contains(q) ||
              short.toLowerCase().contains(q) ||
              c.publicKeyHex.toLowerCase().startsWith(q);
        }).toList();

        // 3) Каналы из локального кеша (searchChannels фильтрует скрытые)
        final channels = _channelMatches;

        // 4) Люди из relay
        return ValueListenableBuilder<List<RelayPeer>>(
          valueListenable: RelayService.instance.searchResults,
          builder: (_, relayResults, __) {
            final knownKeys = <String>{
              ...contactMatches.map((c) => c.publicKeyHex),
              ...chatIds,
            };
            final relayPeople = relayResults
                .where((p) => !knownKeys.contains(p.publicKey))
                .toList();

            final hasAny = chatMatches.isNotEmpty ||
                contactMatches.isNotEmpty ||
                channels.isNotEmpty ||
                relayPeople.isNotEmpty;

            if (!hasAny) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off,
                          size: 56, color: Colors.grey.shade600),
                      const SizedBox(height: 12),
                      Text('Ничего не найдено',
                          style: TextStyle(
                              color: Colors.grey.shade400, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text(
                        RelayService.instance.isConnected
                            ? 'Попробуй другой запрос'
                            : 'Relay не подключён — поиск людей недоступен',
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 80),
              children: [
                if (chatMatches.isNotEmpty) ...[
                  _searchSection('Чаты', chatMatches.length),
                  for (final m in chatMatches)
                    _TelegramChatRow(
                      item: m,
                      onTap: () => widget.onOpenItem(m),
                      timeLabel: _fmtTimeStatic(m.lastTime),
                    ),
                ],
                if (contactMatches.isNotEmpty) ...[
                  _searchSection('Контакты', contactMatches.length),
                  for (final c in contactMatches)
                    ListTile(
                      leading: AvatarWidget(
                        initials: c.nickname.isNotEmpty
                            ? c.nickname[0].toUpperCase()
                            : '?',
                        color: c.avatarColor,
                        emoji: c.avatarEmoji,
                        imagePath: c.avatarImagePath,
                        size: 44,
                      ),
                      title: Text(c.nickname),
                      subtitle: Text(
                        c.username.isNotEmpty ? '#${c.username}' : c.shortId,
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 11),
                      ),
                      onTap: () => Navigator.push(
                        context,
                        slideRoute(ChatScreen(
                          peerId: c.publicKeyHex,
                          peerNickname: c.nickname,
                          peerAvatarColor: c.avatarColor,
                          peerAvatarEmoji: c.avatarEmoji,
                          peerAvatarImagePath: c.avatarImagePath,
                        )),
                      ),
                    ),
                ],
                if (channels.isNotEmpty) ...[
                  _searchSection('Каналы', channels.length),
                  for (final ch in channels)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Color(ch.avatarColor),
                        child: Text(
                          ch.avatarEmoji,
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                      title: Row(children: [
                        Expanded(
                          child: Text(ch.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (ch.verified)
                          const Icon(Icons.verified,
                              size: 16, color: Colors.blue),
                      ]),
                      subtitle: Text(
                        ch.username.isNotEmpty
                            ? '@${ch.username}'
                            : (ch.description ?? ch.universalCode),
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.push(
                        context,
                        slideRoute(ChannelViewScreen(channel: ch)),
                      ),
                    ),
                ],
                if (relayPeople.isNotEmpty) ...[
                  _searchSection('Люди в сети', relayPeople.length),
                  for (final p in relayPeople)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                        child: Text(
                          p.nick.isNotEmpty ? p.nick[0].toUpperCase() : '#',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      title: Text(
                        p.username.isNotEmpty
                            ? '#${p.username}'
                            : (p.nick.isNotEmpty ? p.nick : p.shortId),
                      ),
                      subtitle: Text(
                        p.publicKey.substring(0, p.publicKey.length.clamp(0, 16)),
                        style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                            fontFamily: 'monospace'),
                      ),
                      trailing: const Icon(Icons.circle,
                          size: 10, color: Color(0xFF4CAF50)),
                      onTap: () {
                        final myProfile = ProfileService.instance.profile;
                        if (myProfile != null) {
                          GossipRouter.instance.sendPairRequest(
                            publicKey: myProfile.publicKeyHex,
                            nick: myProfile.nickname,
                            username: myProfile.username,
                            color: myProfile.avatarColor,
                            emoji: myProfile.avatarEmoji,
                            recipientId: p.publicKey,
                            x25519Key:
                                CryptoService.instance.x25519PublicKeyBase64,
                            tags: myProfile.tags,
                          );
                        }
                        final nick =
                            p.nick.isNotEmpty ? p.nick : p.shortId;
                        Navigator.push(
                          context,
                          slideRoute(ChatScreen(
                            peerId: p.publicKey,
                            peerNickname: nick,
                            peerAvatarColor: 0xFF607D8B,
                            peerAvatarEmoji: '',
                            peerAvatarImagePath: null,
                          )),
                        );
                      },
                    ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  static Widget _searchSection(String title, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          '$title ($count)',
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      );

  static String _fmtTimeStatic(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}.${dt.month}';
  }
}

// ── Сторис полоска ───────────────────────────────────────────────

class _StoriesStrip extends StatelessWidget {
  final List<_ChatItem> chatItems;
  const _StoriesStrip({required this.chatItems});

  @override
  Widget build(BuildContext context) {
    // Wrap in profileNotifier listener so strip rebuilds when profile loads
    return ValueListenableBuilder<UserProfile?>(
      valueListenable: ProfileService.instance.profileNotifier,
      builder: (context, myProfile, _) {
        return ValueListenableBuilder<List<Contact>>(
          valueListenable: ChatStorageService.instance.contactsNotifier,
          builder: (context, contacts, __) {
            final contactKeys = contacts.map((c) => c.publicKeyHex).toSet();
            return ValueListenableBuilder<int>(
              valueListenable: StoryService.instance.version,
              builder: (context, _, __) {
                final ownKey = myProfile?.publicKeyHex;
                final activeAuthors = StoryService.instance.activeAuthors
                    .where((id) => id == ownKey || contactKeys.contains(id))
                    .toList();

                // Only show strip if there are stories or own profile exists
                if (activeAuthors.isEmpty && myProfile == null) {
                  return const SizedBox.shrink();
                }

                return SizedBox(
                  height: 96,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    children: [
                      // ── Создать историю (всегда видна) ──────────────
                      if (myProfile != null)
                        _StoryAvatar(
                          label: 'Создать',
                          avatar: AvatarWidget(
                            initials: myProfile.initials,
                            color: myProfile.avatarColor,
                            emoji: myProfile.avatarEmoji,
                            imagePath: myProfile.avatarImagePath,
                            size: 56,
                            hasStory: false,
                            hasUnviewedStory: false,
                          ),
                          showAddBadge: true,
                          onTap: () {
                            Navigator.push(
                              context,
                              slideRoute(
                                StoryCreatorScreen(
                                    authorId: myProfile.publicKeyHex),
                              ),
                            ).then((story) {
                              if (story is StoryItem) {
                                GossipRouter.instance.sendStory(
                                  storyId: story.id,
                                  authorId: story.authorId,
                                  text: story.text,
                                  bgColor: story.bgColor,
                                );
                              }
                            });
                          },
                        ),

                      // ── Моя история (только когда есть активные) ────
                      if (myProfile != null &&
                          StoryService.instance.hasActiveStory(myProfile.publicKeyHex))
                        _StoryAvatar(
                          label: 'Моя история',
                          avatar: AvatarWidget(
                            initials: myProfile.initials,
                            color: myProfile.avatarColor,
                            emoji: myProfile.avatarEmoji,
                            imagePath: myProfile.avatarImagePath,
                            size: 56,
                            hasStory: true,
                            hasUnviewedStory: false,
                          ),
                          onTap: () {
                            final existing = StoryService.instance
                                .storiesFor(myProfile.publicKeyHex);
                            if (existing.isNotEmpty) {
                              Navigator.push(
                                context,
                                slideRoute(
                                  StoryViewerScreen(
                                    authorId: myProfile.publicKeyHex,
                                    authorName: 'Я',
                                    stories: existing,
                                  ),
                                ),
                              );
                            }
                          },
                        ),

                      // Stories from contacts — exclude own key to avoid duplicate
                      ...activeAuthors
                          .where((id) => id != ownKey)
                          .map((authorId) {
                        final chatItem = chatItems
                            .where((c) => c.type == _ChatItemType.personal)
                            .cast<_ChatItem?>()
                            .firstWhere((c) => c?.peerId == authorId, orElse: () => null);
                        final name = chatItem?.nickname ??
                            authorId.substring(0, authorId.length.clamp(0, 8));
                        final stories = StoryService.instance.storiesFor(authorId);
                        return _StoryAvatar(
                          label: name,
                          avatar: AvatarWidget(
                            initials: name.isNotEmpty ? name[0].toUpperCase() : '?',
                            color: chatItem?.avatarColor ?? 0xFF607D8B,
                            emoji: chatItem?.avatarEmoji ?? '',
                            imagePath: chatItem?.avatarImagePath,
                            size: 56,
                            hasStory: true,
                            hasUnviewedStory:
                                StoryService.instance.hasUnviewedStory(authorId),
                          ),
                          onTap: () => Navigator.push(
                            context,
                            slideRoute(
                              StoryViewerScreen(
                                authorId: authorId,
                                authorName: name,
                                stories: stories,
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _StoryAvatar extends StatelessWidget {
  final String label;
  final Widget avatar;
  final bool showAddBadge;
  final VoidCallback onTap;

  const _StoryAvatar({
    required this.label,
    required this.avatar,
    required this.onTap,
    this.showAddBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                if (showAddBadge)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2,
                        ),
                      ),
                      child: const Icon(Icons.add,
                          size: 12, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 60,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Рядом (радар / список) ───────────────────────────────────────

class _NearbyTab extends StatefulWidget {
  @override
  State<_NearbyTab> createState() => _NearbyTabState();
}

class _NearbyTabState extends State<_NearbyTab> {
  bool _showRadar = true;

  void _navigateToChat(String peerId, String nickname, int color,
      String emoji, String? imagePath) {
    Navigator.push(
      context,
      slideRoute(ChatScreen(
        peerId: peerId,
        peerNickname: nickname,
        peerAvatarColor: color,
        peerAvatarEmoji: emoji,
        peerAvatarImagePath: imagePath,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Internet-only mode — BLE is disabled
    if (AppSettings.instance.connectionMode == 1) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.bluetooth_disabled,
                size: 72, color: Colors.grey.shade700),
            const SizedBox(height: 16),
            Text(
              'Bluetooth выключен',
              style: TextStyle(
                  color: Colors.grey.shade300,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Режим «Только интернет» включён.\nОбщение ведётся через сеть.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
            ),
            const SizedBox(height: 20),
            Icon(Icons.wifi, size: 36, color: Colors.green.shade400),
          ]),
        ),
      );
    }

    return Stack(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: _showRadar
              ? MeshRadarWidget(
                  key: const ValueKey('radar'),
                  onPeerTap: _navigateToChat,
                )
              : const _NearbyListView(key: ValueKey('list')),
        ),
        // Toggle button
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            heroTag: 'nearby_toggle',
            onPressed: () => setState(() => _showRadar = !_showRadar),
            tooltip: _showRadar ? 'Список' : 'Радар',
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _showRadar ? Icons.list_rounded : Icons.radar,
                key: ValueKey(_showRadar),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Nearby list view (original) ─────────────────────────────────

class _NearbyListView extends StatelessWidget {
  const _NearbyListView({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Contact>>(
      valueListenable: ChatStorageService.instance.contactsNotifier,
      builder: (_, __, ___) => ValueListenableBuilder<int>(
        valueListenable: BleService.instance.peersCount,
        builder: (_, ___, ____) {
          return ValueListenableBuilder<int>(
            valueListenable: BleService.instance.peerMappingsVersion,
            builder: (_, __, ___) {
              return ValueListenableBuilder<Set<String>>(
                valueListenable: BleService.instance.pendingProfiles,
                builder: (_, pending, __) {
                  return ValueListenableBuilder<Map<String, Map<String, dynamic>>>(
                    valueListenable: BleService.instance.incomingPairRequests,
                    builder: (_, incomingRequests, __) {
                      final peers = BleService.instance.connectedPeerIds;
                      if (peers.isEmpty && pending.isEmpty && incomingRequests.isEmpty) {
                        return Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.bluetooth_searching,
                                size: 72, color: Colors.grey.shade700),
                            const SizedBox(height: 16),
                            Text('Ищем устройства...',
                                style: TextStyle(
                                    color: Colors.grey.shade400, fontSize: 16)),
                            const SizedBox(height: 8),
                            Text(
                                'Убедись что Bluetooth включён\nна обоих устройствах',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.grey.shade600, fontSize: 13)),
                          ]),
                        );
                      }
                      return ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          // Incoming pair requests — show accept/decline cards
                          ...incomingRequests.entries
                              .map((e) => _IncomingPairRequestTile(
                                    bleId: e.key,
                                    info: e.value,
                                  )),
                          ...pending
                              .map((bleId) => _PendingDeviceTile(bleId: bleId)),
                          ...peers
                              .where((id) =>
                                  !BleService.instance.isPeerProfilePending(id))
                              .map((id) => _NearbyDeviceTile(publicKeyOrBleId: id)),
                        ],
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _PendingDeviceTile extends StatelessWidget {
  final String bleId;
  const _PendingDeviceTile({required this.bleId});

  @override
  Widget build(BuildContext context) {
    final btName = BleService.instance.getDeviceName(bleId);
    final displayName =
        btName != bleId ? btName : '${bleId.substring(0, 8)}...';
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _sendInvite(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.bluetooth,
                    color: theme.colorScheme.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text('Нажмите чтобы добавить',
                        style: TextStyle(
                            color: theme.colorScheme.primary, fontSize: 12)),
                  ],
                ),
              ),
              // Send invite button
              FilledButton.icon(
                onPressed: () => _sendInvite(context),
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('Добавить'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  void _sendInvite(BuildContext context) {
    HapticFeedback.mediumImpact();
    final profile = ProfileService.instance.profile;
    if (profile == null) return;

    final resolvedKey = BleService.instance.resolvePublicKey(bleId);
    final isValidKey =
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(resolvedKey);

    if (isValidKey) {
      // Public key already known — send a targeted pair request.
      GossipRouter.instance.sendPairRequest(
        publicKey: profile.publicKeyHex,
        nick: profile.nickname,
        username: profile.username,
        color: profile.avatarColor,
        emoji: profile.avatarEmoji,
        recipientId: resolvedKey,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: profile.tags,
      );
    } else {
      // Public key not yet known (BLE UUID only) — broadcast our profile
      // so the peer learns who we are and can send their own profile back.
      GossipRouter.instance.broadcastProfile(
        id: profile.publicKeyHex,
        nick: profile.nickname,
        username: profile.username,
        color: profile.avatarColor,
        emoji: profile.avatarEmoji,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: profile.tags,
      );
    }

    BleService.instance.setExchangeState(bleId, 1); // invite sent
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Запрос на обмен отправлен'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

/// Inline card — just shows a notification that someone wants to pair.
/// Tapping it opens the full-screen pair request screen.
class _IncomingPairRequestTile extends StatelessWidget {
  final String bleId;
  final Map<String, dynamic> info;
  const _IncomingPairRequestTile({required this.bleId, required this.info});

  @override
  Widget build(BuildContext context) {
    final nick = info['nick'] as String? ?? 'Unknown';
    final theme = Theme.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutBack,
      builder: (_, value, child) => Transform.scale(
        scale: 0.8 + 0.2 * value,
        child: Opacity(opacity: value, child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Card(
          elevation: 4,
          color: theme.colorScheme.primaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => showPairRequestScreen(context, bleId, info),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.person_add,
                      color: theme.colorScheme.primary, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nick,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: theme.colorScheme.onPrimaryContainer,
                          )),
                      Text('Хочет обменяться профилями',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.7),
                          )),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onPrimaryContainer
                        .withValues(alpha: 0.5)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Full-screen pair request ────────────────────────────────────

/// Opens full-screen pair request dialog.
void showPairRequestScreen(
    BuildContext context, String bleId, Map<String, dynamic> info) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    pageBuilder: (_, __, ___) =>
        _PairRequestScreen(bleId: bleId, info: info),
    transitionsBuilder: (_, anim, __, child) {
      return SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 350),
  ));
}

class _PairRequestScreen extends StatefulWidget {
  final String bleId;
  final Map<String, dynamic> info;
  const _PairRequestScreen({required this.bleId, required this.info});

  @override
  State<_PairRequestScreen> createState() => _PairRequestScreenState();
}

class _PairRequestScreenState extends State<_PairRequestScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _rippleController;
  bool _loading = false;
  final bool _done = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    setState(() => _loading = true);
    HapticFeedback.mediumImpact();

    final profile = ProfileService.instance.profile;
    if (profile == null) return;

    // Send pair accept — targeted to the requester
    final requesterKey = widget.info['publicKey'] as String? ?? '';
    await GossipRouter.instance.sendPairAccept(
      publicKey: profile.publicKeyHex,
      nick: profile.nickname,
      username: profile.username,
      color: profile.avatarColor,
      emoji: profile.avatarEmoji,
      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
      recipientId: requesterKey,
      tags: profile.tags,
    );

    // Save their contact (with their tags from the pair_req)
    final nick = widget.info['nick'] as String? ?? 'Unknown';
    final theirUsername = widget.info['username'] as String? ?? '';
    final color = widget.info['color'] as int? ?? 0xFF607D8B;
    final emoji = widget.info['emoji'] as String? ?? '';
    final publicKey = widget.info['publicKey'] as String? ?? '';
    final theirTags = (widget.info['tags'] as List<dynamic>?)
            ?.cast<String>() ??
        const <String>[];

    if (publicKey.isNotEmpty) {
      // Always register — pair_req only arrives from direct peers (TTL=1)
      BleService.instance.registerPeerKey(widget.bleId, publicKey);
      // Map ALL unmapped BLE IDs (both central & peripheral roles) to this peer.
      BleService.instance.registerPeerKeyForAllRoles(publicKey);
      // Register their x25519 key for encryption
      final theirX25519 = widget.info['x25519Key'] as String? ?? '';
      if (theirX25519.isNotEmpty) {
        BleService.instance.registerPeerX25519Key(publicKey, theirX25519);
      }
      BleService.instance.setExchangeState(publicKey, 3);
      BleService.instance.clearPendingForPublicKey(publicKey);
      try {
        final existing = await ChatStorageService.instance.getContact(publicKey);
        await ChatStorageService.instance.saveContact(Contact(
          publicKeyHex: publicKey,
          nickname: existing?.nickname ?? nick,
          username: theirUsername.isNotEmpty ? theirUsername : (existing?.username ?? ''),
          avatarColor: color,
          avatarEmoji: emoji,
          avatarImagePath: existing?.avatarImagePath,
          x25519Key: theirX25519.isNotEmpty ? theirX25519 : existing?.x25519Key,
          addedAt: existing?.addedAt ?? DateTime.now(),
          tags: theirTags.isNotEmpty ? theirTags : (existing?.tags ?? const []),
        ));
      } catch (_) {}
    }

    // Broadcast our profile + avatar
    await GossipRouter.instance.broadcastProfile(
      id: profile.publicKeyHex,
      nick: profile.nickname,
      username: profile.username,
      color: profile.avatarColor,
      emoji: profile.avatarEmoji,
      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
      tags: profile.tags,
    );
    // Send full profile (avatar + banner) directly to the paired peer
    final pairedKey = widget.info['publicKey'] as String? ?? '';
    if (pairedKey.isNotEmpty) {
      sendProfileToAllContacts();
    }

    BleService.instance.removePairRequest(widget.bleId);

    if (!mounted) return;
    // Close this screen and open celebration
    final myKey = CryptoService.instance.publicKeyHex;
    final theirKey = widget.info['publicKey'] as String? ?? '';
    final theirNick = widget.info['nick'] as String? ?? 'Unknown';
    Navigator.of(context).pop();
    final ctx = navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      showBoomCelebration(ctx, theirNick, myKey, theirKey);
    }
  }

  void _decline() {
    HapticFeedback.lightImpact();
    BleService.instance.removePairRequest(widget.bleId);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final nick = widget.info['nick'] as String? ?? 'Unknown';
    final color = widget.info['color'] as int? ?? 0xFF607D8B;
    final theme = Theme.of(context);
    final btName = BleService.instance.getDeviceName(widget.bleId);
    final deviceLabel = btName != widget.bleId ? btName : nick;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with close
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _decline,
                  ),
                  const Spacer(),
                  Text('Запрос на обмен',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            // Main content
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Animated BT icon with ripple
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Ripple rings
                          AnimatedBuilder(
                            animation: _rippleController,
                            builder: (_, __) => CustomPaint(
                              size: const Size(160, 160),
                              painter: _RipplePainter(
                                progress: _rippleController.value,
                                color: Color(color),
                              ),
                            ),
                          ),
                          // Pulsing BT icon
                          AnimatedBuilder(
                            animation: _pulseController,
                            builder: (_, child) => Transform.scale(
                              scale: 1.0 + 0.1 * _pulseController.value,
                              child: child,
                            ),
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                color: Color(color).withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Color(color).withValues(alpha: 0.4),
                                  width: 3,
                                ),
                              ),
                              child: _done
                                  ? Icon(Icons.check,
                                      color: Colors.green.shade400, size: 40)
                                  : Icon(Icons.bluetooth,
                                      color: Color(color), size: 36),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Device name
                    Text(deviceLabel,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      _done
                          ? 'Профиль загружен!'
                          : 'Хочет обменяться профилями',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_loading) ...[
                      const SizedBox(height: 24),
                      const SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      const SizedBox(height: 8),
                      Text('Обмен профилями...',
                          style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 13)),
                    ],
                  ],
                ),
              ),
            ),
            // Bottom buttons
            if (!_loading && !_done)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _accept,
                        icon: const Icon(Icons.download, size: 20),
                        label: const Text('Загрузить профиль',
                            style: TextStyle(fontSize: 16)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton(
                        onPressed: _decline,
                        child: const Text('Отклонить',
                            style: TextStyle(fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final double progress;
  final Color color;

  _RipplePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    for (var i = 0; i < 3; i++) {
      final p = ((progress + i * 0.33) % 1.0);
      final radius = 30.0 + p * 50.0;
      final opacity = (1.0 - p) * 0.3;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.progress != progress;
}

// ── Бумшшшш celebration screen ──────────────────────────────────

/// Opens the emoji celebration screen — identical on both devices.
void showBoomCelebration(
    BuildContext context, String peerNick, String myKey, String theirKey) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    pageBuilder: (_, __, ___) => _BoomCelebrationScreen(
      peerNick: peerNick,
      myKey: myKey,
      theirKey: theirKey,
    ),
    transitionsBuilder: (_, anim, __, child) {
      return FadeTransition(opacity: anim, child: child);
    },
    transitionDuration: const Duration(milliseconds: 300),
  ));
}

class _BoomCelebrationScreen extends StatefulWidget {
  final String peerNick;
  final String myKey;
  final String theirKey;
  const _BoomCelebrationScreen({
    required this.peerNick,
    required this.myKey,
    required this.theirKey,
  });

  @override
  State<_BoomCelebrationScreen> createState() =>
      _BoomCelebrationScreenState();
}

class _BoomCelebrationScreenState extends State<_BoomCelebrationScreen>
    with TickerProviderStateMixin {
  late final List<String> _emojis;
  late final int _vibSeed;
  late final AnimationController _fadeController;
  final List<_FallingEmoji> _fallingEmojis = [];

  @override
  void initState() {
    super.initState();
    _emojis = generatePairEmojis(widget.myKey, widget.theirKey);
    _vibSeed = pairVibrationSeed(widget.myKey, widget.theirKey);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    // Generate falling emojis with deterministic positions from seed
    final sorted = [widget.myKey, widget.theirKey]..sort();
    final combined = '${sorted[0]}${sorted[1]}';
    for (var i = 0; i < 40; i++) {
      final c1 = combined.codeUnitAt(i % combined.length);
      final c2 = combined.codeUnitAt((i * 3 + 7) % combined.length);
      _fallingEmojis.add(_FallingEmoji(
        emoji: _emojis[i % _emojis.length],
        x: (c1 * 17 + i * 23) % 100 / 100.0,
        delay: (c2 * 11 + i * 37) % 3000 / 1000.0,
        duration: 2.0 + (c1 % 20) / 10.0,
        size: 24.0 + (c2 % 24),
        rotation: (c1 - 64) / 30.0,
      ));
    }

    // Start celebration vibration
    celebrationVibration(_vibSeed);

    // Auto-close after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        _fadeController.reverse().then((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FadeTransition(
      opacity: _fadeController,
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.85),
        body: Stack(
          children: [
            // Falling emojis
            ..._fallingEmojis.map((e) => _AnimatedFallingEmoji(key: ValueKey(e), data: e)),
            // Center content
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Big boom text
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.elasticOut,
                    builder: (_, v, child) => Transform.scale(
                      scale: v,
                      child: child,
                    ),
                    child: Text('БУМШШШШ!',
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          shadows: [
                            Shadow(
                              color: theme.colorScheme.primary,
                              blurRadius: 30,
                            ),
                          ],
                        )),
                  ),
                  const SizedBox(height: 16),
                  // Connected with
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOut,
                    builder: (_, v, child) => Opacity(opacity: v, child: child),
                    child: Text(
                      'Вы обменялись с ${widget.peerNick}!',
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white70,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Emoji row — unique pair emojis
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutBack,
                    builder: (_, v, child) => Transform.scale(
                      scale: 0.5 + 0.5 * v,
                      child: Opacity(opacity: v, child: child),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      runSpacing: 4,
                      children: _emojis
                          .take(10)
                          .map((e) => Text(e, style: const TextStyle(fontSize: 32)))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
            // Tap to close
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                behavior: HitTestBehavior.translucent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FallingEmoji {
  final String emoji;
  final double x; // 0..1 horizontal position
  final double delay; // seconds before start
  final double duration; // fall duration seconds
  final double size;
  final double rotation;

  const _FallingEmoji({
    required this.emoji,
    required this.x,
    required this.delay,
    required this.duration,
    required this.size,
    required this.rotation,
  });
}

class _AnimatedFallingEmoji extends StatefulWidget {
  final _FallingEmoji data;
  const _AnimatedFallingEmoji({super.key, required this.data});

  @override
  State<_AnimatedFallingEmoji> createState() => _AnimatedFallingEmojiState();
}

class _AnimatedFallingEmojiState extends State<_AnimatedFallingEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.data.duration * 1000).toInt()),
    );
    Future.delayed(
      Duration(milliseconds: (widget.data.delay * 1000).toInt()),
      () {
        if (mounted) _controller.forward();
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final y = -50.0 + _controller.value * (screenHeight + 100);
        final wobble =
            10.0 * (0.5 - (_controller.value * 3.14 * 2).remainder(1.0)).abs();
        return Positioned(
          left: widget.data.x * screenWidth + wobble - widget.data.size / 2,
          top: y,
          child: Opacity(
            opacity: (1.0 - (_controller.value - 0.7).clamp(0.0, 0.3) / 0.3),
            child: Transform.rotate(
              angle: widget.data.rotation * _controller.value,
              child: Text(widget.data.emoji,
                  style: TextStyle(fontSize: widget.data.size)),
            ),
          ),
        );
      },
    );
  }
}

class _NearbyDeviceTile extends StatelessWidget {
  final String publicKeyOrBleId;
  const _NearbyDeviceTile({required this.publicKeyOrBleId});

  Contact? _findContact(List<Contact> contacts) {
    final publicKey = BleService.instance.resolvePublicKey(publicKeyOrBleId);
    for (final c in contacts) {
      if (c.publicKeyHex == publicKey || c.publicKeyHex == publicKeyOrBleId) {
        return c;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Contact>>(
      valueListenable: ChatStorageService.instance.contactsNotifier,
      builder: (_, contacts, __) {
        final contact = _findContact(contacts);
        final btName = BleService.instance.getDeviceName(publicKeyOrBleId);
        final nickname = contact?.nickname ?? btName;
        final color = contact?.avatarColor ?? 0xFF607D8B;
        final emoji = contact?.avatarEmoji ?? '';

        return ListTile(
          leading: AvatarWidget(
            initials: nickname[0].toUpperCase(),
            color: color,
            emoji: emoji,
            imagePath: contact?.avatarImagePath,
            size: 48,
            isOnline: true,
          ),
          title: Text(nickname,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          onTap: () => Navigator.push(
            context,
            slideRoute(
              ChatScreen(
                peerId: publicKeyOrBleId,
                peerNickname: nickname,
                peerAvatarColor: color,
                peerAvatarEmoji: emoji,
                peerAvatarImagePath: contact?.avatarImagePath,
              ),
            ),
          ),
          subtitle: Text(
            contact != null
                ? 'Rlink'
                : btName != publicKeyOrBleId
                    ? btName
                    : '${publicKeyOrBleId.substring(0, publicKeyOrBleId.length.clamp(0, 12))}...',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (contact == null)
              IconButton(
                icon: const Icon(Icons.person_add_outlined),
                tooltip: 'Добавить',
                onPressed: () => _addContact(context, publicKeyOrBleId),
              ),
            IconButton(
              icon: const Icon(Icons.chat),
              tooltip: 'Написать',
              onPressed: () => Navigator.push(
                context,
                slideRoute(
                  ChatScreen(
                    peerId: publicKeyOrBleId,
                    peerNickname: nickname,
                    peerAvatarColor: color,
                    peerAvatarEmoji: emoji,
                    peerAvatarImagePath: contact?.avatarImagePath,
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  void _addContact(BuildContext context, String peerId) {
    final resolvedKey = BleService.instance.resolvePublicKey(peerId);
    // Require valid Ed25519 public key before sending pair_req
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(resolvedKey)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Профиль ещё не загружен — подождите несколько секунд'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    final profile = ProfileService.instance.profile;
    if (profile == null) return;
    GossipRouter.instance.sendPairRequest(
      publicKey: profile.publicKeyHex,
      nick: profile.nickname,
      username: profile.username,
      color: profile.avatarColor,
      emoji: profile.avatarEmoji,
      recipientId: resolvedKey,
      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
      tags: profile.tags,
    );
    BleService.instance.setExchangeState(peerId, 1); // invite sent
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Запрос на обмен отправлен'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
