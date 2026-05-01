import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../models/group.dart';
import '../../models/chat_message.dart';
import '../../models/contact.dart';
import '../../models/shared_collab.dart';
import '../../models/message_poll.dart';
import '../../services/app_settings.dart';
import '../../services/crypto_service.dart';
import '../widgets/animated_transitions.dart';
import '../../services/broadcast_outbox_service.dart';
import '../../services/gossip_router.dart';
import '../../services/group_service.dart';
import '../../services/notification_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/embedded_video_pause_bus.dart';
import '../../services/voice_service.dart';
import '../../services/image_service.dart';
import '../../services/sticker_collection_service.dart';
import '../../services/invite_dm_service.dart';
import '../../services/outbound_dm_text.dart';
import '../../services/profile_service.dart';
import 'location_map_screen.dart';
import '../../utils/external_message_share.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/poll_message_card.dart';
import '../widgets/shared_todo_message_card.dart';
import '../widgets/shared_calendar_message_card.dart';
import '../widgets/missing_local_media.dart';
import '../../utils/channel_mentions.dart';
import 'collab_compose_dialogs.dart';
import 'chat_screen.dart';
import '../mention_nav.dart';
import 'image_editor_screen.dart';
import '../widgets/forward_target_sheet.dart';
import '../widgets/media_gallery_send_sheet.dart';
import '../widgets/chat_emoji_insert_sheet.dart';
import 'square_video_recorder_screen.dart';

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
                  child: _GroupTile(
                      group: _groups[i], onTap: () => _openGroup(_groups[i])),
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
      title:
          Text(group.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${group.memberIds.length} участников',
          style: TextStyle(
              fontSize: 13, color: cs.onSurface.withValues(alpha: 0.5))),
      onTap: onTap,
    );
  }
}

// ── Group chat screen ────────────────────────────────────────────

class _GroupFmtBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool underline;

  const _GroupFmtBtn({
    required this.label,
    required this.onTap,
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.underline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                decoration: underline
                    ? TextDecoration.underline
                    : strikethrough
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
  late Group _group;
  final _focusNode = FocusNode();
  bool _showScrollToBottomFab = false;
  double? _pendingLat;
  double? _pendingLng;
  bool _showFormatStrip = false;

  String get _myId => CryptoService.instance.publicKeyHex;
  bool get _composeHasText => _controller.text.trim().isNotEmpty;
  bool get _isCreator => _group.creatorId == _myId;

  void _onAppSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    AppSettings.instance.addListener(_onAppSettingsChanged);
    unawaited(_loadAndMarkRead());
    GroupService.instance.version.addListener(_load);
    _scrollController.addListener(_onScrollFab);
    _requestHistoryDelta();
    NotificationService.instance.currentRoute.value = 'group:${_group.id}';
    _controller.addListener(_onComposeChanged);
  }

  void _onComposeChanged() {
    if (!mounted) return;
    final sel = _controller.selection;
    setState(() {
      if (!sel.isValid || sel.isCollapsed) {
        _showFormatStrip = false;
      }
    });
  }

  Future<void> _requestHistoryDelta() async {
    if (_myId.isEmpty) return;
    final last = await GroupService.instance.getLastMessage(_group.id);
    unawaited(GossipRouter.instance.sendGroupHistoryRequest(
      groupId: _group.id,
      requesterId: _myId,
      sinceTs: last?.timestamp ?? 0,
    ));
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    unawaited(GroupService.instance.markGroupRead(_group.id));
    _scrollController.removeListener(_onScrollFab);
    GroupService.instance.version.removeListener(_load);
    _controller.removeListener(_onComposeChanged);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    if (NotificationService.instance.currentRoute.value ==
        'group:${_group.id}') {
      NotificationService.instance.currentRoute.value = null;
    }
    super.dispose();
  }

  void _wrapSelection(String prefix, String suffix) {
    final sel = _controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final text = _controller.text;
    final selected = text.substring(sel.start, sel.end);
    final newText =
        text.replaceRange(sel.start, sel.end, '$prefix$selected$suffix');
    final newOffset = sel.end + prefix.length + suffix.length;
    _controller.value = _controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  void _insertIntoComposer(String insert) {
    final value = _controller.value;
    final sel = value.selection;
    final text = value.text;
    if (!sel.isValid) {
      _controller.value = value.copyWith(
        text: '$text$insert',
        selection: TextSelection.collapsed(offset: text.length + insert.length),
      );
      return;
    }
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final next = text.replaceRange(start, end, insert);
    final caret = start + insert.length;
    _controller.value = value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  Future<void> _attachLinkToSelection() async {
    final sel = _controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final fullText = _controller.text;
    final selected = fullText.substring(sel.start, sel.end);

    final urlCtrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ссылка'),
        content: TextField(
          controller: urlCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, urlCtrl.text.trim()),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
    final u = (url ?? '').trim();
    if (u.isEmpty) return;
    final wrapped = '[$selected]($u)';
    final newText = fullText.replaceRange(sel.start, sel.end, wrapped);
    final newOffset = sel.start + wrapped.length;
    _controller.value = _controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  Widget _buildContextMenu(
      BuildContext context, EditableTextState editableTextState) {
    final items = <ContextMenuButtonItem>[
      ...editableTextState.contextMenuButtonItems,
      ContextMenuButtonItem(
        label: 'Жирный',
        onPressed: () {
          editableTextState.hideToolbar();
          _wrapSelection('**', '**');
        },
      ),
      ContextMenuButtonItem(
        label: 'Курсив',
        onPressed: () {
          editableTextState.hideToolbar();
          _wrapSelection('_', '_');
        },
      ),
      ContextMenuButtonItem(
        label: 'Тонкий',
        onPressed: () {
          editableTextState.hideToolbar();
          _wrapSelection('`', '`');
        },
      ),
      ContextMenuButtonItem(
        label: 'Подчёркнутый',
        onPressed: () {
          editableTextState.hideToolbar();
          _wrapSelection('__', '__');
        },
      ),
      ContextMenuButtonItem(
        label: 'Зачёркнутый',
        onPressed: () {
          editableTextState.hideToolbar();
          _wrapSelection('~~', '~~');
        },
      ),
      ContextMenuButtonItem(
        label: 'Спойлер',
        onPressed: () {
          editableTextState.hideToolbar();
          _wrapSelection('||', '||');
        },
      ),
      ContextMenuButtonItem(
        label: 'Ссылка…',
        onPressed: () {
          editableTextState.hideToolbar();
          _attachLinkToSelection();
        },
      ),
    ];

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Future<void> _load() async {
    final msgs = await GroupService.instance.getMessages(_group.id);
    final grp = await GroupService.instance.getGroup(_group.id);
    if (mounted) {
      setState(() {
        _messages = msgs;
        if (grp != null) {
          _group = grp;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScrollFab());
    }
  }

  Future<void> _loadAndMarkRead() async {
    await _load();
    if (mounted) await GroupService.instance.markGroupRead(_group.id);
  }

  void _onScrollFab() {
    final pos =
        _scrollController.hasClients ? _scrollController.position : null;
    if (pos == null) return;
    final away = pos.maxScrollExtent - pos.pixels;
    final show = away > 120;
    if (show != _showScrollToBottomFab && mounted) {
      setState(() => _showScrollToBottomFab = show);
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
    final lat = _pendingLat;
    final lng = _pendingLng;
    setState(() {
      _pendingLat = null;
      _pendingLng = null;
    });

    try {
      final myId = CryptoService.instance.publicKeyHex;
      final parts = OutboundDmText.splitChunks(text);

      for (var i = 0; i < parts.length; i++) {
        final partText = parts[i];
        final isFirst = i == 0;
        final msgId = const Uuid().v4();
        final now = DateTime.now().millisecondsSinceEpoch;

        final msg = GroupMessage(
          id: msgId,
          groupId: widget.group.id,
          senderId: myId,
          text: partText,
          latitude: isFirst ? lat : null,
          longitude: isFirst ? lng : null,
          isOutgoing: true,
          timestamp: now,
        );
        await GroupService.instance.saveMessage(msg);

        await BroadcastOutboxService.instance.enqueueGroupMessage(
          groupId: widget.group.id,
          senderId: myId,
          text: partText,
          messageId: msgId,
          timestamp: now,
          latitude: isFirst ? lat : null,
          longitude: isFirst ? lng : null,
        );
      }

      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _composeAndSendTodo() async {
    if (_isSending) return;
    final enc = await showSharedTodoComposeDialog(context);
    if (enc == null || !mounted) return;
    await _sendStructuredGroupMessage(enc);
  }

  Future<void> _composeAndSendCalendar() async {
    if (_isSending) return;
    final enc = await showSharedCalendarComposeDialog(context);
    if (enc == null || !mounted) return;
    await _sendStructuredGroupMessage(enc);
  }

  Future<void> _sendStructuredGroupMessage(String encoded) async {
    if (_isSending) return;
    setState(() => _isSending = true);
    final lat = _pendingLat;
    final lng = _pendingLng;
    setState(() {
      _pendingLat = null;
      _pendingLng = null;
    });
    try {
      final myId = _myId;
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: encoded,
        latitude: lat,
        longitude: lng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: encoded,
        messageId: msgId,
        timestamp: now,
        latitude: lat,
        longitude: lng,
      );
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _syncGroupCollab(GroupMessage msg, String newEnc) async {
    await GroupService.instance.updateMessageText(msg.id, newEnc);
    await BroadcastOutboxService.instance.enqueueGroupMessage(
      groupId: widget.group.id,
      senderId: _myId,
      text: newEnc,
      messageId: msg.id,
      timestamp: msg.timestamp,
      latitude: msg.latitude,
      longitude: msg.longitude,
      reactionsJson: msg.reactions.isEmpty ? null : jsonEncode(msg.reactions),
      pollJson: msg.pollJson,
    );
    _load();
  }

  Future<void> _openGroupCalendar() async {
    final events = SharedCalendarPayload.collectFromGroupMessages(_messages);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('События в группе'),
        content: SizedBox(
          width: double.maxFinite,
          child: events.isEmpty
              ? const Text('Пока нет отмеченных событий.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: events.length,
                  itemBuilder: (_, i) {
                    final e = events[i];
                    final dt = DateTime.fromMillisecondsSinceEpoch(e.startMs);
                    return ListTile(
                      dense: true,
                      title: Text(e.title.isEmpty ? '(без названия)' : e.title),
                      subtitle: Text(
                        '${dt.day.toString().padLeft(2, '0')}.'
                        '${dt.month.toString().padLeft(2, '0')}.${dt.year} '
                        '${dt.hour.toString().padLeft(2, '0')}:'
                        '${dt.minute.toString().padLeft(2, '0')}',
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть')),
        ],
      ),
    );
  }

  // ignore: unused_element
  Future<void> _sendGroupSquareVideo() async {
    if (_isSending) return;
    if (!mounted) return;
    final raw = await showSquareVideoRecorder(context);
    if (raw == null || !mounted) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = _myId;
      final path = await ImageService.instance.saveVideo(raw, isSquare: true);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        isAvatar: false,
        isVideo: true,
        isSquare: true,
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

      final msg = GroupMessage(
        id: msgId,
        groupId: _group.id,
        senderId: myId,
        text: '⬛',
        videoPath: path,
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: _group.id,
        senderId: myId,
        text: '⬛',
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasVideo: true,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Квадратик: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  // ignore: unused_element
  Future<void> _sendGroupVideoFromGallery() async {
    if (_isSending) return;
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = _myId;
      final path =
          await ImageService.instance.saveVideo(picked.path, isSquare: false);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        isAvatar: false,
        isVideo: true,
        isSquare: false,
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

      final msg = GroupMessage(
        id: msgId,
        groupId: _group.id,
        senderId: myId,
        text: '📹',
        videoPath: path,
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: _group.id,
        senderId: myId,
        text: '📹',
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasVideo: true,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<MessagePoll?> _showPollEditor() async {
    final qCtrl = TextEditingController();
    final o1 = TextEditingController();
    final o2 = TextEditingController();
    final o3 = TextEditingController();
    var anon = false;
    var quiz = false;
    var multi = false;
    var randomOrder = false;
    var correctIndex = 0;

    return showDialog<MessagePoll>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return AlertDialog(
            title: const Text('Опрос'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: qCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Вопрос',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                      controller: o1,
                      decoration:
                          const InputDecoration(labelText: 'Вариант 1')),
                  TextField(
                      controller: o2,
                      decoration:
                          const InputDecoration(labelText: 'Вариант 2')),
                  TextField(
                    controller: o3,
                    decoration: const InputDecoration(
                        labelText: 'Вариант 3 (необязательно)'),
                  ),
                  SwitchListTile(
                    value: anon,
                    onChanged: (v) => setSt(() => anon = v),
                    title: const Text('Анонимный'),
                  ),
                  SwitchListTile(
                    value: multi,
                    onChanged: (v) => setSt(() => multi = v),
                    title: const Text('Несколько ответов'),
                  ),
                  SwitchListTile(
                    value: quiz,
                    onChanged: (v) => setSt(() => quiz = v),
                    title: const Text('Викторина'),
                  ),
                  if (quiz)
                    DropdownButtonFormField<int>(
                      value: correctIndex,
                      decoration: const InputDecoration(
                          labelText: 'Правильный вариант'),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('1')),
                        DropdownMenuItem(value: 1, child: Text('2')),
                        DropdownMenuItem(value: 2, child: Text('3')),
                      ],
                      onChanged: (v) => setSt(() => correctIndex = v ?? 0),
                    ),
                  SwitchListTile(
                    value: randomOrder,
                    onChanged: (v) => setSt(() => randomOrder = v),
                    title: const Text('Случайный порядок'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена')),
              FilledButton(
                onPressed: () {
                  final opts = [
                    o1.text.trim(),
                    o2.text.trim(),
                    o3.text.trim(),
                  ].where((s) => s.isNotEmpty).toList();
                  if (qCtrl.text.trim().isEmpty || opts.length < 2) return;
                  final ci =
                      quiz ? correctIndex.clamp(0, opts.length - 1) : null;
                  Navigator.pop(
                    ctx,
                    MessagePoll(
                      question: qCtrl.text.trim(),
                      options: opts,
                      anonymous: anon,
                      quiz: quiz,
                      multiSelect: multi,
                      randomOrder: randomOrder,
                      correctIndex: ci,
                    ),
                  );
                },
                child: const Text('Отправить'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _sendPoll() async {
    if (_isSending) return;
    final poll = await _showPollEditor();
    if (poll == null || !mounted) return;
    setState(() => _isSending = true);
    try {
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      final pj = poll.encode();
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: _myId,
        text: '',
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
        pollJson: pj,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: _myId,
        text: '',
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        pollJson: pj,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ignore: unused_element
  Future<void> _sendFile() async {
    if (_isSending) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final picked = result.files.first;
    final srcPath = picked.path;
    if (srcPath == null) return;
    final originalName = picked.name;

    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = CryptoService.instance.publicKeyHex;
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;

      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files');
      if (!filesDir.existsSync()) filesDir.createSync(recursive: true);
      final destPath = '${filesDir.path}/$originalName';
      await File(srcPath).copy(destPath);

      final fileBytes = await File(destPath).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(fileBytes);

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        isAvatar: false,
        isFile: true,
        fileName: originalName,
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

      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: '\u{1F4CE} $originalName',
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);

      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: msg.text,
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasFile: true,
        fileName: originalName,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка файла: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _openGroupMediaGallery() async {
    if (_isSending) return;
    if (!mounted) return;
    await showMediaGallerySendSheet(
      context,
      onPhotoPath: _groupGalleryPhoto,
      onGifPath: _groupGalleryGif,
      onVideoPath: _groupGalleryVideo,
      onStickerCropped: _groupGalleryStickerCrop,
      onStickerFromLibrary: _groupGalleryStickerLib,
      onFilePath: _groupGalleryFile,
      onLocation: _toggleLocation,
      onTodo: _composeAndSendTodo,
      onPoll: () async => _sendPoll(),
      onCalendarEvent: _composeAndSendCalendar,
    );
  }

  Future<void> _groupGalleryGif(String rawPath) async {
    if (_isSending) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = _myId;
      final path = await ImageService.instance.saveChatImageFromPicker(rawPath);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
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
      final cap = _controller.text.trim();
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: cap.isEmpty ? '🎞 GIF' : cap,
        imagePath: path,
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: msg.text,
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasImage: true,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('GIF: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _groupGalleryPhoto(String rawPath) async {
    if (_isSending) return;
    if (rawPath.toLowerCase().endsWith('.gif')) {
      await _groupGalleryGif(rawPath);
      return;
    }
    final editedBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageEditorScreen(imagePath: rawPath),
      ),
    );
    if (editedBytes == null || !mounted) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = _myId;
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
          '${tmpDir.path}/grp_gal_${DateTime.now().millisecondsSinceEpoch}.png');
      await tmpFile.writeAsBytes(editedBytes);
      final path = await ImageService.instance.compressAndSave(tmpFile.path);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
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
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: _controller.text.trim().isEmpty ? '📷' : _controller.text.trim(),
        imagePath: path,
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: msg.text,
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasImage: true,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _groupGalleryVideo(String rawPath) async {
    if (_isSending) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = _myId;
      final path =
          await ImageService.instance.saveVideo(rawPath, isSquare: false);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        isAvatar: false,
        isVideo: true,
        isSquare: false,
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
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: '📹',
        videoPath: path,
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: '📹',
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasVideo: true,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _groupPublishStickerPath(String path) async {
    final myId = _myId;
    final bytes = await File(path).readAsBytes();
    final chunks = ImageService.instance.splitToBase64Chunks(bytes);
    final msgId = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await GossipRouter.instance.sendImgMeta(
      msgId: msgId,
      totalChunks: chunks.length,
      fromId: myId,
      isSticker: true,
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
    final cap = _controller.text.trim();
    final msg = GroupMessage(
      id: msgId,
      groupId: widget.group.id,
      senderId: myId,
      text: cap.isEmpty ? ' ' : cap,
      imagePath: path,
      latitude: _pendingLat,
      longitude: _pendingLng,
      isOutgoing: true,
      timestamp: now,
    );
    await GroupService.instance.saveMessage(msg);
    await BroadcastOutboxService.instance.enqueueGroupMessage(
      groupId: widget.group.id,
      senderId: myId,
      text: msg.text,
      messageId: msgId,
      timestamp: now,
      latitude: _pendingLat,
      longitude: _pendingLng,
      hasImage: true,
    );
    _scrollToBottom();
    if (mounted) {
      setState(() {
        _pendingLat = null;
        _pendingLng = null;
      });
    }
  }

  Future<void> _groupGalleryStickerCrop(Uint8List bytes) async {
    if (_isSending) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final path = await ImageService.instance.saveStickerFromBytes(bytes);
      unawaited(
          StickerCollectionService.instance.registerAbsoluteStickerPath(path));
      await _groupPublishStickerPath(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Стикер: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _groupGalleryStickerLib(String absPath) async {
    if (_isSending) return;
    if (!File(absPath).existsSync()) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      await _groupPublishStickerPath(absPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Стикер: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _groupGalleryFile(String srcPath) async {
    if (_isSending) return;
    if (!File(srcPath).existsSync()) return;
    final originalName = p.basename(srcPath);
    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final myId = _myId;
      final msgId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files');
      if (!filesDir.existsSync()) filesDir.createSync(recursive: true);
      final destPath =
          '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_$originalName';
      await File(srcPath).copy(destPath);
      final fileBytes = await File(destPath).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(fileBytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        isAvatar: false,
        isFile: true,
        fileName: originalName,
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
      final msg = GroupMessage(
        id: msgId,
        groupId: widget.group.id,
        senderId: myId,
        text: '\u{1F4CE} $originalName',
        latitude: _pendingLat,
        longitude: _pendingLng,
        isOutgoing: true,
        timestamp: now,
      );
      await GroupService.instance.saveMessage(msg);
      await BroadcastOutboxService.instance.enqueueGroupMessage(
        groupId: widget.group.id,
        senderId: myId,
        text: msg.text,
        messageId: msgId,
        timestamp: now,
        latitude: _pendingLat,
        longitude: _pendingLng,
        hasFile: true,
        fileName: originalName,
      );
      _scrollToBottom();
      if (mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Файл: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendProgress = 0.0;
        });
      }
    }
  }

  Future<void> _toggleLocation() async {
    if (_pendingLat != null && _pendingLng != null) {
      setState(() {
        _pendingLat = null;
        _pendingLng = null;
      });
      return;
    }
    final picked = await Navigator.of(context).push<LocationPickResult>(
      MaterialPageRoute(
        builder: (_) => const LocationMapScreen(
          allowPicking: true,
          title: 'Геолокация для группы',
          confirmButtonLabel: 'Прикрепить геометку',
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _pendingLat = picked.latitude;
      _pendingLng = picked.longitude;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📍 Геометка прикреплена к следующему сообщению'),
        duration: Duration(seconds: 2),
      ),
    );
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
                        await InviteDmService.sendGroupInviteDm(
                          targetPublicKey: c.publicKeyHex,
                          payload: {
                            'groupId': group.id,
                            'groupName': group.name,
                            'inviterId': CryptoService.instance.publicKeyHex,
                            'inviterNick': myProfile?.nickname ?? '',
                            'creatorId': group.creatorId,
                            'memberIds': group.memberIds,
                            'avatarColor': group.avatarColor,
                            'avatarEmoji': group.avatarEmoji,
                            'createdAt': group.createdAt,
                          },
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
        content: const Text(
            'Вы больше не будете получать сообщения из этой группы.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
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
                  final picked = await ImagePicker()
                      .pickImage(source: ImageSource.gallery);
                  if (picked == null) return;
                  final saved = await ImageService.instance.compressAndSave(
                    picked.path,
                    isAvatar: true,
                  );
                  setDialogState(() => pickedImagePath = saved);
                },
                child: CircleAvatar(
                  radius: 36,
                  backgroundImage: pickedImagePath != null &&
                          File(pickedImagePath!).existsSync()
                      ? FileImage(File(pickedImagePath!))
                      : null,
                  child: pickedImagePath == null ||
                          !File(pickedImagePath!).existsSync()
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
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);
                final updated = _group.copyWith(
                  name: name,
                  avatarEmoji: emojiCtrl.text.trim().isEmpty
                      ? _group.avatarEmoji
                      : emojiCtrl.text.trim(),
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
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (currentMembers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет участников',
                        style: TextStyle(color: Colors.grey)),
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
                              await GroupService.instance
                                  .removeMember(_group.id, uid);
                              final grp = await GroupService.instance
                                  .getGroup(_group.id);
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
    final members =
        _group.memberIds.where((id) => id != _group.creatorId).toList();
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
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
                        maxHeight: MediaQuery.of(ctx2).size.height * 0.5),
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
                            final updated = await GroupService.instance
                                .setModerator(_group.id, uid, val);
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

  ChatMessage _syntheticChatFromGroup(GroupMessage m) {
    return ChatMessage(
      id: m.id,
      peerId: m.senderId,
      text: m.text,
      imagePath: m.imagePath,
      videoPath: m.videoPath,
      voicePath: m.voicePath,
      isOutgoing: m.senderId == _myId,
      timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
    );
  }

  Future<void> _forwardGroupMessageToDm(GroupMessage m) async {
    final origId = m.forwardFromId ?? m.senderId;
    final origNick = m.forwardFromNick ?? _nickFor(m.senderId);
    final picked = await showForwardDmTargetSheet(context);
    if (picked == null || !mounted) return;
    final c = await ChatStorageService.instance.getContact(picked.peerId);
    if (!mounted) return;
    final draft = DmForwardDraft(
      message: _syntheticChatFromGroup(m),
      sourcePeerId: m.senderId,
      originalAuthorNick: origNick,
      forwardAuthorId: origId,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerId: picked.peerId,
          peerNickname: c?.nickname ?? picked.nickname,
          peerAvatarColor: c?.avatarColor ?? picked.avatarColor,
          peerAvatarEmoji: c?.avatarEmoji ?? picked.avatarEmoji,
          peerAvatarImagePath: c?.avatarImagePath ?? picked.avatarImagePath,
          forwardDraft: draft,
        ),
      ),
    );
  }

  String _plainTextForClipboardGroup(GroupMessage m) {
    final lines = <String>[];
    final fn = m.forwardFromNick?.trim();
    if (fn != null && fn.isNotEmpty) {
      lines.add('Переслано от: $fn');
    } else if (m.forwardFromId != null &&
        m.forwardFromId!.trim().isNotEmpty) {
      lines.add('Переслано (автор: ${m.forwardFromId})');
    }
    lines.add('Автор: ${_nickFor(m.senderId)}');

    final todo = SharedTodoPayload.tryDecode(m.text);
    if (todo != null) {
      final title = todo.title.trim();
      if (title.isNotEmpty) lines.add(title);
      for (final it in todo.items) {
        lines.add('${it.done ? "✓" : "○"} ${it.text}');
      }
    } else {
      final cal = SharedCalendarPayload.tryDecode(m.text);
      if (cal != null) {
        final title = cal.title.trim();
        lines.add(title.isEmpty ? 'Событие' : title);
        if (cal.startMs > 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(cal.startMs);
          final mm = dt.minute.toString().padLeft(2, '0');
          lines.add(
              '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${dt.hour}:$mm');
        }
        final note = cal.note?.trim();
        if (note != null && note.isNotEmpty) lines.add(note);
      } else {
        final poll = MessagePoll.tryDecode(m.pollJson);
        if (poll != null) {
          final q = poll.question.trim();
          lines.add(q.isEmpty ? 'Опрос' : 'Опрос: $q');
          final labels = poll.displayLabels(m.id);
          for (var i = 0; i < labels.length; i++) {
            lines.add('${i + 1}. ${labels[i]}');
          }
        } else {
          final missing = groupMessageMissingLocalMedia(m);
          final t = m.text.trim();
          if (t.isNotEmpty && !(missing && isSyntheticMediaCaption(m.text))) {
            lines.add(t);
          }
        }
      }
    }

    if (m.imagePath != null && m.imagePath!.trim().isNotEmpty) {
      lines.add('[Изображение]');
    }
    if (m.videoPath != null && m.videoPath!.trim().isNotEmpty) {
      lines.add('[Видео]');
    }
    if (m.voicePath != null && m.voicePath!.trim().isNotEmpty) {
      lines.add('[Голосовое сообщение]');
    }
    if (m.latitude != null && m.longitude != null) {
      lines.add('[Гео: ${m.latitude}, ${m.longitude}]');
    }

    return lines.join('\n').trim();
  }

  Future<void> _handleGroupMessageLongPress(GroupMessage m) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('Реакция'),
              onTap: () => Navigator.pop(ctx, 'react'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Скопировать'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Переслать…'),
              onTap: () => Navigator.pop(ctx, 'fwd'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Экспортировать…'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'react') {
      final emoji = await showReactionPickerSheet(context);
      if (emoji == null) return;
      final myId = CryptoService.instance.publicKeyHex;
      await GroupService.instance.toggleMessageReaction(m.id, emoji, myId);
      await BroadcastOutboxService.instance.enqueueReactionExt(
        kind: 'group_message',
        targetId: m.id,
        emoji: emoji,
        fromId: myId,
      );
    } else if (action == 'copy') {
      final plain = _plainTextForClipboardGroup(m);
      if (plain.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нечего копировать')),
        );
        return;
      }
      await Clipboard.setData(ClipboardData(text: plain));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сообщение скопировано')),
      );
    } else if (action == 'fwd') {
      await _forwardGroupMessageToDm(m);
    } else if (action == 'share') {
      await shareGroupMessageExternally(context, m);
    }
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
    final sel = _controller.selection;
    final hasSelection = sel.isValid && sel.baseOffset != sel.extentOffset;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_group.name, style: const TextStyle(fontSize: 16)),
            Text('${_group.memberIds.length} участников',
                style: TextStyle(
                    fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: 'Календарь группы',
            onPressed: () => unawaited(_openGroupCalendar()),
          ),
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
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final msg = _messages[i];
                          return RepaintBoundary(
                            child: _GroupBubble(
                              msg: msg,
                              senderNick: _nickFor(msg.senderId),
                              cs: cs,
                              groupId: widget.group.id,
                              onCollabPersist: _syncGroupCollab,
                              onLongPressMenu: () =>
                                  _handleGroupMessageLongPress(msg),
                            ),
                          );
                        },
                      ),
                      if (_showScrollToBottomFab)
                        Positioned(
                          right: 10,
                          bottom: 10,
                          child: Material(
                            elevation: 3,
                            shape: const CircleBorder(),
                            color: cs.primary,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _scrollToBottom,
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: cs.onPrimary,
                                  size: 26,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                    top: BorderSide(color: cs.outline.withValues(alpha: 0.3))),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isSending && _sendProgress > 0)
                    LinearProgressIndicator(value: _sendProgress),
                  if (hasSelection && _showFormatStrip)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                      child: Row(
                        children: [
                          _GroupFmtBtn(
                              label: 'B',
                              bold: true,
                              onTap: () => _wrapSelection('**', '**')),
                          _GroupFmtBtn(
                              label: 'I',
                              italic: true,
                              onTap: () => _wrapSelection('_', '_')),
                          _GroupFmtBtn(
                              label: 'S',
                              strikethrough: true,
                              onTap: () => _wrapSelection('~~', '~~')),
                          _GroupFmtBtn(
                              label: 'U',
                              underline: true,
                              onTap: () => _wrapSelection('__', '__')),
                          _GroupFmtBtn(
                              label: '||',
                              onTap: () => _wrapSelection('||', '||')),
                        ],
                      ),
                    ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(children: [
                      if (hasSelection)
                        IconButton(
                          onPressed: () => setState(
                              () => _showFormatStrip = !_showFormatStrip),
                          icon: Icon(
                            Icons.text_fields_rounded,
                            color: _showFormatStrip
                                ? cs.primary
                                : cs.onSurfaceVariant,
                            size: 22,
                          ),
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 36, minHeight: 36),
                          tooltip: _showFormatStrip
                              ? 'Скрыть формат'
                              : 'Формат выделенного текста',
                        ),
                      IconButton(
                        onPressed: _isSending
                            ? null
                            : () => unawaited(showChatEmojiInsertSheet(
                                  context,
                                  onInsert: _insertIntoComposer,
                                )),
                        icon: Icon(
                          Icons.emoji_emotions_outlined,
                          color: _isSending
                              ? cs.onSurface.withValues(alpha: 0.3)
                              : cs.onSurfaceVariant,
                          size: 24,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        tooltip: 'Эмодзи и стикеры',
                      ),
                      IconButton(
                        onPressed: _isSending
                            ? null
                            : () => unawaited(_openGroupMediaGallery()),
                        icon: Icon(
                          Icons.photo_library_outlined,
                          color: _isSending
                              ? cs.onSurface.withValues(alpha: 0.3)
                              : cs.onSurfaceVariant,
                          size: 24,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                        tooltip: 'Галерея медиа',
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            onTapOutside: (_) => _focusNode.unfocus(),
                            contextMenuBuilder: _buildContextMenu,
                            maxLines: AppSettings.instance.sendOnEnter ? 1 : 4,
                            minLines: 1,
                            decoration: InputDecoration(
                              hintText: 'Сообщение...',
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                            ),
                            style: TextStyle(fontSize: 15, color: cs.onSurface),
                            textInputAction: AppSettings.instance.sendOnEnter
                                ? TextInputAction.send
                                : TextInputAction.newline,
                            onSubmitted: AppSettings.instance.sendOnEnter
                                ? (_) => _send()
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_composeHasText || _isSending)
                        GestureDetector(
                          onTap: _isSending || !_composeHasText
                              ? null
                              : _send,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _isSending || !_composeHasText
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.3)
                                  : Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: _isSending
                                ? Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary,
                                    ),
                                  )
                                : Icon(Icons.send_rounded,
                                    color:
                                        Theme.of(context).colorScheme.onPrimary,
                                    size: 20),
                          ),
                        ),
                    ]),
                  ),
                ],
              ),
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
  final Future<void> Function(GroupMessage msg, String newEnc)? onCollabPersist;
  final Future<void> Function()? onLongPressMenu;

  const _GroupBubble({
    required this.msg,
    required this.senderNick,
    required this.cs,
    required this.groupId,
    this.onCollabPersist,
    this.onLongPressMenu,
  });

  Future<void> _toggle(BuildContext context, String emoji) async {
    final myId = CryptoService.instance.publicKeyHex;
    await GroupService.instance.toggleMessageReaction(msg.id, emoji, myId);
    await BroadcastOutboxService.instance.enqueueReactionExt(
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
    final settings = AppSettings.instance;
    final compact = settings.compactMode;
    final missing = groupMessageMissingLocalMedia(msg);
    return Align(
      alignment: msg.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          if (onLongPressMenu != null) {
            unawaited(onLongPressMenu!());
          } else {
            _openPicker(context);
          }
        },
        child: Container(
          margin: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 2 : 3,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: settings.messageVerticalPadding,
          ),
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
              if (msg.forwardFromId != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.forward,
                          size: 14,
                          color: msg.isOutgoing ? cs.onPrimary : cs.primary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          msg.forwardFromNick?.isNotEmpty == true
                              ? msg.forwardFromNick!
                              : '${msg.forwardFromId!.substring(0, 8)}…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: msg.isOutgoing ? cs.onPrimary : cs.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!msg.isOutgoing)
                Text(senderNick,
                    style: TextStyle(
                        fontSize: 11,
                        color: cs.primary,
                        fontWeight: FontWeight.bold)),
              if (missing)
                ClearedMediaPlaceholder(
                  isOutgoing: msg.isOutgoing,
                  isDirectChat: false,
                  colorScheme: cs,
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Откройте группу при подключении к сети — '
                          'запросится история и вложения.',
                        ),
                      ),
                    );
                  },
                ),
              if (!missing &&
                  msg.imagePath != null &&
                  msg.imagePath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Builder(builder: (_) {
                      final isSticker =
                          p.basename(msg.imagePath!).startsWith('stk_');
                      return Image.file(
                        File(msg.imagePath!),
                        width: isSticker ? 132 : 200,
                        height: isSticker ? 132 : null,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      );
                    }),
                  ),
                ),
              if (!missing &&
                  msg.videoPath != null &&
                  msg.videoPath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _GroupInlineVideo(
                    storedPath: msg.videoPath!,
                    isOutgoing: msg.isOutgoing,
                  ),
                ),
              if (MessagePoll.tryDecode(msg.pollJson) case final poll?)
                PollMessageCard(
                  targetId: msg.id,
                  kind: 'group_message',
                  poll: poll,
                  cs: cs,
                  isOutgoing: msg.isOutgoing,
                  compact: false,
                ),
              if (SharedTodoPayload.tryDecode(msg.text) != null &&
                  onCollabPersist != null)
                SharedTodoMessageCard(
                  encoded: msg.text,
                  cs: cs,
                  isOutgoing: msg.isOutgoing,
                  onPersist: (enc) => onCollabPersist!(msg, enc),
                )
              else if (SharedCalendarPayload.tryDecode(msg.text) != null)
                SharedCalendarMessageCard(
                  encoded: msg.text,
                  cs: cs,
                  isOutgoing: msg.isOutgoing,
                )
              else if (msg.text.isNotEmpty &&
                  !(missing && isSyntheticMediaCaption(msg.text)))
                ValueListenableBuilder<List<Contact>>(
                  valueListenable: ChatStorageService.instance.contactsNotifier,
                  builder: (ctx, contacts, __) {
                    return RichMessageText(
                      text: msg.text,
                      textColor: msg.isOutgoing ? cs.onPrimary : cs.onSurface,
                      isOut: msg.isOutgoing,
                      mentionLabelFor: (hex) => resolveChannelMentionDisplay(
                        hex,
                        contacts,
                        ProfileService.instance.profile,
                      ),
                      onMentionTap: (hex) => openDmFromMentionKey(ctx, hex),
                    );
                  },
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
              if (msg.latitude != null && msg.longitude != null)
                _GroupLocationPreview(
                  lat: msg.latitude!,
                  lng: msg.longitude!,
                  isOut: msg.isOutgoing,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

class _GroupLocationPreview extends StatelessWidget {
  final double lat;
  final double lng;
  final bool isOut;

  const _GroupLocationPreview({
    required this.lat,
    required this.lng,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              unawaited(
                showLocationActionsSheet(
                  context,
                  latitude: lat,
                  longitude: lng,
                ),
              );
            },
            child: SizedBox(
              width: 220,
              height: 124,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    'https://static-maps.yandex.ru/1.x/?lang=ru_RU&ll=$lng,$lat&z=14&size=440,248&l=map&pt=$lng,$lat,pm2rdm',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: isOut
                          ? Colors.black.withValues(alpha: 0.2)
                          : cs.surfaceContainerHighest,
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.45),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Row(
                      children: [
                        const Icon(Icons.location_on,
                            color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
                  style: TextStyle(
                      color: cs.onPrimaryContainer.withValues(alpha: 0.6))),
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

/// Видео в группе: квадратик (1:1) или ролик из галереи.
class _GroupInlineVideo extends StatefulWidget {
  final String storedPath;
  final bool isOutgoing;

  const _GroupInlineVideo({
    required this.storedPath,
    required this.isOutgoing,
  });

  @override
  State<_GroupInlineVideo> createState() => _GroupInlineVideoState();
}

class _GroupInlineVideoState extends State<_GroupInlineVideo> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _playing = false;
  int _embedPauseGen = 0;

  void _onEmbedPauseBus() {
    if (!mounted) return;
    final g = EmbeddedVideoPauseBus.instance.generation.value;
    if (g != _embedPauseGen) {
      _embedPauseGen = g;
      try {
        _ctrl?.pause();
      } catch (_) {}
      setState(() => _playing = false);
    }
  }

  String? get _abs {
    final r = ImageService.instance.resolveStoredPath(widget.storedPath);
    return (r != null && File(r).existsSync()) ? r : null;
  }

  bool get _isSquare => widget.storedPath.endsWith('_sq.mp4');

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    final p = _abs;
    if (p != null) _init(p);
  }

  @override
  void didUpdateWidget(_GroupInlineVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storedPath != widget.storedPath) {
      _ctrl?.dispose();
      _ctrl = null;
      _initialized = false;
      _playing = false;
      final p = _abs;
      if (p != null) _init(p);
    }
  }

  Future<void> _init(String path) async {
    final ctrl = VideoPlayerController.file(File(path));
    try {
      await ctrl.initialize();
      if (_isSquare) {
        ctrl.setLooping(true);
      } else {
        await ctrl.seekTo(Duration.zero);
      }
      if (mounted) {
        setState(() {
          _ctrl = ctrl;
          _initialized = true;
        });
      } else {
        ctrl.dispose();
      }
    } catch (e) {
      debugPrint('[GroupVideo] $e');
      ctrl.dispose();
    }
  }

  @override
  void dispose() {
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    _ctrl?.dispose();
    super.dispose();
  }

  void _toggleSquare() {
    if (_ctrl == null || !_initialized) return;
    if (_playing) {
      _ctrl!.pause();
      setState(() => _playing = false);
      return;
    }
    EmbeddedVideoPauseBus.instance.bump();
    unawaited(VoiceService.instance.stopPlayback());
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _ctrl == null) return;
      _ctrl!.play();
      setState(() => _playing = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _abs;
    if (p == null) {
      return Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.videocam_off_outlined,
            color: Colors.white38, size: 32),
      );
    }
    if (_isSquare) {
      return GestureDetector(
        onTap: _toggleSquare,
        child: SizedBox(
          width: 160,
          height: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_initialized && _ctrl != null)
                  FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _ctrl!.value.size.width,
                      height: _ctrl!.value.size.height,
                      child: VideoPlayer(_ctrl!),
                    ),
                  )
                else
                  Container(
                    color: const Color(0xFF1A1A1A),
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white54),
                      ),
                    ),
                  ),
                if (!_playing)
                  Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    child: const Center(
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 52),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final ar = (_initialized && _ctrl != null && _ctrl!.value.aspectRatio > 0)
        ? _ctrl!.value.aspectRatio
        : 16 / 9;
    const w = 220.0;
    final h = (w / ar).clamp(80.0, 280.0);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _GroupVideoFullScreen(path: p),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: const Color(0xFF111111)),
              if (_initialized && _ctrl != null)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _ctrl!.value.size.width,
                    height: _ctrl!.value.size.height,
                    child: VideoPlayer(_ctrl!),
                  ),
                ),
              Container(color: Colors.black.withValues(alpha: 0.28)),
              const Center(
                child:
                    Icon(Icons.play_circle_fill, color: Colors.white, size: 54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupVideoFullScreen extends StatefulWidget {
  final String path;
  const _GroupVideoFullScreen({required this.path});

  @override
  State<_GroupVideoFullScreen> createState() => _GroupVideoFullScreenState();
}

class _GroupVideoFullScreenState extends State<_GroupVideoFullScreen> {
  VideoPlayerController? _ctrl;
  int _embedPauseGen = 0;

  void _onEmbedPauseBus() {
    if (!mounted) return;
    final g = EmbeddedVideoPauseBus.instance.generation.value;
    if (g != _embedPauseGen) {
      _embedPauseGen = g;
      try {
        _ctrl?.pause();
      } catch (_) {}
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    final c = VideoPlayerController.file(File(widget.path));
    c.initialize().then((_) {
      if (mounted) {
        setState(() => _ctrl = c);
        c.play();
      } else {
        c.dispose();
      }
    });
  }

  @override
  void dispose() {
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: c != null && c.value.isInitialized
            ? AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: VideoPlayer(c),
              )
            : const CircularProgressIndicator(color: Colors.white54),
      ),
    );
  }
}
