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

  /// Query comes from parent AppBar search field
  String get _effectiveQuery => widget.searchQuery.trim();

  @override
  void initState() {
    super.initState();
    RelayService.instance.state.addListener(_onRelayStateChanged);
  }

  @override
  void didUpdateWidget(ContactsScreen old) {
    super.didUpdateWidget(old);
    if (widget.searchQuery != old.searchQuery) {
      _triggerSearch(_effectiveQuery);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    RelayService.instance.state.removeListener(_onRelayStateChanged);
    RelayService.instance.searchResults.value = [];
    super.dispose();
  }

  bool _isSelfSearch(String query) {
    final myKey = CryptoService.instance.publicKeyHex;
    final myProfile = ProfileService.instance.profile;
    if (myKey.isEmpty || query.isEmpty) return false;
    final q = query.toLowerCase();
    final myShortId = myKey.length > 8 ? myKey.substring(0, 8) : myKey;
    if (myShortId.toLowerCase().contains(q)) return true;
    if (myProfile != null && myProfile.username.isNotEmpty &&
        myProfile.username.toLowerCase().contains(q)) { return true; }
    return false;
  }

  void _onRelayStateChanged() {
    if (RelayService.instance.isConnected) {
      final q = _effectiveQuery;
      if (q.length >= 2) {
        _lastQuery = ''; // allow retry
        _triggerSearch(q);
      }
    }
    if (mounted) setState(() {}); // update relay status indicator
  }

  /// Strip search prefix (#username / &fullkey) and return the raw query for relay
  String _stripSearchPrefix(String query) {
    final q = query.trim();
    if (q.startsWith('#') || q.startsWith('&')) return q.substring(1);
    return q;
  }

  void _triggerSearch(String query) {
    _debounce?.cancel();
    final raw = _stripSearchPrefix(query.trim());
    if (raw.isEmpty || raw.length < 2) {
      RelayService.instance.searchResults.value = [];
      _lastQuery = '';
      _isSearching = false;
      return;
    }
    if (raw == _lastQuery) return;
    _isSearching = true;
    if (mounted) setState(() {});
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (RelayService.instance.isConnected) {
        debugPrint('[RLINK][Contacts] Sending search: "$raw"');
        RelayService.instance.searchUsers(raw);
        _lastQuery = raw;
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isSearching = false);
        });
      } else {
        debugPrint('[RLINK][Contacts] Relay not connected, skipping search');
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

  void _onTapRelayPeer(RelayPeer peer) {
    final nick = peer.nick.isNotEmpty ? peer.nick : peer.shortId;
    // Open the chat for previewing messages, but do NOT auto-create a contact.
    // Instead, send a pair_req so the contact is only added after mutual acceptance.
    final myProfile = ProfileService.instance.profile;
    if (myProfile != null) {
      GossipRouter.instance.sendPairRequest(
        publicKey: myProfile.publicKeyHex,
        nick: myProfile.nickname,
        username: myProfile.username,
        color: myProfile.avatarColor,
        emoji: myProfile.avatarEmoji,
        recipientId: peer.publicKey,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: myProfile.tags,
      );
    }
    _openChat(context, peer.publicKey, nick, 0xFF607D8B, '', null);
  }

  void _openDirectByKey(BuildContext context) {
    final key = _effectiveQuery.toLowerCase();
    if (key.length < 8) return;
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
    final rawQuery = _effectiveQuery;
    final isUsernameSearch = rawQuery.startsWith('#');
    final isFullKeySearch = rawQuery.startsWith('&');
    final q = _stripSearchPrefix(rawQuery).toLowerCase();
    final relayConnected = RelayService.instance.isConnected;

    return Column(children: [
      // Search is handled by the parent AppBar — no local field needed.

      // ── Relay status ──
      if (!relayConnected)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: Colors.orange.shade100,
          child: Row(children: [
            Icon(Icons.wifi_off, size: 14, color: Colors.orange.shade800),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Relay не подключён — поиск людей недоступен',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
            ),
            SizedBox(
              height: 24,
              child: TextButton(
                onPressed: () => RelayService.instance.reconnect(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                ),
                child: Text('Подключить',
                    style: TextStyle(fontSize: 11, color: Colors.orange.shade900)),
              ),
            ),
          ]),
        ),

      // ── Content ──
      Expanded(
        child: ValueListenableBuilder<List<Contact>>(
          valueListenable: ChatStorageService.instance.contactsNotifier,
          builder: (_, contacts, __) {
            final List<Contact> localVisible;
            if (q.isEmpty) {
              localVisible = contacts;
            } else if (isUsernameSearch) {
              // #username — поиск только по юзернейму
              localVisible = contacts.where((c) =>
                  c.username.toLowerCase().contains(q)).toList();
            } else if (isFullKeySearch) {
              // &fullkey — поиск по полному публичному ключу
              localVisible = contacts.where((c) =>
                  c.publicKeyHex.toLowerCase().contains(q)).toList();
            } else {
              // без префикса — поиск по всему
              localVisible = contacts.where((c) =>
                  c.nickname.toLowerCase().contains(q) ||
                  c.username.toLowerCase().contains(q) ||
                  c.publicKeyHex.toLowerCase().startsWith(q) ||
                  c.shortId.toLowerCase().contains(q)).toList();
            }

            return ValueListenableBuilder<List<RelayPeer>>(
              valueListenable: RelayService.instance.searchResults,
              builder: (_, relayResults, __) {
                // Show ALL relay results — don't filter out existing contacts.
                // Existing contacts appear in both sections — user expects to see search results.
                final filteredRelay = q.isEmpty ? <RelayPeer>[] : relayResults;

                final hasLocal = localVisible.isNotEmpty;
                final hasRelay = filteredRelay.isNotEmpty;
                final showDirectButton =
                    q.length >= 8 && !hasLocal && !hasRelay;

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
                        'Введи имя или ID в поле выше\nчтобы найти собеседников',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ]),
                  );
                }

                return ListView(
                  children: [
                    // ── Relay results (top priority when searching) ──
                    if (hasRelay) ...[
                      _SectionHeader(
                        title: 'Найдены в сети',
                        count: filteredRelay.length,
                        icon: Icons.wifi,
                      ),
                      for (final peer in filteredRelay)
                        Builder(builder: (_) {
                          final contact = contacts.cast<Contact?>().firstWhere(
                            (c) => c!.publicKeyHex == peer.publicKey,
                            orElse: () => null,
                          );
                          return _RelayPeerTile(
                            peer: peer,
                            onTap: () => _onTapRelayPeer(peer),
                            isContact: contact != null,
                            contactNickname: contact?.nickname,
                          );
                        }),
                    ],

                    // ── Searching indicator ──
                    if (q.isNotEmpty && _isSearching && !hasRelay) ...[
                      const SizedBox(height: 16),
                      const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text('Поиск в сети...',
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 13)),
                      ),
                    ],

                    // ── No results from relay ──
                    if (q.isNotEmpty &&
                        !hasRelay &&
                        !_isSearching &&
                        relayConnected) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.info_outline,
                                  size: 14,
                                  color: _isSelfSearch(q)
                                      ? Colors.orange.shade700
                                      : Colors.grey.shade500),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _isSelfSearch(q)
                                      ? 'Это ваш код! Введите код собеседника.'
                                      : 'Никого не найдено по "$q".',
                                  style: TextStyle(
                                    color: _isSelfSearch(q)
                                        ? Colors.orange.shade700
                                        : Colors.grey.shade500,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  _lastQuery = '';
                                  _triggerSearch(_effectiveQuery);
                                },
                                child: const Text('Повторить',
                                    style: TextStyle(fontSize: 12)),
                              ),
                            ]),
                            Builder(builder: (_) {
                              final peers =
                                  RelayService.instance.knownOnlinePeers;
                              if (peers.isEmpty) return const SizedBox.shrink();
                              final hint = peers
                                  .map((p) {
                                    if (p.username.isNotEmpty) return '#${p.username}';
                                    if (p.nick.isNotEmpty) return '${p.nick} (${p.shortId})';
                                    return p.shortId;
                                  })
                                  .join(', ');
                              return Padding(
                                padding:
                                    const EdgeInsets.only(left: 20, top: 2),
                                child: Text(
                                  'В сети: $hint',
                                  style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 11),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ],

                    // ── Local contacts ──
                    if (hasLocal) ...[
                      _SectionHeader(
                        title: q.isEmpty ? 'Контакты' : 'Мои контакты',
                        count: localVisible.length,
                      ),
                      for (final c in localVisible) _ContactTile(contact: c),
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
        ),
      ),
    ]);
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
  final bool isContact;
  final String? contactNickname;
  const _RelayPeerTile({
    required this.peer,
    required this.onTap,
    this.isContact = false,
    this.contactNickname,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Верхняя строка: юзернейм (или ник), если контакт — имя контакта
    final displayName = isContact && contactNickname != null
        ? contactNickname!
        : peer.username.isNotEmpty
            ? '#${peer.username}'
            : (peer.nick.isNotEmpty ? peer.nick : peer.shortId);
    // Нижняя строка: если контакт — юзернейм, иначе — полный ключ мелко
    final subtitle = isContact
        ? (peer.username.isNotEmpty ? '#${peer.username}' : peer.publicKey.substring(0, 16))
        : peer.publicKey.substring(0, peer.publicKey.length.clamp(0, 16));
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
        displayName,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: Colors.grey.shade500,
        ),
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
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
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
    final subtitle = contact.username.isNotEmpty
        ? '#${contact.username}'
        : '${contact.publicKeyHex.substring(0, contact.publicKeyHex.length.clamp(0, 16))}...';
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
        subtitle,
        style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 20),
          tooltip: 'Редактировать',
          onPressed: () => _editContact(context),
        ),
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
          icon: Icon(Icons.delete_outline, color: Colors.red.shade400, size: 20),
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

  void _editContact(BuildContext context) {
    final nickCtrl = TextEditingController(text: contact.nickname);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Редактировать контакт'),
        content: TextField(
          controller: nickCtrl,
          decoration: const InputDecoration(labelText: 'Имя'),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final newNick = nickCtrl.text.trim();
              if (newNick.isNotEmpty && newNick != contact.nickname) {
                await ChatStorageService.instance.saveContact(
                  contact.copyWith(nickname: newNick),
                );
              }
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
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
