import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../widgets/avatar_widget.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  final String searchQuery;
  const ContactsScreen({super.key, this.searchQuery = ''});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  Timer? _debounce;
  String _lastQuery = '';
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    // Re-trigger search when relay connects (user may have typed while offline)
    RelayService.instance.state.addListener(_onRelayStateChanged);
  }

  @override
  void didUpdateWidget(ContactsScreen old) {
    super.didUpdateWidget(old);
    if (widget.searchQuery != old.searchQuery) {
      _onQueryChanged(widget.searchQuery);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    RelayService.instance.state.removeListener(_onRelayStateChanged);
    RelayService.instance.searchResults.value = [];
    super.dispose();
  }

  void _onRelayStateChanged() {
    // When relay connects, retry the last pending query
    if (RelayService.instance.isConnected) {
      final q = widget.searchQuery.trim();
      if (q.length >= 2) {
        _lastQuery = ''; // allow retry
        _onQueryChanged(widget.searchQuery);
      }
    }
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    final q = query.trim();
    if (q.isEmpty || q.length < 2) {
      RelayService.instance.searchResults.value = [];
      _lastQuery = '';
      _isSearching = false;
      if (mounted) setState(() {});
      return;
    }
    if (q == _lastQuery) return;
    _isSearching = true;
    if (mounted) setState(() {});
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (RelayService.instance.isConnected) {
        RelayService.instance.searchUsers(q);
        _lastQuery = q;
        // Clear searching state after a short timeout
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _isSearching = false);
        });
      } else {
        if (mounted) setState(() => _isSearching = false);
      }
    });
  }

  void _openChat(BuildContext context, String publicKey, String nick,
      int color, String emoji, String? avatarPath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerId: publicKey,
          peerNickname: nick,
          peerAvatarColor: color,
          peerAvatarEmoji: emoji,
          peerAvatarImagePath: avatarPath,
        ),
      ),
    );
  }

  void _openDirectByKey(BuildContext context) {
    final key = widget.searchQuery.trim().toLowerCase();
    if (key.length < 8) return;
    // Save as contact stub
    final nick = '${key.substring(0, 8)}...';
    ChatStorageService.instance.saveContact(Contact(
      publicKeyHex: key,
      nickname: nick,
      avatarColor: 0xFF607D8B,
      avatarEmoji: '',
      addedAt: DateTime.now(),
    ));
    _openChat(context, key, nick, 0xFF607D8B, '', null);
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.searchQuery.toLowerCase().trim();

    return ValueListenableBuilder<List<Contact>>(
      valueListenable: ChatStorageService.instance.contactsNotifier,
      builder: (_, contacts, __) {
        final localVisible = q.isEmpty
            ? contacts
            : contacts.where((c) =>
                c.nickname.toLowerCase().contains(q) ||
                c.publicKeyHex.toLowerCase().startsWith(q) ||
                c.shortId.toLowerCase().contains(q)).toList();

        return ValueListenableBuilder<List<RelayPeer>>(
          valueListenable: RelayService.instance.searchResults,
          builder: (_, relayResults, __) {
            // Filter out relay results that are already in local contacts
            final localKeys = contacts.map((c) => c.publicKeyHex).toSet();
            final filteredRelay = relayResults
                .where((r) => !localKeys.contains(r.publicKey))
                .toList();

            final hasLocal = localVisible.isNotEmpty;
            final hasRelay = filteredRelay.isNotEmpty && q.isNotEmpty;
            final showDirectButton = q.length >= 8 && !hasLocal && !hasRelay;

            if (contacts.isEmpty && q.isEmpty) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.people_outline,
                      size: 64, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  Text('Нет контактов',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text(
                    'Используй поиск чтобы найти\nсобеседников в сети',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 13),
                  ),
                ]),
              );
            }

            return ListView(
              children: [
                // ── Local contacts ──
                if (hasLocal) ...[
                  if (q.isNotEmpty)
                    _SectionHeader(
                      title: 'Мои контакты',
                      count: localVisible.length,
                    ),
                  for (final c in localVisible) _ContactTile(contact: c),
                ],

                // ── Relay results ──
                if (hasRelay) ...[
                  _SectionHeader(
                    title: 'Найдены в сети',
                    count: filteredRelay.length,
                    icon: Icons.wifi,
                  ),
                  for (final peer in filteredRelay)
                    _RelayPeerTile(
                      peer: peer,
                      onTap: () {
                        // Save as contact with nick from relay
                        final nick = peer.nick.isNotEmpty
                            ? peer.nick
                            : peer.shortId;
                        ChatStorageService.instance.saveContact(Contact(
                          publicKeyHex: peer.publicKey,
                          nickname: nick,
                          avatarColor: 0xFF607D8B,
                          avatarEmoji: '',
                          addedAt: DateTime.now(),
                        ));
                        // Send our profile via relay so the peer knows who we are
                        final myProfile = ProfileService.instance.profile;
                        if (myProfile != null) {
                          GossipRouter.instance.broadcastProfile(
                            id: myProfile.publicKeyHex,
                            nick: myProfile.nickname,
                            color: myProfile.avatarColor,
                            emoji: myProfile.avatarEmoji,
                            x25519Key: CryptoService.instance.x25519PublicKeyBase64,
                          );
                        }
                        _openChat(context, peer.publicKey, nick,
                            0xFF607D8B, '', null);
                      },
                    ),
                ],

                // ── Searching indicator ──
                if (q.isNotEmpty && _isSearching && !hasRelay) ...[
                  const SizedBox(height: 16),
                  const Center(
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text('Поиск в сети...',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                  ),
                ],

                // ── No results ──
                if (q.isNotEmpty && !hasLocal && !hasRelay && !_isSearching) ...[
                  const SizedBox(height: 48),
                  Icon(Icons.person_search_rounded,
                      color: Colors.grey.shade600, size: 40),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      RelayService.instance.isConnected
                          ? 'Никого не найдено'
                          : 'Relay не подключён — поиск в сети недоступен',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 13),
                    ),
                  ),
                ],

                // ── Direct key button ──
                if (showDirectButton && q.length >= 16) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () => _openDirectByKey(context),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Открыть чат по ключу'),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 80),
              ],
            );
          },
        );
      },
    );
  }
}

// ── Section Header ──────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final IconData? icon;
  const _SectionHeader({required this.title, required this.count, this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.grey.shade500),
            const SizedBox(width: 6),
          ],
          Text(
            '$title ($count)',
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Relay Peer Tile ─────────────────────────────────────────────

class _RelayPeerTile extends StatelessWidget {
  final RelayPeer peer;
  final VoidCallback onTap;
  const _RelayPeerTile({required this.peer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: cs.primary.withValues(alpha: 0.15),
        child: Text(
          peer.nick.isNotEmpty ? peer.nick[0].toUpperCase() : '#',
          style: TextStyle(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        peer.nick.isNotEmpty ? peer.nick : peer.shortId,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        peer.shortId,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Color(0xFF4CAF50),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text('в сети',
            style:
                TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
      onTap: onTap,
    );
  }
}

// ── Contact Tile ────────────────────────────────────────────────

class _ContactTile extends StatelessWidget {
  final Contact contact;
  const _ContactTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: AvatarWidget(
        initials: contact.nickname.isNotEmpty
            ? contact.nickname[0].toUpperCase()
            : '?',
        color: contact.avatarColor,
        emoji: contact.avatarEmoji,
        imagePath: contact.avatarImagePath,
        size: 48,
      ),
      title: Text(contact.nickname,
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        '${contact.publicKeyHex.substring(0, contact.publicKeyHex.length.clamp(0, 16))}...',
        style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.chat_outlined),
          tooltip: 'Написать',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerId: contact.publicKeyHex,
                peerNickname: contact.nickname,
                peerAvatarColor: contact.avatarColor,
                peerAvatarEmoji: contact.avatarEmoji,
                peerAvatarImagePath: contact.avatarImagePath,
              ),
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
          tooltip: 'Удалить',
          onPressed: () => _confirmDelete(context),
        ),
      ]),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            peerId: contact.publicKeyHex,
            peerNickname: contact.nickname,
            peerAvatarColor: contact.avatarColor,
            peerAvatarEmoji: contact.avatarEmoji,
            peerAvatarImagePath: contact.avatarImagePath,
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить контакт?'),
        content: Text('${contact.nickname} будет удалён из контактов.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await ChatStorageService.instance
                  .deleteContact(contact.publicKeyHex);
              BleService.instance.resetPeerMapping(contact.publicKeyHex);
            },
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}
