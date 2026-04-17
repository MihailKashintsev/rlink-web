import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../models/group.dart';
import '../../services/crypto_service.dart';
import '../widgets/animated_transitions.dart';
import '../../services/gossip_router.dart';
import '../../services/group_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  List<Group> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
    GroupService.instance.version.addListener(_load);
  }

  @override
  void dispose() {
    GroupService.instance.version.removeListener(_load);
    super.dispose();
  }

  void _load() async {
    final groups = await GroupService.instance.getGroups();
    if (mounted) setState(() => _groups = groups);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: ValueListenableBuilder<List<GroupInvite>>(
        valueListenable: GroupService.instance.pendingInvites,
        builder: (_, invites, __) {
          final hasInvites = invites.isNotEmpty;
          final hasGroups = _groups.isNotEmpty;

          if (!hasInvites && !hasGroups) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.group_outlined,
                    size: 64, color: cs.primary.withValues(alpha: 0.3)),
                const SizedBox(height: 16),
                Text('Нет групп',
                    style: TextStyle(
                        fontSize: 18,
                        color: cs.onSurface.withValues(alpha: 0.5))),
                const SizedBox(height: 8),
                Text('Создайте группу или примите приглашение',
                    style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.3))),
              ]),
            );
          }

          return ListView(
            padding: const EdgeInsets.only(top: 8),
            children: [
              // Pending group invites
              if (hasInvites) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Row(children: [
                    Icon(Icons.mail_outline, size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Text('Приглашения',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: cs.primary)),
                  ]),
                ),
                ...invites.map((inv) => _GroupInviteCard(invite: inv)),
                const SizedBox(height: 8),
              ],
              // Existing groups
              for (var i = 0; i < _groups.length; i++)
                StaggeredListItem(
                  index: i,
                  child: _GroupTile(group: _groups[i], onTap: () => _openGroup(_groups[i])),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createGroup,
        child: const Icon(Icons.group_add),
      ),
    );
  }

  void _openGroup(Group group) {
    Navigator.push(
      context,
      SmoothPageRoute(
        page: GroupChatScreen(group: group),
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
          maxLength: 30,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Название группы',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              final myId = CryptoService.instance.publicKeyHex;
              final group = await GroupService.instance.createGroup(
                name: name,
                creatorId: myId,
                memberIds: [myId],
              );
              if (mounted) _openGroup(group);
            },
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  final Group group;
  final VoidCallback onTap;
  const _GroupTile({required this.group, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: AvatarWidget(
        initials: group.name.isNotEmpty ? group.name[0].toUpperCase() : '?',
        color: group.avatarColor,
        emoji: group.avatarEmoji,
        imagePath: group.avatarImagePath,
        size: 48,
      ),
      title: Text(group.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${group.memberIds.length} участников',
          style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.5))),
      onTap: onTap,
    );
  }
}

// ── Group chat screen ────────────────────────────────────────────

class GroupChatScreen extends StatefulWidget {
  final Group group;
  const GroupChatScreen({super.key, required this.group});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  List<GroupMessage> _messages = [];
  bool _isSending = false;
  double _sendProgress = 0.0;
  bool _showAttachments = false;
  late Group _group;

  String get _myId => CryptoService.instance.publicKeyHex;
  bool get _isCreator => _group.creatorId == _myId;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _load();
    GroupService.instance.version.addListener(_load);
  }

  @override
  void dispose() {
    GroupService.instance.version.removeListener(_load);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _load() async {
    final msgs = await GroupService.instance.getMessages(_group.id);
    final grp = await GroupService.instance.getGroup(_group.id);
    if (mounted) {
      setState(() {
        _messages = msgs;
        if (grp != null) { _group = grp; }
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _controller.clear();

    try {
      final myId = CryptoService.instance.publicKeyHex;
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;

      // Save locally
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: text,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);

      // Broadcast via gossip
      await GossipRouter.instance.sendGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: text,
        messageId: msgId,
      );

      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendImage() async {
    if (_isSending) return;
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    setState(() { _isSending = true; _sendProgress = 0.0; });
    try {
      final myId = CryptoService.instance.publicKeyHex;
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;

      // Compress image
      final path = await ImageService.instance.compressAndSave(picked.path);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);

      // Send via gossip (broadcast, no specific recipient)
      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myId,
        );
        if (mounted) setState(() => _sendProgress = (i + 1) / chunks.length);
      }

      // Save locally
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: '📷',
        imagePath: path,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);

      // Broadcast the group message with image ref
      await GossipRouter.instance.sendGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: '📷',
        messageId: msgId,
      );

      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; _sendProgress = 0.0; });
    }
  }

  void _inviteMember() async {
    final contacts = ChatStorageService.instance.contactsNotifier.value;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет контактов для приглашения')),
      );
      return;
    }

    final myProfile = ProfileService.instance.profile;
    final group = _group;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Пригласить в группу',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ...contacts
                .where((c) => !group.memberIds.contains(c.publicKeyHex))
                .map((c) => ListTile(
                      leading: AvatarWidget(
                        initials: c.initials,
                        color: c.avatarColor,
                        emoji: c.avatarEmoji,
                        imagePath: c.avatarImagePath,
                        size: 40,
                      ),
                      title: Text(c.nickname),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await GossipRouter.instance.sendGroupInvite(
                          groupId: group.id,
                          groupName: group.name,
                          inviterId: CryptoService.instance.publicKeyHex,
                          inviterNick: myProfile?.nickname ?? '',
                          creatorId: group.creatorId,
                          memberIds: group.memberIds,
                          targetPublicKey: c.publicKeyHex,
                          avatarColor: group.avatarColor,
                          avatarEmoji: group.avatarEmoji,
                          createdAt: group.createdAt,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Приглашение отправлено ${c.nickname}')),
                          );
                        }
                      },
                    )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ── Leave group ─────────────────────────────────────────────

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Покинуть группу?'),
        content: const Text('Вы больше не будете получать сообщения из этой группы.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Покинуть'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await GroupService.instance.leaveGroup(_group.id);
    if (mounted) Navigator.pop(context);
  }

  // ── Edit group profile ──────────────────────────────────────

  void _editGroup() {
    final nameCtrl = TextEditingController(text: _group.name);
    final emojiCtrl = TextEditingController(text: _group.avatarEmoji);
    String? pickedImagePath = _group.avatarImagePath;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Редактировать группу'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Avatar image picker
              GestureDetector(
                onTap: () async {
                  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                  if (picked == null) return;
                  final saved = await ImageService.instance.compressAndSave(
                    picked.path, isAvatar: true,
                  );
                  setDialogState(() => pickedImagePath = saved);
                },
                child: CircleAvatar(
                  radius: 36,
                  backgroundImage: pickedImagePath != null && File(pickedImagePath!).existsSync()
                      ? FileImage(File(pickedImagePath!)) : null,
                  child: pickedImagePath == null || !File(pickedImagePath!).existsSync()
                      ? const Icon(Icons.add_a_photo, size: 28)
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                maxLength: 30,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Название группы',
                  labelText: 'Название',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emojiCtrl,
                maxLength: 2,
                decoration: const InputDecoration(
                  hintText: '👥',
                  labelText: 'Эмодзи-аватар',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);
                final updated = _group.copyWith(
                  name: name,
                  avatarEmoji: emojiCtrl.text.trim().isEmpty ? _group.avatarEmoji : emojiCtrl.text.trim(),
                  avatarImagePath: pickedImagePath,
                );
                await GroupService.instance.updateGroup(updated);
                if (mounted) setState(() => _group = updated);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Manage members (kick) ───────────────────────────────────

  void _manageMembers() {
    final contacts = ChatStorageService.instance.contactsNotifier.value;

    String nickFor(String id) {
      return contacts
              .where((c) => c.publicKeyHex == id)
              .firstOrNull
              ?.nickname ??
          '${id.substring(0, 8)}…';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setModal) {
          final currentMembers = _group.memberIds
              .where((id) => id != _group.creatorId && id != _myId)
              .toList();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Участники группы',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (currentMembers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет участников', style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx2).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: currentMembers.length,
                      itemBuilder: (_, i) {
                        final uid = currentMembers[i];
                        final isMod = _group.moderatorIds.contains(uid);
                        return ListTile(
                          title: Text(nickFor(uid)),
                          subtitle: Text(
                            isMod ? 'Модератор · ${uid.substring(0, 12)}…' : '${uid.substring(0, 12)}…',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_remove_outlined, color: Colors.red),
                            tooltip: 'Исключить',
                            onPressed: () async {
                              await GroupService.instance.removeMember(_group.id, uid);
                              final grp = await GroupService.instance.getGroup(_group.id);
                              if (grp != null && mounted) {
                                setState(() => _group = grp);
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

  // ── Moderator management ────────────────────────────────────

  void _manageModerators() {
    final members = _group.memberIds
        .where((id) => id != _group.creatorId)
        .toList();
    final contacts = ChatStorageService.instance.contactsNotifier.value;

    String nickFor(String id) {
      if (id == _myId) return 'Вы';
      return contacts
              .where((c) => c.publicKeyHex == id)
              .firstOrNull
              ?.nickname ??
          '${id.substring(0, 8)}…';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setModal) {
          final mods = _group.moderatorIds;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Модераторы группы',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (members.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет участников для назначения',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.of(ctx2).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: members.length,
                      itemBuilder: (_, i) {
                        final uid = members[i];
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
                            final updated =
                                await GroupService.instance.setModerator(
                                    _group.id, uid, val);
                            if (updated != null && mounted) {
                              setState(() => _group = updated);
                              setModal(() {});
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

  String _nickFor(String id) {
    if (id == CryptoService.instance.publicKeyHex) return 'Вы';
    final contact = ChatStorageService.instance.contactsNotifier.value
        .where((c) => c.publicKeyHex == id)
        .firstOrNull;
    return contact?.nickname ?? '${id.substring(0, 8)}...';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_group.name, style: const TextStyle(fontSize: 16)),
            Text('${_group.memberIds.length} участников',
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.5))),
          ],
        ),
        actions: [
          if (_isCreator || _group.canModerate(_myId))
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              onPressed: _inviteMember,
              tooltip: 'Пригласить',
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _editGroup();
              if (v == 'mods') _manageModerators();
              if (v == 'members') _manageMembers();
              if (v == 'leave') _leaveGroup();
            },
            itemBuilder: (_) => [
              if (_isCreator || _group.canModerate(_myId))
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Редактировать'),
                  ]),
                ),
              if (_isCreator)
                const PopupMenuItem(
                  value: 'mods',
                  child: Row(children: [
                    Icon(Icons.manage_accounts_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Модераторы'),
                  ]),
                ),
              if (_isCreator || _group.canModerate(_myId))
                const PopupMenuItem(
                  value: 'members',
                  child: Row(children: [
                    Icon(Icons.people_outline, size: 18),
                    SizedBox(width: 8),
                    Text('Участники'),
                  ]),
                ),
              const PopupMenuItem(
                value: 'leave',
                child: Row(children: [
                  Icon(Icons.exit_to_app, size: 18, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Покинуть', style: TextStyle(color: Colors.red)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text('Нет сообщений',
                        style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.3))))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final msg = _messages[i];
                      return _GroupBubble(
                        msg: msg,
                        senderNick: _nickFor(msg.senderId),
                        cs: cs,
                        groupId: widget.group.id,
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isSending && _sendProgress > 0)
                  LinearProgressIndicator(value: _sendProgress),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    // + button to toggle media icons
                    IconButton(
                      icon: AnimatedRotation(
                        turns: _showAttachments ? 0.125 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.add),
                      ),
                      onPressed: () => setState(() => _showAttachments = !_showAttachments),
                      color: _showAttachments
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      tooltip: 'Прикрепить',
                    ),
                    if (_showAttachments)
                      IconButton(
                        icon: const Icon(Icons.photo_outlined),
                        onPressed: _isSending ? null : _sendImage,
                        tooltip: 'Фото',
                      ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: const InputDecoration(
                          hintText: 'Сообщение...',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        onChanged: (text) {
                          if (text.isNotEmpty && _showAttachments) {
                            setState(() => _showAttachments = false);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _isSending ? null : _send,
                      child: _isSending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupBubble extends StatelessWidget {
  final GroupMessage msg;
  final String senderNick;
  final ColorScheme cs;
  final String groupId;
  const _GroupBubble(
      {required this.msg,
      required this.senderNick,
      required this.cs,
      required this.groupId});

  Future<void> _toggle(BuildContext context, String emoji) async {
    final myId = CryptoService.instance.publicKeyHex;
    await GroupService.instance.toggleMessageReaction(msg.id, emoji, myId);
    await GossipRouter.instance.sendReactionExt(
      kind: 'group_message',
      targetId: msg.id,
      emoji: emoji,
      fromId: myId,
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final emoji = await showReactionPickerSheet(context);
    if (emoji == null) return;
    if (!context.mounted) return;
    await _toggle(context, emoji);
  }

  @override
  Widget build(BuildContext context) {
    final myId = CryptoService.instance.publicKeyHex;
    return Align(
      alignment: msg.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _openPicker(context),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: msg.isOutgoing ? cs.primary : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18).copyWith(
              bottomRight: msg.isOutgoing ? const Radius.circular(4) : null,
              bottomLeft: msg.isOutgoing ? null : const Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!msg.isOutgoing)
                Text(senderNick,
                    style: TextStyle(
                        fontSize: 11,
                        color: cs.primary,
                        fontWeight: FontWeight.bold)),
              if (msg.imagePath != null && msg.imagePath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      File(msg.imagePath!),
                      width: 200,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              SelectableText(
                msg.text,
                style: TextStyle(
                  color: msg.isOutgoing ? cs.onPrimary : cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _fmt(DateTime.fromMillisecondsSinceEpoch(msg.timestamp)),
                style: TextStyle(
                  fontSize: 10,
                  color: (msg.isOutgoing ? cs.onPrimary : cs.onSurface)
                      .withValues(alpha: 0.5),
                ),
              ),
              if (msg.reactions.isNotEmpty) ...[
                const SizedBox(height: 4),
                ReactionsBar(
                  reactions: msg.reactions,
                  myId: myId,
                  onTap: (e) => _toggle(context, e),
                  compact: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

// ── Group invite card ────────────────────────────────────────────

class _GroupInviteCard extends StatelessWidget {
  final GroupInvite invite;
  const _GroupInviteCard({required this.invite});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        elevation: 2,
        color: cs.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            AvatarWidget(
              initials: invite.groupName.isNotEmpty
                  ? invite.groupName[0].toUpperCase()
                  : '?',
              color: invite.avatarColor,
              emoji: invite.avatarEmoji,
              size: 44,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(invite.groupName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: cs.onPrimaryContainer,
                      )),
                  Text('${invite.inviterNick} приглашает вас',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                      )),
                  Text('${invite.memberIds.length} участников',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onPrimaryContainer.withValues(alpha: 0.5),
                      )),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                GroupService.instance.removeInvite(invite.groupId);
              },
              child: Text('Нет',
                  style: TextStyle(color: cs.onPrimaryContainer.withValues(alpha: 0.6))),
            ),
            FilledButton(
              onPressed: () async {
                final myId = CryptoService.instance.publicKeyHex;
                final myProfile = ProfileService.instance.profile;
                final group = Group(
                  id: invite.groupId,
                  name: invite.groupName,
                  creatorId: invite.creatorId,
                  memberIds: [...invite.memberIds, myId],
                  avatarColor: invite.avatarColor,
                  avatarEmoji: invite.avatarEmoji,
                  createdAt: invite.createdAt,
                );
                await GroupService.instance.saveGroupFromInvite(group);
                GroupService.instance.removeInvite(invite.groupId);
                await GossipRouter.instance.sendGroupAccept(
                  groupId: invite.groupId,
                  accepterId: myId,
                  accepterNick: myProfile?.nickname ?? '',
                );
              },
              child: const Text('Принять'),
            ),
          ]),
        ),
      ),
    );
  }
}
