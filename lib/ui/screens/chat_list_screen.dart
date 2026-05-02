import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../models/channel.dart';
import '../../models/contact.dart';
import '../../services/ai_bot_constants.dart';
import '../../services/app_settings.dart';
import '../../services/chat_inbox_service.dart';
import '../../services/ble_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/dm_bot_flags.dart';
import '../../services/dm_compose_draft_service.dart';
import '../../services/crypto_service.dart';
import '../../services/ether_service.dart';
import '../../services/group_service.dart';
import '../../models/user_profile.dart';
import '../../services/profile_service.dart';
import '../../services/connection_transport.dart';
import '../../l10n/app_l10n.dart';
import '../../services/gossip_router.dart';
import '../../services/relay_service.dart';
import '../../services/story_service.dart';
import '../../services/audio_queue_mini_player_layout.dart';
import '../../services/platform_capabilities.dart';
import '../../services/wifi_direct_service.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/mesh_radar_widget.dart';
import '../widgets/status_emoji_view.dart';
import '../widgets/update_available_banner.dart';
import '../../utils/message_preview_formatter.dart'
    show
        formatChannelPostPreview,
        formatGroupMessagePreview,
        dmLastMessagePreview;
import 'channels_screen.dart';
import 'bot_catalog_screen.dart';
import 'chat_screen.dart';
import 'ether_screen.dart';
import 'groups_screen.dart';
import 'location_map_screen.dart';
import 'profile_screen.dart';
import 'call_history_screen.dart';
import 'chat_inbox_filters_manage_screen.dart';
import 'settings_screen.dart';
import 'story_creator_screen.dart';
import 'story_viewer_screen.dart';
import '../rlink_nav_routes.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with UpdateAvailableBannerMixin {
  /// 0=Чаты, 1=Рядом, 2=Эфир, 3=Я
  int _currentTab = 0;
  bool _homeMiniPlayerLayoutCallbackPending = false;
  bool _searchActive = false;
  final _searchController = TextEditingController();
  final ValueNotifier<bool> _nearbyShowRadar = ValueNotifier(true);

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
    _nearbyShowRadar.dispose();
    AudioQueueMiniPlayerLayout.instance.clearBarTop();
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

  Future<void> _openBotsCatalog() async {
    await Navigator.push(
      context,
      rlinkChatRoute(const BotCatalogScreen()),
    );
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
    if (!AppSettings.instance.channelsEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Каналы недоступны в текущем режиме'),
        ),
      );
      return;
    }
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
                decoration:
                    const InputDecoration(hintText: 'Описание (необязательно)'),
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
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final uname = usernameCtrl.text.trim().toLowerCase();
                if (uname.isNotEmpty) {
                  final taken =
                      await ChannelService.instance.isUsernameTaken(uname);
                  if (taken) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Этот юзернейм уже занят')),
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
                    description: descCtrl.text.trim().isNotEmpty
                        ? descCtrl.text.trim()
                        : null,
                  );
                  await ch.broadcastGossipMeta();
                  if (mounted) {
                    Navigator.push(
                        context,
                        rlinkPushRoute(
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
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
                  Navigator.push(
                      context,
                      rlinkPushRoute(
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

  void _showEtherBroadcastOptions(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ListenableBuilder(
            listenable: EtherBroadcastOptions.instance,
            builder: (context, _) {
              final o = EtherBroadcastOptions.instance;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Icon(Icons.cell_tower_rounded,
                            color: cs.primary, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          AppL10n.t('nav_ether'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    value: o.anonymous,
                    title: const Text('Анонимно'),
                    secondary: const Icon(Icons.person_off_outlined),
                    onChanged: o.setAnonymous,
                  ),
                  SwitchListTile(
                    value: o.attachGeo,
                    title: const Text('Прикреплять геолокацию'),
                    secondary: const Icon(Icons.location_on_outlined),
                    onChanged: o.setAttachGeo,
                  ),
                  if (o.attachGeo)
                    ListTile(
                      leading: const Icon(Icons.map_rounded),
                      title: Text(
                        o.hasCustomLocation
                            ? 'Выбрана точка на карте'
                            : 'Выбрать точку на карте',
                      ),
                      subtitle: Text(
                        o.hasCustomLocation
                            ? '${o.customLatitude!.toStringAsFixed(5)}, ${o.customLongitude!.toStringAsFixed(5)}'
                            : 'Иначе отправляется текущее местоположение',
                      ),
                      trailing: o.hasCustomLocation
                          ? IconButton(
                              tooltip: 'Сбросить точку',
                              onPressed: o.clearCustomLocation,
                              icon: const Icon(Icons.close_rounded),
                            )
                          : null,
                      onTap: () async {
                        final picked = await Navigator.of(context)
                            .push<LocationPickResult>(
                          MaterialPageRoute(
                            builder: (_) => LocationMapScreen(
                              initialLat: o.customLatitude,
                              initialLng: o.customLongitude,
                              allowPicking: true,
                              title: 'Геолокация для Эфира',
                              confirmButtonLabel: 'Использовать эту точку',
                            ),
                          ),
                        );
                        if (picked == null) return;
                        o.setCustomLocation(
                          latitude: picked.latitude,
                          longitude: picked.longitude,
                        );
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _syncHomeMiniPlayerBarTop(BuildContext context) {
    if (_homeMiniPlayerLayoutCallbackPending) return;
    _homeMiniPlayerLayoutCallbackPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeMiniPlayerLayoutCallbackPending = false;
      if (!mounted) return;
      if (_currentTab != 0) {
        AudioQueueMiniPlayerLayout.instance.clearBarTop();
      } else if (_searchActive) {
        AudioQueueMiniPlayerLayout.instance.setBarTopBelowAppBar(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncHomeMiniPlayerBarTop(context);
    final settings = AppSettings.instance;
    final channelsEnabled = settings.channelsEnabled;
    final childLinked = settings.isLinkedChildDevice;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor:
            isDark ? const Color(0xFF121212) : const Color(0xFFF2F2F2),
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
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: Text(
                  _currentTab == 0
                      ? 'Rlink'
                      : _currentTab == 1
                          ? AppL10n.t('nav_nearby')
                          : _currentTab == 2
                              ? AppL10n.t('nav_ether')
                              : _currentTab == 3
                                  ? AppL10n.t('nav_call_history')
                                  : AppL10n.t('nav_me'),
                  key: ValueKey<int>(_currentTab),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 22),
                ),
              ),
        leading: _searchActive
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _toggleSearch,
              )
            : null,
        actions: [
          if (_currentTab == 0 && !_searchActive && !childLinked)
            PopupMenuButton<String>(
              tooltip: AppL10n.t('main_menu_tooltip'),
              onSelected: (v) {
                if (v == 'channel') _createChannel();
                if (v == 'group') _createGroup();
                if (v == 'bots') _openBotsCatalog();
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'bots',
                  child: Row(children: [
                    Icon(Icons.smart_toy_outlined,
                        size: 20, color: Theme.of(ctx).colorScheme.primary),
                    const SizedBox(width: 10),
                    const Text('Боты'),
                  ]),
                ),
                if (channelsEnabled)
                  PopupMenuItem(
                    value: 'channel',
                    child: Row(children: [
                      Icon(Icons.campaign_outlined,
                          size: 20, color: Theme.of(ctx).colorScheme.primary),
                      const SizedBox(width: 10),
                      const Text('Новый канал'),
                    ]),
                  ),
                PopupMenuItem(
                  value: 'group',
                  child: Row(children: [
                    Icon(Icons.group_add_outlined,
                        size: 20, color: Theme.of(ctx).colorScheme.primary),
                    const SizedBox(width: 10),
                    const Text('Новая группа'),
                  ]),
                ),
              ],
            ),
          if (_currentTab == 1 && !_searchActive)
            ValueListenableBuilder<bool>(
              valueListenable: _nearbyShowRadar,
              builder: (ctx, radar, _) {
                final cs = Theme.of(ctx).colorScheme;
                return PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'Вид и обновление',
                  onSelected: (v) {
                    if (v == 'rescan') _rescan();
                    if (v == 'radar') _nearbyShowRadar.value = true;
                    if (v == 'list') _nearbyShowRadar.value = false;
                  },
                  itemBuilder: (ctx2) => [
                    PopupMenuItem(
                      value: 'rescan',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading:
                            Icon(Icons.refresh, color: cs.primary, size: 22),
                        title: const Text('Обновить поиск'),
                        subtitle: const Text('Сканировать устройства рядом',
                            style: TextStyle(fontSize: 11)),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'radar',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.radar, color: cs.primary, size: 22),
                        title: const Text('Радар'),
                        trailing:
                            radar ? Icon(Icons.check, color: cs.primary) : null,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'list',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.list_rounded,
                            color: cs.primary, size: 22),
                        title: const Text('Список'),
                        trailing: !radar
                            ? Icon(Icons.check, color: cs.primary)
                            : null,
                      ),
                    ),
                  ],
                );
              },
            ),
          if (_currentTab == 0 && !_searchActive)
            ListenableBuilder(
              listenable: ChatInboxService.instance,
              builder: (ctx, _) {
                final inbox = ChatInboxService.instance;
                final cs = Theme.of(ctx).colorScheme;
                return IconButton(
                  icon: Icon(
                    inbox.archiveView
                        ? Icons.inventory_2
                        : Icons.inventory_2_outlined,
                    color: inbox.archiveView ? cs.primary : null,
                  ),
                  tooltip: 'Архив',
                  onPressed: () => inbox.setArchiveView(!inbox.archiveView),
                );
              },
            ),
          if (_currentTab == 0)
            IconButton(
              icon: Icon(_searchActive ? Icons.close : Icons.search),
              tooltip: _searchActive ? 'Закрыть' : 'Поиск',
              onPressed: _toggleSearch,
            ),
          if (_currentTab == 2 && !_searchActive)
            IconButton(
              tooltip: AppL10n.t('nav_ether'),
              onPressed: () => _showEtherBroadcastOptions(context),
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
      body: IndexedStack(
        index: _currentTab,
        children: [
          _UnifiedChatsTab(
            searchQuery: _searchActive ? _searchController.text : '',
            layoutActive: _currentTab == 0 &&
                !_searchActive &&
                (ModalRoute.of(context)?.isCurrent ?? true),
          ),
          _NearbyTab(showRadar: _nearbyShowRadar),
          const EtherScreen(),
          const CallHistoryScreen(),
          const _MeTab(),
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

// ── Аватар в нижнем меню (вкладка «Я») ────────────────────────────

class _MeTabNavIcon extends StatelessWidget {
  final bool selected;
  const _MeTabNavIcon({required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<UserProfile?>(
      valueListenable: ProfileService.instance.profileNotifier,
      builder: (context, profile, _) {
        if (profile == null) {
          return Icon(
            selected ? Icons.person : Icons.person_outline,
            size: 24,
          );
        }
        final avatar = AvatarWidget(
          initials: profile.initials,
          color: profile.avatarColor,
          emoji: profile.avatarEmoji,
          imagePath: profile.avatarImagePath,
          size: selected ? 26 : 24,
        );
        if (!selected) {
          return Opacity(opacity: 0.85, child: avatar);
        }
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: cs.primary, width: 2),
          ),
          child: avatar,
        );
      },
    );
  }
}

// ── Animated bottom nav bar (5 tabs) ─────────────────────────────

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
      animationDuration: const Duration(milliseconds: 520),
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
            builder: (_, count, __) => count > 0 &&
                    AppSettings.instance.connectionMode != 1
                ? Badge(label: Text('$count'), child: const Icon(Icons.radar))
                : const Icon(Icons.radar_outlined),
          ),
          selectedIcon: ValueListenableBuilder<int>(
            valueListenable: BleService.instance.peersCount,
            builder: (_, count, __) => count > 0 &&
                    AppSettings.instance.connectionMode != 1
                ? Badge(label: Text('$count'), child: const Icon(Icons.radar))
                : const Icon(Icons.radar),
          ),
          label: AppL10n.t('nav_nearby'),
        ),
        NavigationDestination(
          icon: ValueListenableBuilder<int>(
            valueListenable: EtherService.instance.unreadCount,
            builder: (_, count, __) => count > 0
                ? Badge(
                    label: Text('$count'), child: const Icon(Icons.cell_tower))
                : const Icon(Icons.cell_tower),
          ),
          selectedIcon: const Icon(Icons.cell_tower),
          label: AppL10n.t('nav_ether'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.history),
          selectedIcon: const Icon(Icons.history),
          label: AppL10n.t('nav_call_history'),
        ),
        NavigationDestination(
          icon: const _MeTabNavIcon(selected: false),
          selectedIcon: const _MeTabNavIcon(selected: true),
          label: AppL10n.t('nav_me'),
        ),
      ],
    );
  }
}

class _MeTab extends StatelessWidget {
  const _MeTab();

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;
    if (settings.isLinkedChildDevice) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        children: [
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: ListTile(
              leading: Icon(Icons.lock_person_outlined, color: cs.primary),
              title: const Text('Дочернее устройство'),
              subtitle: Text(
                settings.linkedDeviceNickname.isNotEmpty
                    ? 'Связано с: ${settings.linkedDeviceNickname}'
                    : settings.linkedDevicePublicKey,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link_off_rounded, color: Colors.red),
            title: const Text(
              'Отвязаться',
              style: TextStyle(color: Colors.red),
            ),
            subtitle: const Text(
              'После отвязки снова станут доступны все разделы',
              style: TextStyle(fontSize: 12),
            ),
            onTap: () async {
              final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Отвязать устройство?'),
                      content: const Text(
                        'Связка будет снята и на главном устройстве.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Отмена'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Отвязать'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!ok) return;
              final linkedKey = settings.linkedDevicePublicKey;
              final me = ProfileService.instance.profile;
              if (me != null &&
                  linkedKey.isNotEmpty &&
                  RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(linkedKey)) {
                await RelayService.instance.connect();
                await GossipRouter.instance.sendDeviceUnlink(
                  publicKey: me.publicKeyHex,
                  recipientId: linkedKey,
                );
              }
              await settings.unlinkDevice();
              await applyConnectionTransport();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Связка устройств снята')),
              );
            },
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      children: [
        if (profile != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              leading: Hero(
                tag: 'avatar_my_profile',
                child: Material(
                  color: Colors.transparent,
                  child: AvatarWidget(
                    initials: profile.initials,
                    color: profile.avatarColor,
                    emoji: profile.avatarEmoji,
                    imagePath: profile.avatarImagePath,
                    size: 52,
                  ),
                ),
              ),
              title: Text(
                profile.nickname,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: profile.statusEmoji.isEmpty
                  ? Text(AppL10n.t('menu_open_profile'))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusEmojiView(
                          statusEmoji: profile.statusEmoji,
                          fontSize: 16,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(AppL10n.t('menu_open_profile')),
                        ),
                      ],
                    ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                rlinkPushRoute(const ProfileScreen()),
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 28),
          child: SettingsCategoryCards(),
        ),
      ],
    );
  }
}

// ── Единый список: чаты + группы + каналы (Telegram-style) ──────

enum _ChatItemType { personal, group, channel }

String _dmChatListBotChipLabel(String peerId) {
  if (peerId == kLibBotPeerId) return 'Lib';
  if (peerId == kEmojiBotPeerId) return 'Emoji';
  if (peerId == kGigachatBotPeerId) return 'ИИ';
  return 'Бот';
}

/// Превью строки в списке чатов: при несохранённом вводе — «Черновик: …» вместо последнего сообщения.
String _dmChatListPreviewOrDraft(
  String peerId,
  String lastMessagePreview,
  Map<String, String> drafts,
) {
  final pid = ChatStorageService.normalizeDmPeerId(peerId);
  final d = drafts[pid];
  if (d == null || d.trim().isEmpty) return lastMessagePreview;
  final oneLine = d.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  if (oneLine.isEmpty) return lastMessagePreview;
  final short = oneLine.length > 52 ? '${oneLine.substring(0, 52)}…' : oneLine;
  return 'Черновик: $short';
}

class _UnifiedChatsTab extends StatefulWidget {
  final String searchQuery;
  /// Вкладка «Чаты» видна и поиск не открыт — якорь под фильтрами актуален.
  final bool layoutActive;
  const _UnifiedChatsTab({
    this.searchQuery = '',
    this.layoutActive = true,
  });

  @override
  State<_UnifiedChatsTab> createState() => _UnifiedChatsTabState();
}

class _UnifiedChatsTabState extends State<_UnifiedChatsTab> {
  final GlobalKey _miniPlayerListAnchor = GlobalKey(debugLabel: 'miniPlayerListAnchor');
  bool _miniPlayerAnchorCallbackPending = false;
  List<_ChatItem> _items = [];
  StreamSubscription<IncomingMessage>? _sub;
  Timer? _loadDebounce;
  VoidCallback? _groupListener;
  VoidCallback? _channelListener;
  VoidCallback? _bleListener; // fires on BLE peer connect/disconnect
  VoidCallback? _relayListener;
  VoidCallback? _wifiListener;
  VoidCallback? _contactListener; // fires when contactsNotifier updates
  VoidCallback? _readStateListener;
  VoidCallback? _settingsListener;
  VoidCallback? _draftRevisionListener;
  VoidCallback? _botDirListener;
  late final VoidCallback _inboxListener;

  @override
  void initState() {
    super.initState();
    _inboxListener = () {
      if (mounted) setState(() {});
    };
    ChatInboxService.instance.addListener(_inboxListener);
    _load();
    _sub = incomingMessageController.stream.listen((_) {
      _loadDebounce?.cancel();
      _loadDebounce = Timer(const Duration(milliseconds: 300), _load);
    });
    _groupListener = () => _debouncedLoad();
    _channelListener = () => _debouncedLoad();
    // Rebuild when BLE peers connect/disconnect so the green dot updates live.
    _bleListener = () => _debouncedLoad();
    _relayListener = () => _debouncedLoad();
    _wifiListener = () => _debouncedLoad();
    // Also rebuild when contacts change (avatar/banner/nickname updates).
    _contactListener = () => _debouncedLoad();
    GroupService.instance.version.addListener(_groupListener!);
    ChannelService.instance.version.addListener(_channelListener!);
    BleService.instance.peersCount.addListener(_bleListener!);
    RelayService.instance.state.addListener(_relayListener!);
    RelayService.instance.onlineCount.addListener(_relayListener!);
    WifiDirectService.instance.peersCount.addListener(_wifiListener!);
    ChatStorageService.instance.contactsNotifier.addListener(_contactListener!);
    _readStateListener = () => _debouncedLoad();
    ChatStorageService.instance.readStateVersion
        .addListener(_readStateListener!);
    _settingsListener = () => _debouncedLoad();
    AppSettings.instance.addListener(_settingsListener!);
    _draftRevisionListener = () => _debouncedLoad();
    DmComposeDraftService.instance.revision
        .addListener(_draftRevisionListener!);
    _botDirListener = () => _debouncedLoad();
    RelayService.instance.botDirectoryVersion.addListener(_botDirListener!);
  }

  void _debouncedLoad() {
    _loadDebounce?.cancel();
    _loadDebounce = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  void dispose() {
    _loadDebounce?.cancel();
    _sub?.cancel();
    if (_groupListener != null) {
      GroupService.instance.version.removeListener(_groupListener!);
    }
    if (_channelListener != null) {
      ChannelService.instance.version.removeListener(_channelListener!);
    }
    if (_bleListener != null) {
      BleService.instance.peersCount.removeListener(_bleListener!);
    }
    if (_relayListener != null) {
      RelayService.instance.state.removeListener(_relayListener!);
      RelayService.instance.onlineCount.removeListener(_relayListener!);
    }
    if (_wifiListener != null) {
      WifiDirectService.instance.peersCount.removeListener(_wifiListener!);
    }
    if (_contactListener != null) {
      ChatStorageService.instance.contactsNotifier
          .removeListener(_contactListener!);
    }
    if (_readStateListener != null) {
      ChatStorageService.instance.readStateVersion
          .removeListener(_readStateListener!);
    }
    if (_settingsListener != null) {
      AppSettings.instance.removeListener(_settingsListener!);
    }
    if (_draftRevisionListener != null) {
      DmComposeDraftService.instance.revision
          .removeListener(_draftRevisionListener!);
    }
    if (_botDirListener != null) {
      RelayService.instance.botDirectoryVersion
          .removeListener(_botDirListener!);
    }
    ChatInboxService.instance.removeListener(_inboxListener);
    super.dispose();
  }

  void _layoutMiniPlayerAnchor() {
    if (!widget.layoutActive || widget.searchQuery.isNotEmpty) return;
    if (_miniPlayerAnchorCallbackPending) return;
    _miniPlayerAnchorCallbackPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _miniPlayerAnchorCallbackPending = false;
      if (!mounted || !widget.layoutActive || widget.searchQuery.isNotEmpty) {
        return;
      }
      AudioQueueMiniPlayerLayout.instance
          .scheduleBarTopFromAnchor(_miniPlayerListAnchor);
    });
  }

  Future<void> _load() async {
    final items = <_ChatItem>[];
    final settings = AppSettings.instance;
    final myId = CryptoService.instance.publicKeyHex;
    final linkedPrimaryId = settings.linkedDevicePublicKey.trim();
    final childLinked = settings.isLinkedChildDevice;
    final membershipKeys = <String>{
      if (myId.isNotEmpty) myId,
      if (childLinked && linkedPrimaryId.isNotEmpty) linkedPrimaryId,
    };
    final showOnline = settings.showOnlineStatus;
    final wifiConnected = WifiDirectService.instance.peersCount.value > 0;
    final channelsEnabled = settings.channelsEnabled;
    final dmUnread = await ChatStorageService.instance.getDmUnreadCounts();
    final groupUnread = await GroupService.instance.getGroupUnreadCounts();
    final channelUnread = channelsEnabled
        ? await ChannelService.instance.getChannelUnreadCounts()
        : <String, int>{};

    final dmDrafts = await DmComposeDraftService.instance.getAllDrafts();

    final contacts = await ChatStorageService.instance.getContacts();
    final contactById = <String, Contact>{
      for (final c in contacts) c.publicKeyHex: c,
    };

    // 1) Личные чаты
    final summaries = await ChatStorageService.instance.getChatSummaries();
    final summaryIds = <String>{};
    for (final s in summaries) {
      if (myId.isNotEmpty && s.peerId == myId) continue;
      final transports =
          _resolvePresenceTransports(s.peerId, wifiConnected: wifiConnected);
      summaryIds.add(s.peerId);
      items.add(_ChatItem(
        type: _ChatItemType.personal,
        id: s.peerId,
        nickname: s.nickname ??
            '${s.peerId.substring(0, s.peerId.length.clamp(0, 8))}...',
        avatarColor: s.avatarColor ?? 0xFF607D8B,
        avatarEmoji: s.avatarEmoji ?? '',
        avatarImagePath: s.avatarImagePath,
        statusEmoji: contactById[s.peerId]?.statusEmoji ?? '',
        lastMessage:
            _dmChatListPreviewOrDraft(s.peerId, s.displayText, dmDrafts),
        lastTime: s.timestamp,
        isOnline: showOnline && transports.isNotEmpty,
        onlineTransports: transports,
        showPresenceStatus: showOnline,
        isAiBot: isDmBotPeerId(s.peerId),
        unreadCount: dmUnread[s.peerId] ?? 0,
      ));
    }

    // 1б) Контакты без переписки — добавляем с пустым lastMessage
    for (final c in contacts) {
      if (myId.isNotEmpty && c.publicKeyHex == myId) continue;
      if (summaryIds.contains(c.publicKeyHex)) continue;
      final transports = _resolvePresenceTransports(
        c.publicKeyHex,
        wifiConnected: wifiConnected,
      );
      items.add(_ChatItem(
        type: _ChatItemType.personal,
        id: c.publicKeyHex,
        nickname: c.nickname.isNotEmpty
            ? c.nickname
            : '${c.publicKeyHex.substring(0, 8)}...',
        avatarColor: c.avatarColor,
        avatarEmoji: c.avatarEmoji,
        avatarImagePath: c.avatarImagePath,
        statusEmoji: c.statusEmoji,
        lastMessage: _dmChatListPreviewOrDraft(c.publicKeyHex, '', dmDrafts),
        lastTime: c.addedAt,
        isOnline: showOnline && transports.isNotEmpty,
        onlineTransports: transports,
        showPresenceStatus: showOnline,
        isAiBot: isDmBotPeerId(c.publicKeyHex),
        unreadCount: 0,
      ));
    }

    // 2) Группы — только те, где я участник или создатель.
    final groups = await GroupService.instance.getGroups();
    for (final g in groups) {
      if (membershipKeys.isEmpty) continue;
      final visibleForMe = membershipKeys.contains(g.creatorId) ||
          g.memberIds.any(membershipKeys.contains);
      if (!visibleForMe) {
        continue;
      }
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
        onlineTransports: const [],
        unreadCount: groupUnread[g.id] ?? 0,
      ));
    }

    // 3) Каналы — только те, где я подписан или являюсь админом.
    if (channelsEnabled) {
      final channels = await ChannelService.instance.getChannels();
      for (final ch in channels) {
        if (membershipKeys.isEmpty) continue;
        final visibleForMe = membershipKeys.contains(ch.adminId) ||
            ch.subscriberIds.any(membershipKeys.contains) ||
            ch.moderatorIds.any(membershipKeys.contains) ||
            ch.linkAdminIds.any(membershipKeys.contains);
        if (!visibleForMe) {
          continue;
        }
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
          onlineTransports: const [],
          unreadCount: channelUnread[ch.id] ?? 0,
          channelVerified: ch.verified,
        ));
      }
    }

    // Сортируем по последнему сообщению (новые сверху)
    items.sort((a, b) => b.lastTime.compareTo(a.lastTime));

    if (myId.isNotEmpty && !childLinked) {
      final savedLast = await ChatStorageService.instance.getLastMessage(myId);
      final savedPreview = savedLast != null
          ? dmLastMessagePreview(savedLast)
          : AppL10n.t('chat_saved_messages_empty');
      final savedTime =
          savedLast?.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
      final savedLine = _dmChatListPreviewOrDraft(myId, savedPreview, dmDrafts);
      items.insert(
        0,
        _ChatItem(
          isSavedMessages: true,
          savedHasMessages: savedLast != null,
          id: myId,
          nickname: AppL10n.t('chat_saved_messages'),
          avatarColor: 0xFF26A69A,
          avatarEmoji: '⭐',
          avatarImagePath: null,
          lastMessage: savedLine,
          lastTime: savedTime,
          isOnline: false,
          onlineTransports: const [],
          unreadCount: 0,
        ),
      );
    }

    if (!mounted) return;
    setState(() => _items = items);
  }

  List<AvatarPresenceTransport> _resolvePresenceTransports(
    String peerId, {
    required bool wifiConnected,
  }) {
    final transports = <AvatarPresenceTransport>[];
    if (BleService.instance.isPeerConnected(peerId)) {
      transports.add(AvatarPresenceTransport.bluetooth);
    }
    if (RelayService.instance.isPeerOnline(peerId)) {
      transports.add(AvatarPresenceTransport.internet);
    }
    if (wifiConnected && transports.isEmpty) {
      transports.add(AvatarPresenceTransport.wifiDirect);
    }
    return transports;
  }

  Future<void> _navigate(BuildContext context, _ChatItem item) async {
    switch (item.type) {
      case _ChatItemType.personal:
        await Navigator.push(
            context,
            rlinkChatRoute(ChatScreen(
              peerId: item.id,
              peerNickname: item.nickname,
              peerAvatarColor: item.avatarColor,
              peerAvatarEmoji: item.avatarEmoji,
              peerAvatarImagePath: item.avatarImagePath,
            )));
      case _ChatItemType.group:
        final group = await GroupService.instance.getGroup(item.id);
        if (group == null || !context.mounted) return;
        await Navigator.push(
            context,
            rlinkPushRoute(
              GroupChatScreen(group: group),
            ));
      case _ChatItemType.channel:
        if (!AppSettings.instance.channelsEnabled) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Каналы недоступны в текущем режиме'),
            ),
          );
          return;
        }
        final channel = await ChannelService.instance.getChannel(item.id);
        if (channel == null || !context.mounted) return;
        await Navigator.push(
            context,
            rlinkPushRoute(
              ChannelViewScreen(channel: channel),
            ));
    }
    if (mounted) _load();
  }

  List<_ChatItem> _storiesSource() {
    final inbox = ChatInboxService.instance;
    return _items
        .where((it) => !inbox.isArchived(_chatItemInboxKey(it)))
        .toList();
  }

  List<_ChatItem> _computeVisibleItems() {
    final inbox = ChatInboxService.instance;
    final tab = inbox.selectedTab;

    Iterable<_ChatItem> pool = _items;
    if (inbox.archiveView) {
      pool = pool.where((it) => inbox.isArchived(_chatItemInboxKey(it)));
    } else {
      pool = pool.where((it) => !inbox.isArchived(_chatItemInboxKey(it)));
      if (tab != null) {
        pool = pool.where((it) {
          final k = _chatItemInboxKey(it);
          final kind = _chatItemInboxKind(it);
          return tab.matches(k, kind);
        });
      }
    }

    final list = pool.toList();
    if (inbox.archiveView) {
      list.sort((a, b) => b.lastTime.compareTo(a.lastTime));
      return list;
    }

    final pinOrder = inbox.pinOrder;
    final keysIn = {for (final x in list) _chatItemInboxKey(x): x};
    final out = <_ChatItem>[];

    _ChatItem? saved;
    for (final it in list) {
      if (it.isSavedMessages) {
        saved = it;
        break;
      }
    }
    if (saved != null) out.add(saved);

    _ChatItem? aiItem;
    String? aiKey;
    for (final it in list) {
      if (it.isAiBot) {
        aiItem = it;
        aiKey = _chatItemInboxKey(it);
        break;
      }
    }

    for (final key in pinOrder) {
      if (saved != null && key == _chatItemInboxKey(saved)) continue;
      final it = keysIn[key];
      if (it != null) out.add(it);
    }

    var used = out.map(_chatItemInboxKey).toSet();
    if (aiItem != null && aiKey != null && !used.contains(aiKey)) {
      out.add(aiItem);
      used = out.map(_chatItemInboxKey).toSet();
    }

    final tail =
        list.where((it) => !used.contains(_chatItemInboxKey(it))).toList();
    tail.sort((a, b) => b.lastTime.compareTo(a.lastTime));
    out.addAll(tail);
    return out;
  }

  void _showChatItemActions(BuildContext context, _ChatItem item) {
    final inbox = ChatInboxService.instance;
    final key = _chatItemInboxKey(item);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (inbox.archiveView)
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('Вернуть из архива'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await inbox.unarchive(key);
                },
              )
            else ...[
              if (inbox.isPinned(key))
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: const Text('Открепить'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await inbox.unpin(key);
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: const Text('Закрепить'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await inbox.pin(key);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('В архив'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await inbox.archive(key);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPinReorderSheet(BuildContext context) {
    final inbox = ChatInboxService.instance;
    final keyToItem = {for (final x in _items) _chatItemInboxKey(x): x};
    var keys = List<String>.from(inbox.pinOrder);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Порядок закреплённых',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: MediaQuery.of(ctx).size.height * 0.45,
                      child: ReorderableListView.builder(
                        itemCount: keys.length,
                        onReorder: (oldI, newI) {
                          setSt(() {
                            if (newI > oldI) newI--;
                            final x = keys.removeAt(oldI);
                            keys.insert(newI, x);
                          });
                        },
                        itemBuilder: (_, i) {
                          final k = keys[i];
                          return ListTile(
                            key: ValueKey(k),
                            leading: const Icon(Icons.drag_handle),
                            title: Text(keyToItem[k]?.nickname ?? k),
                          );
                        },
                      ),
                    ),
                    FilledButton(
                      onPressed: () async {
                        await inbox.setPinOrder(keys);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Готово'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final inbox = ChatInboxService.instance;
    final cs = Theme.of(context).colorScheme;
    if (inbox.archiveView) {
      return Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => inbox.setArchiveView(false),
                tooltip: 'Закрыть архив',
              ),
              const Expanded(
                child: Text(
                  'Архив',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            children: [
              for (final tab in inbox.tabs)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(inbox.tabLabel(tab)),
                    selected: inbox.selectedTabId == tab.id,
                    onSelected: (_) => inbox.setSelectedTab(tab.id),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 8, 2),
          child: Wrap(
            spacing: 0,
            children: [
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  rlinkPushRoute(const ChatInboxFiltersManageScreen()),
                ),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Фильтры'),
              ),
              if (inbox.pinOrder.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _showPinReorderSheet(context),
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  label: const Text('Закреплённые'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPendingBanners(BuildContext context) {
    final inbox = ChatInboxService.instance;
    if (inbox.archiveView) return const SizedBox.shrink();
    return ValueListenableBuilder<Map<String, Map<String, dynamic>>>(
      valueListenable: BleService.instance.incomingPairRequests,
      builder: (_, pairRequests, __) {
        return ValueListenableBuilder<List<ChannelInvite>>(
          valueListenable: ChannelService.instance.pendingChannelInvites,
          builder: (_, channelInvites, __) {
            return ValueListenableBuilder<List<GroupInvite>>(
              valueListenable: GroupService.instance.pendingInvites,
              builder: (_, groupInvites, __) {
                final hasAnything = pairRequests.isNotEmpty ||
                    channelInvites.isNotEmpty ||
                    groupInvites.isNotEmpty;
                if (!hasAnything) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  child: Column(
                    children: [
                      for (final e in pairRequests.entries)
                        _buildPendingBannerTile(
                          context,
                          icon: Icons.person_add_alt_1_rounded,
                          iconColor: Theme.of(context).colorScheme.primary,
                          title: (e.value['nick'] as String?)
                                      ?.trim()
                                      .isNotEmpty ==
                                  true
                              ? '${e.value['nick']} хочет обменяться профилем'
                              : 'Новый запрос на обмен профилем',
                          subtitle: 'Нажмите, чтобы открыть запрос',
                          onTap: () => showPairRequestScreen(
                            context,
                            e.key,
                            e.value,
                          ),
                        ),
                      for (final inv in channelInvites)
                        _buildPendingBannerTile(
                          context,
                          icon: Icons.campaign_outlined,
                          iconColor: const Color(0xFF42A5F5),
                          title: 'Приглашение в канал: ${inv.channelName}',
                          subtitle: '${inv.inviterNick} приглашает вас',
                          onTap: () => Navigator.push(
                            context,
                            rlinkPushRoute(const ChannelsScreen()),
                          ),
                        ),
                      for (final inv in groupInvites)
                        _buildPendingBannerTile(
                          context,
                          icon: Icons.group_outlined,
                          iconColor: const Color(0xFF5C6BC0),
                          title: 'Приглашение в группу: ${inv.groupName}',
                          subtitle: '${inv.inviterNick} приглашает вас',
                          onTap: () => Navigator.push(
                            context,
                            rlinkPushRoute(const GroupsScreen()),
                          ),
                        ),
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

  Widget _buildPendingBannerTile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: iconColor, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.searchQuery.toLowerCase().trim();
    final inbox = ChatInboxService.instance;
    final visible = _computeVisibleItems();

    if (_items.isEmpty && q.isEmpty) {
      final col = Column(children: [
        _StoriesStrip(chatItems: _storiesSource()),
        _buildPendingBanners(context),
        SizedBox(height: 0, key: _miniPlayerListAnchor),
        const Expanded(child: _EmptyChatsState()),
      ]);
      _layoutMiniPlayerAnchor();
      return col;
    }

    if (q.isEmpty) {
      if (visible.isEmpty) {
        final col = Column(
          children: [
            _StoriesStrip(chatItems: _storiesSource()),
            _buildFilterBar(context),
            _buildPendingBanners(context),
            SizedBox(height: 0, key: _miniPlayerListAnchor),
            Expanded(
              child: Center(
                child: Text(
                  inbox.archiveView ? 'Архив пуст' : 'Нет чатов в этой вкладке',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ),
            ),
          ],
        );
        _layoutMiniPlayerAnchor();
        return col;
      }
      final col = Column(children: [
        _StoriesStrip(chatItems: _storiesSource()),
        _buildFilterBar(context),
        _buildPendingBanners(context),
        SizedBox(height: 0, key: _miniPlayerListAnchor),
        Expanded(
            child: ListView.separated(
          itemCount: visible.length,
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          separatorBuilder: (_, __) => Divider(
            height: 1,
            indent: 68,
            endIndent: 12,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.22),
          ),
          itemBuilder: (_, i) {
            final item = visible[i];
            final key = _chatItemInboxKey(item);
            final pinned =
                inbox.pinOrder.contains(key) && !item.isSavedMessages;
            return RepaintBoundary(
              child: _TelegramChatRow(
                item: item,
                onTap: () => _navigate(context, item),
                onLongPress: () => _showChatItemActions(context, item),
                showPinned: pinned,
                timeLabel: item.isSavedMessages && !item.savedHasMessages
                    ? ''
                    : _fmtTime(item.lastTime),
              ),
            );
          },
        )),
      ]);
      _layoutMiniPlayerAnchor();
      return col;
    }

    final forSearch =
        _items.where((it) => !inbox.isArchived(_chatItemInboxKey(it))).toList();
    return _UnifiedSearchResults(
      query: q,
      localItems: forSearch,
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
  final VoidCallback? onLongPress;
  final bool showPinned;
  final String timeLabel;

  const _TelegramChatRow({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.showPinned = false,
    required this.timeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final compact = AppSettings.instance.compactMode;
    final avatarSize = compact ? 44.0 : 52.0;
    final subColor = theme.brightness == Brightness.dark
        ? const Color(0xFF8E8E93)
        : const Color(0xFF8E8E93);
    final showVerifiedMark =
        (item.type == _ChatItemType.channel && item.channelVerified) ||
        item.isAiBot;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 6 : 10,
          ),
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
                  size: avatarSize,
                  isOnline: item.isOnline,
                  onlineTransports: item.onlineTransports,
                  hasStory: item.type == _ChatItemType.personal &&
                      !item.isSavedMessages &&
                      !item.isAiBot &&
                      StoryService.instance.hasActiveStory(item.peerId),
                  hasUnviewedStory: item.type == _ChatItemType.personal &&
                      !item.isSavedMessages &&
                      !item.isAiBot &&
                      StoryService.instance.hasUnviewedStory(item.peerId),
                ),
              ),
              SizedBox(width: compact ? 10 : 12),
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
                                size: 18,
                                color: cs.primary.withValues(alpha: 0.75)),
                          ),
                        if (item.type == _ChatItemType.channel)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Icon(Icons.campaign_outlined,
                                size: 18,
                                color: cs.primary.withValues(alpha: 0.75)),
                          ),
                        if (item.isAiBot)
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: cs.primary.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                _dmChatListBotChipLabel(item.id),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          ),
                        if (item.isSavedMessages)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Icon(Icons.bookmark_outline_rounded,
                                size: 18,
                                color: cs.primary.withValues(alpha: 0.85)),
                          ),
                        if (showPinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Icon(Icons.push_pin,
                                size: 16,
                                color: cs.primary.withValues(alpha: 0.65)),
                          ),
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
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
                              if (showVerifiedMark) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.verified,
                                  size: 16,
                                  color: Colors.blue.shade700,
                                ),
                              ],
                              if (item.statusEmoji.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                StatusEmojiView(
                                  statusEmoji: item.statusEmoji,
                                  fontSize: 16,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (item.showPresenceStatus &&
                            item.type == _ChatItemType.personal &&
                            !item.isSavedMessages &&
                            !item.isAiBot) ...[
                          const SizedBox(width: 6),
                          Text(
                            item.isOnline ? 'В сети' : 'Не в сети',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: item.isOnline
                                  ? const Color(0xFF1DB954)
                                  : subColor,
                            ),
                          ),
                        ],
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
                              item.unreadCount > 99
                                  ? '99+'
                                  : '${item.unreadCount}',
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
                    CustomEmojiInlineText(
                      text: item.lastMessage,
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
  final String
      id; // peerId for personal, groupId for group, channelId for channel
  final String nickname, lastMessage, avatarEmoji, statusEmoji;
  final int avatarColor;
  final String? avatarImagePath;
  final DateTime lastTime;
  final bool isOnline;
  final List<AvatarPresenceTransport> onlineTransports;
  final bool showPresenceStatus;
  final int unreadCount;

  /// Чат «Избранное» (сохранённые сообщения у себя).
  final bool isSavedMessages;

  /// Есть ли уже сообщения в избранном (для подписи времени в списке).
  final bool savedHasMessages;

  /// Личка с ботом: Lib, GigaChat или бот из каталога relay.
  final bool isAiBot;
  final bool channelVerified;
  _ChatItem({
    this.type = _ChatItemType.personal,
    required this.id,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    this.statusEmoji = '',
    required this.lastMessage,
    required this.lastTime,
    required this.isOnline,
    this.onlineTransports = const [],
    this.showPresenceStatus = false,
    this.unreadCount = 0,
    this.isSavedMessages = false,
    this.savedHasMessages = true,
    this.isAiBot = false,
    this.channelVerified = false,
  });
  // Backward compat
  String get peerId => id;
}

ChatInboxItemKind _chatItemInboxKind(_ChatItem item) {
  if (item.isSavedMessages) return ChatInboxItemKind.saved;
  switch (item.type) {
    case _ChatItemType.personal:
      return ChatInboxItemKind.dm;
    case _ChatItemType.group:
      return ChatInboxItemKind.group;
    case _ChatItemType.channel:
      return ChatInboxItemKind.channel;
  }
}

String _chatItemInboxKey(_ChatItem item) =>
    chatInboxKey(kind: _chatItemInboxKind(item), id: item.id);

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
  int _channelSearchGen = 0;

  @override
  void initState() {
    super.initState();
    _loadChannels();
    ChannelService.instance.version.addListener(_onChannelsChanged);
    AppSettings.instance.addListener(_onChannelsChanged);
  }

  @override
  void dispose() {
    ChannelService.instance.version.removeListener(_onChannelsChanged);
    AppSettings.instance.removeListener(_onChannelsChanged);
    super.dispose();
  }

  void _onChannelsChanged() => _loadChannels();

  @override
  void didUpdateWidget(_UnifiedSearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _loadChannels();
  }

  Future<void> _loadChannels() async {
    if (!AppSettings.instance.channelsEnabled) {
      if (mounted && _channelMatches.isNotEmpty) {
        setState(() => _channelMatches = []);
      }
      return;
    }
    final gen = ++_channelSearchGen;
    final matches = await ChannelService.instance
        .searchChannels(widget.query, includeHidden: true);
    if (!mounted || gen != _channelSearchGen) return;
    setState(() => _channelMatches = matches);
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.query;

    // 1) Чаты (из localItems)
    final chatMatches = widget.localItems
        .where((item) =>
            item.nickname.toLowerCase().contains(q) ||
            item.lastMessage.toLowerCase().contains(q))
        .toList();

    return ValueListenableBuilder<List<Contact>>(
      valueListenable: ChatStorageService.instance.contactsNotifier,
      builder: (_, contacts, __) {
        // 2) Контакты (без дубликатов с чатами)
        final chatIds = chatMatches.map((c) => c.id).toSet();
        final contactMatches = contacts.where((c) {
          if (chatIds.contains(c.publicKeyHex)) return false;
          final short = c.publicKeyHex.length > 8
              ? c.publicKeyHex.substring(0, 8)
              : c.publicKeyHex;
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
                      timeLabel: m.isSavedMessages && !m.savedHasMessages
                          ? ''
                          : _fmtTimeStatic(m.lastTime),
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
                        rlinkChatRoute(ChatScreen(
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
                        rlinkPushRoute(ChannelViewScreen(channel: ch)),
                      ),
                    ),
                ],
                if (relayPeople.isNotEmpty) ...[
                  _searchSection('Люди в сети', relayPeople.length),
                  for (final p in relayPeople)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
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
                        p.publicKey
                            .substring(0, p.publicKey.length.clamp(0, 16)),
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
                            statusEmoji: myProfile.statusEmoji,
                          );
                        }
                        final nick = p.nick.isNotEmpty ? p.nick : p.shortId;
                        Navigator.push(
                          context,
                          rlinkChatRoute(ChatScreen(
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

                final storiesList = ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                            rlinkPushRoute(
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
                                textX: story.textX,
                                textY: story.textY,
                                textSize: story.textSize,
                                textColor: story.textColor,
                                textBold: story.textBold,
                                textItalic: story.textItalic,
                                textBgOpacity: story.textBgOpacity,
                                overlays: story.overlays
                                    .map((e) => e.toJson())
                                    .toList(),
                              );
                            }
                          });
                        },
                      ),

                    // ── Моя история (только когда есть активные) ────
                    if (myProfile != null &&
                        StoryService.instance
                            .hasActiveStory(myProfile.publicKeyHex))
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
                              rlinkPushRoute(
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
                          .firstWhere((c) => c?.peerId == authorId,
                              orElse: () => null);
                      final name = chatItem?.nickname ??
                          authorId.substring(0, authorId.length.clamp(0, 8));
                      final stories =
                          StoryService.instance.storiesFor(authorId);
                      return _StoryAvatar(
                        label: name,
                        avatar: AvatarWidget(
                          initials:
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
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
                          rlinkPushRoute(
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
                );
                final isWide = MediaQuery.of(context).size.width >= 1100;
                if (!isWide) {
                  return SizedBox(height: 96, child: storiesList);
                }
                final cs = Theme.of(context).colorScheme;
                return SizedBox(
                  height: 106,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: storiesList,
                        ),
                      ),
                    ),
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
                      child:
                          const Icon(Icons.add, size: 12, color: Colors.white),
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
  final ValueNotifier<bool> showRadar;

  const _NearbyTab({required this.showRadar});

  @override
  State<_NearbyTab> createState() => _NearbyTabState();
}

class _NearbyTabState extends State<_NearbyTab> {
  void _navigateToChat(String peerId, String nickname, int color, String emoji,
      String? imagePath) {
    Navigator.push(
      context,
      rlinkChatRoute(ChatScreen(
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
    // Web/Internet-only mode — local mesh is disabled.
    if (PlatformCapabilities.instance.isWeb ||
        AppSettings.instance.connectionMode == 1) {
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

    return ValueListenableBuilder<bool>(
      valueListenable: widget.showRadar,
      builder: (context, showRadar, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: showRadar
              ? MeshRadarWidget(
                  key: const ValueKey('radar'),
                  onPeerTap: _navigateToChat,
                )
              : const _NearbyListView(key: ValueKey('list')),
        );
      },
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
                  return ValueListenableBuilder<
                      Map<String, Map<String, dynamic>>>(
                    valueListenable: BleService.instance.incomingPairRequests,
                    builder: (_, incomingRequests, __) {
                      final peers = BleService.instance.connectedPeerIds;
                      if (peers.isEmpty &&
                          pending.isEmpty &&
                          incomingRequests.isEmpty) {
                        return Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
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
                              .map((id) =>
                                  _NearbyDeviceTile(publicKeyOrBleId: id)),
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
    final isValidKey = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(resolvedKey);

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
        statusEmoji: profile.statusEmoji,
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
        statusEmoji: profile.statusEmoji,
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
    final sourceId = info['sourceId'] as String? ?? bleId;
    final isRelaySource = sourceId.startsWith('relay:');
    final fallbackName =
        bleId.startsWith('relay:') ? bleId.replaceFirst('relay:', '') : bleId;
    final btName = BleService.instance.getDeviceName(fallbackName);
    final hasBleDeviceName = !isRelaySource &&
        btName.isNotEmpty &&
        btName != fallbackName &&
        !btName.startsWith('relay:');
    final displayName = hasBleDeviceName ? btName : nick;

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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                      Text(displayName,
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
    pageBuilder: (_, __, ___) => _PairRequestScreen(bleId: bleId, info: info),
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
      statusEmoji: profile.statusEmoji,
    );

    // Save their contact (with their tags from the pair_req)
    final nick = widget.info['nick'] as String? ?? 'Unknown';
    final theirUsername = widget.info['username'] as String? ?? '';
    final color = widget.info['color'] as int? ?? 0xFF607D8B;
    final emoji = widget.info['emoji'] as String? ?? '';
    final publicKey = widget.info['publicKey'] as String? ?? '';
    final theirTags = (widget.info['tags'] as List<dynamic>?)?.cast<String>() ??
        const <String>[];
    final theirStatusEmoji = UserProfile.normalizeStatusEmoji(
      widget.info['statusEmoji'] as String? ?? '',
    );

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
        final existing =
            await ChatStorageService.instance.getContact(publicKey);
        await ChatStorageService.instance.saveContact(Contact(
          publicKeyHex: publicKey,
          nickname: existing?.nickname ?? nick,
          username: theirUsername.isNotEmpty
              ? theirUsername
              : (existing?.username ?? ''),
          avatarColor: color,
          avatarEmoji: emoji,
          avatarImagePath: existing?.avatarImagePath,
          x25519Key: theirX25519.isNotEmpty ? theirX25519 : existing?.x25519Key,
          addedAt: existing?.addedAt ?? DateTime.now(),
          tags: theirTags.isNotEmpty ? theirTags : (existing?.tags ?? const []),
          bannerImagePath: existing?.bannerImagePath,
          profileMusicPath: existing?.profileMusicPath,
          statusEmoji: theirStatusEmoji.isNotEmpty
              ? theirStatusEmoji
              : (existing?.statusEmoji ?? ''),
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
      statusEmoji: profile.statusEmoji,
    );
    // Send full profile (avatar + banner) directly to the paired peer
    final pairedKey = widget.info['publicKey'] as String? ?? '';
    if (pairedKey.isNotEmpty) {
      await sendFullProfileToPeer(pairedKey);
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
    final sourceId = widget.info['sourceId'] as String? ?? widget.bleId;
    final isRelaySource = sourceId.startsWith('relay:');
    final fallbackName = widget.bleId.startsWith('relay:')
        ? widget.bleId.replaceFirst('relay:', '')
        : widget.bleId;
    final btName = BleService.instance.getDeviceName(fallbackName);
    final hasBleDeviceName = !isRelaySource &&
        btName.isNotEmpty &&
        btName != fallbackName &&
        !btName.startsWith('relay:');
    final deviceLabel = hasBleDeviceName ? btName : nick;

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
  State<_BoomCelebrationScreen> createState() => _BoomCelebrationScreenState();
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
            ..._fallingEmojis
                .map((e) => _AnimatedFallingEmoji(key: ValueKey(e), data: e)),
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
                          .map((e) =>
                              Text(e, style: const TextStyle(fontSize: 32)))
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
        final childLinked = AppSettings.instance.isLinkedChildDevice;

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
            rlinkChatRoute(
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
            if (contact == null && !childLinked)
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
                rlinkChatRoute(
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
    if (AppSettings.instance.isLinkedChildDevice) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('В дочернем режиме добавление контактов недоступно'),
        ),
      );
      return;
    }
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
      statusEmoji: profile.statusEmoji,
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
