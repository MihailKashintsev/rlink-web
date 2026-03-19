import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/contact.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/profile_service.dart';
import '../widgets/avatar_widget.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'contacts_screen.dart';
import 'settings_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  StreamSubscription<IncomingMessage>? _msgSub;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    ChatStorageService.instance.loadContacts();
    _msgSub = incomingMessageController.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _msgSub?.cancel();
    super.dispose();
  }

  Future<void> _rescan() async {
    await BleService.instance.rescan();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Поиск устройств...'), duration: Duration(seconds: 2)),
    );
    _tabs.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rlink',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22)),
        leading: GestureDetector(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const ProfileScreen())),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: profile != null
                ? AvatarWidget(
                    initials: profile.initials,
                    color: profile.avatarColor,
                    emoji: profile.avatarEmoji,
                    size: 36,
                  )
                : const Icon(Icons.account_circle),
          ),
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: BleService.instance.peersCount,
            builder: (_, count, __) => IconButton(
              icon: count > 0
                  ? Badge(
                      label: Text('$count'),
                      child: const Icon(Icons.bluetooth_searching))
                  : const Icon(Icons.bluetooth_searching),
              tooltip: 'Найти устройства',
              onPressed: _rescan,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Настройки',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsScreen()),
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Чаты'),
            Tab(text: 'Контакты'),
            Tab(text: 'Рядом')
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_ChatsTab(), const ContactsScreen(), _NearbyTab()],
      ),
    );
  }
}

// ── Чаты ────────────────────────────────────────────────────────

class _ChatsTab extends StatefulWidget {
  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> {
  List<_ChatItem> _items = [];
  StreamSubscription<IncomingMessage>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = incomingMessageController.stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final storage = ChatStorageService.instance;
    final peerIds = await storage.getChatPeerIds();
    final items = <_ChatItem>[];
    for (final peerId in peerIds) {
      final last = await storage.getLastMessage(peerId);
      if (last == null) continue;
      final contact = await storage.getContact(peerId);
      items.add(_ChatItem(
        peerId: peerId,
        nickname: contact?.nickname ?? '${peerId.substring(0, 8)}...',
        avatarColor: contact?.avatarColor ?? 0xFF607D8B,
        avatarEmoji: contact?.avatarEmoji ?? '',
        lastMessage: last.text,
        lastTime: last.timestamp,
        isOnline: BleService.instance.isPeerConnected(peerId),
      ));
    }
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline,
              size: 64, color: Colors.grey.shade700),
          const SizedBox(height: 16),
          Text('Нет чатов',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
          const SizedBox(height: 8),
          Text('Найди устройства на вкладке "Рядом"',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
        ]),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, indent: 72, color: Colors.grey.shade800),
      itemBuilder: (_, i) {
        final item = _items[i];
        return ListTile(
          leading: AvatarWidget(
            initials: item.nickname[0].toUpperCase(),
            color: item.avatarColor,
            emoji: item.avatarEmoji,
            size: 48,
            isOnline: item.isOnline,
          ),
          title: Text(item.nickname,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          subtitle: Text(item.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
          trailing: Text(_fmtTime(item.lastTime),
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerId: item.peerId,
                peerNickname: item.nickname,
                peerAvatarColor: item.avatarColor,
                peerAvatarEmoji: item.avatarEmoji,
              ),
            ),
          ),
        );
      },
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

class _ChatItem {
  final String peerId, nickname, lastMessage, avatarEmoji;
  final int avatarColor;
  final DateTime lastTime;
  final bool isOnline;
  const _ChatItem({
    required this.peerId,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    required this.lastMessage,
    required this.lastTime,
    required this.isOnline,
  });
}

// ── Рядом ────────────────────────────────────────────────────────

class _NearbyTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: BleService.instance.peersCount,
      builder: (_, count, __) {
        return ValueListenableBuilder<Set<String>>(
          valueListenable: BleService.instance.pendingProfiles,
          builder: (_, pending, __) {
            final peers = BleService.instance.connectedPeerIds;
            if (peers.isEmpty && pending.isEmpty) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.bluetooth_searching,
                      size: 72, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  Text('Ищем устройства...',
                      style:
                          TextStyle(color: Colors.grey.shade400, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Убедись что Bluetooth включён\nна обоих устройствах',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                ]),
              );
            }
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // Устройства которые загружают профиль
                ...pending.map((bleId) => _PendingDeviceTile(bleId: bleId)),
                // Устройства с полученным профилем
                ...peers
                    .where((id) => !pending.contains(id))
                    .map((id) => _NearbyDeviceTile(publicKeyOrBleId: id)),
              ],
            );
          },
        );
      },
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
    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          shape: BoxShape.circle,
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFF1DB954)),
          ),
        ),
      ),
      title: Text(displayName,
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text('Загрузка профиля...',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
      trailing: const SizedBox(width: 48),
    );
  }
}

class _NearbyDeviceTile extends StatelessWidget {
  final String publicKeyOrBleId;
  const _NearbyDeviceTile({required this.publicKeyOrBleId});

  Future<Contact?> _resolveContact() async {
    // Try by public key first (if we have the mapping)
    final publicKey = BleService.instance.resolvePublicKey(publicKeyOrBleId);
    if (publicKey != publicKeyOrBleId) {
      final c = await ChatStorageService.instance.getContact(publicKey);
      if (c != null) return c;
    }
    return ChatStorageService.instance.getContact(publicKeyOrBleId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Contact?>(
      future: _resolveContact(),
      builder: (_, snap) {
        final contact = snap.data;
        // Priority: registered nickname > BT device name > short ID
        final btName = BleService.instance.getDeviceName(publicKeyOrBleId);
        final nickname = contact?.nickname ?? btName;
        final color = contact?.avatarColor ?? 0xFF607D8B;
        final emoji = contact?.avatarEmoji ?? '';

        return ListTile(
          leading: AvatarWidget(
            initials: nickname[0].toUpperCase(),
            color: color,
            emoji: emoji,
            size: 48,
            isOnline: true,
          ),
          title: Text(nickname,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerId: publicKeyOrBleId,
                peerNickname: nickname,
                peerAvatarColor: color,
                peerAvatarEmoji: emoji,
              ),
            ),
          ),
          subtitle: Text(
            contact != null
                ? 'Rlink' // контакт найден — показываем что это Rlink пользователь
                : btName != publicKeyOrBleId
                    ? btName // BT имя устройства
                    : '${publicKeyOrBleId.substring(0, publicKeyOrBleId.length.clamp(0, 12))}...',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: contact == null ? 'Добавить' : 'Изменить',
              onPressed: () =>
                  _addContact(context, publicKeyOrBleId, existing: contact),
            ),
            IconButton(
              icon: const Icon(Icons.chat),
              tooltip: 'Написать',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    peerId: publicKeyOrBleId,
                    peerNickname: nickname,
                    peerAvatarColor: color,
                    peerAvatarEmoji: emoji,
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  void _addContact(BuildContext context, String peerId, {Contact? existing}) {
    final ctrl = TextEditingController(text: existing?.nickname ?? '');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(existing == null ? 'Добавить контакт' : 'Изменить имя'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Имя'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final contact = Contact(
                publicKeyHex: peerId,
                nickname: name,
                avatarColor: 0xFF5C6BC0,
                avatarEmoji: '',
                addedAt: DateTime.now(),
              );
              await ChatStorageService.instance.saveContact(contact);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$name добавлен')),
                );
              }
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
  }
}
