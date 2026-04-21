import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../models/channel.dart';
import '../../models/chat_message.dart';
import '../../models/contact.dart';
import '../../models/message_poll.dart';
import '../../utils/channel_mentions.dart';
import '../../services/broadcast_outbox_service.dart';
import '../../services/channel_service.dart';
import '../../services/notification_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/image_service.dart';
import '../../services/voice_service.dart';
import '../widgets/animated_transitions.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/poll_message_card.dart';
import '../widgets/missing_local_media.dart';
import '../widgets/channel_feed_image.dart';
import 'image_editor_screen.dart';
import 'channel_profile_screen.dart';
import 'chat_screen.dart' show ChatScreen, DmForwardDraft;

// ══════════════════════════════════════════════════════════════════
// Forward / упоминания (канал)
// ══════════════════════════════════════════════════════════════════

ChatMessage _channelPostToForwardMessage(ChannelPost post, String channelId) {
  var t = post.text.trim();
  if (t.isEmpty) {
    if (post.pollJson != null && MessagePoll.tryDecode(post.pollJson) != null) {
      t = '📊 Опрос';
    } else if (post.imagePath != null) {
      t = '🖼 Фото';
    } else if (post.videoPath != null) {
      t = '📹 Видео';
    } else if (post.voicePath != null) {
      t = '🎤 Голос';
    } else if (post.filePath != null) {
      t = '📎 ${post.fileName ?? 'Файл'}';
    } else {
      t = ' ';
    }
  }
  return ChatMessage(
    id: post.id,
    peerId: channelId,
    text: t.isEmpty ? ' ' : t,
    imagePath: post.imagePath,
    videoPath: post.videoPath,
    voicePath: post.voicePath,
    filePath: post.filePath,
    fileName: post.fileName,
    fileSize: post.fileSize,
    isOutgoing: false,
    timestamp: DateTime.fromMillisecondsSinceEpoch(post.timestamp),
    status: MessageStatus.sent,
  );
}

ChatMessage _channelCommentToForwardMessage(ChannelComment c, String channelId) {
  var t = c.text.trim();
  if (t.isEmpty) {
    if (c.imagePath != null) {
      t = '🖼 Фото';
    } else if (c.videoPath != null) {
      t = '📹 Видео';
    } else if (c.voicePath != null) {
      t = '🎤 Голос';
    } else if (c.filePath != null) {
      t = '📎 ${c.fileName ?? 'Файл'}';
    } else {
      t = ' ';
    }
  }
  return ChatMessage(
    id: c.id,
    peerId: channelId,
    text: t.isEmpty ? ' ' : t,
    imagePath: c.imagePath,
    videoPath: c.videoPath,
    voicePath: c.voicePath,
    filePath: c.filePath,
    fileName: c.fileName,
    fileSize: c.fileSize,
    isOutgoing: false,
    timestamp: DateTime.fromMillisecondsSinceEpoch(c.timestamp),
    status: MessageStatus.sent,
  );
}

Future<void> _pickForwardChannelContent(
  BuildContext context, {
  required ChatMessage forwardMessage,
  required String forwardAuthorId,
  required String originalAuthorNick,
}) async {
  final peers = await ChatStorageService.instance.getChatPeerIds();
  if (!context.mounted) return;
  if (peers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Нет чатов для пересылки')),
    );
    return;
  }
  final nickMap = <String, String>{};
  for (final c in ChatStorageService.instance.contactsNotifier.value) {
    nickMap[c.publicKeyHex] = c.nickname;
  }
  final picked = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Переслать в…')),
          for (final pid in peers)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(nickMap[pid] ?? '${pid.substring(0, 8)}…'),
              onTap: () => Navigator.pop(ctx, pid),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final nick = nickMap[picked] ?? '${picked.substring(0, 8)}…';
  final contact = await ChatStorageService.instance.getContact(picked);
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ChatScreen(
        peerId: picked,
        peerNickname: nick,
        peerAvatarColor: contact?.avatarColor ?? 0xFF42A5F5,
        peerAvatarEmoji: contact?.avatarEmoji ?? '👤',
        peerAvatarImagePath: contact?.avatarImagePath,
        forwardDraft: DmForwardDraft(
          message: forwardMessage,
          sourcePeerId: '',
          originalAuthorNick: originalAuthorNick,
          forwardAuthorId: forwardAuthorId,
        ),
      ),
    ),
  );
}

void insertChannelMentionToken(
    TextEditingController ctrl, String publicKeyHex) {
  final t = ctrl.text;
  final sel = ctrl.selection;
  final start = sel.isValid ? sel.start.clamp(0, t.length) : t.length;
  final end = sel.isValid ? sel.end.clamp(0, t.length) : t.length;
  final insert = '&$publicKeyHex ';
  final nt = t.replaceRange(start, end, insert);
  ctrl.value = TextEditingValue(
    text: nt,
    selection: TextSelection.collapsed(
        offset: (start + insert.length).clamp(0, nt.length)),
  );
}

Future<void> _showContactMentionPicker(
  BuildContext context,
  void Function(String publicKeyHex) onPick,
) async {
  final contacts = ChatStorageService.instance.contactsNotifier.value;
  if (contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Нет контактов — добавьте людей в разделе «Контакты»')),
    );
    return;
  }
  final picked = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Отметить человека'),
            subtitle: Text('В текст добавится уникальный код (ключ). '
                'Для других он отобразится как @ник.'),
          ),
          for (final c in contacts)
            ListTile(
              leading: AvatarWidget(
                initials: c.initials,
                color: c.avatarColor,
                emoji: c.avatarEmoji,
                imagePath: c.avatarImagePath,
                size: 40,
              ),
              title: Text(c.nickname),
              subtitle: c.username.isNotEmpty ? Text('@${c.username}') : null,
              onTap: () => Navigator.pop(ctx, c.publicKeyHex),
            ),
        ],
      ),
    ),
  );
  if (picked != null && context.mounted) {
    onPick(picked);
  }
}

// ══════════════════════════════════════════════════════════════════
// 1. ChannelsScreen — list of channels with search
// ══════════════════════════════════════════════════════════════════

class ChannelsScreen extends StatefulWidget {
  final String searchQuery;
  const ChannelsScreen({super.key, this.searchQuery = ''});

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  List<Channel> _channels = [];

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

  void _load() async {
    final channels = await ChannelService.instance.getChannels();
    if (mounted) setState(() => _channels = channels);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = widget.searchQuery.toLowerCase().trim();
    final filtered = q.isEmpty
        ? _channels
        : _channels.where((ch) => ch.name.toLowerCase().contains(q)).toList();

    return Scaffold(
      body: ValueListenableBuilder<List<ChannelInvite>>(
        valueListenable: ChannelService.instance.pendingChannelInvites,
        builder: (_, invites, __) {
          final hasInvites = invites.isNotEmpty && q.isEmpty;
          final hasChannels = filtered.isNotEmpty;

          if (!hasInvites && !hasChannels) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.campaign_outlined,
                    size: 64, color: cs.primary.withValues(alpha: 0.3)),
                const SizedBox(height: 16),
                Text('Нет каналов',
                    style: TextStyle(
                        fontSize: 18,
                        color: cs.onSurface.withValues(alpha: 0.5))),
                const SizedBox(height: 8),
                Text('Создайте канал для публикаций',
                    style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.3))),
              ]),
            );
          }

          return ListView(
            padding: const EdgeInsets.only(top: 8),
            children: [
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
                ...invites.map((inv) => _ChannelInviteCard(invite: inv)),
                const SizedBox(height: 8),
              ],
              for (var i = 0; i < filtered.length; i++)
                StaggeredListItem(
                  index: i,
                  child: _ChannelTile(
                      channel: filtered[i],
                      onTap: () => _openChannel(filtered[i])),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createChannel,
        child: const Icon(Icons.add_comment_outlined),
      ),
    );
  }

  void _openChannel(Channel ch) {
    Navigator.push(
      context,
      SmoothPageRoute(page: ChannelViewScreen(channel: ch)),
    );
  }

  void _createChannel() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый канал'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            maxLength: 30,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Название канала',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: descCtrl,
            maxLength: 100,
            decoration: const InputDecoration(
              hintText: 'Описание (необязательно)',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
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
              final ch = await ChannelService.instance.createChannel(
                name: name,
                adminId: myId,
                description:
                    descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
              );
              await GossipRouter.instance.broadcastChannelMeta(
                channelId: ch.id,
                name: ch.name,
                adminId: ch.adminId,
                avatarColor: ch.avatarColor,
                avatarEmoji: ch.avatarEmoji,
                description: ch.description,
                commentsEnabled: ch.commentsEnabled,
                createdAt: ch.createdAt,
                verified: ch.verified,
                verifiedBy: ch.verifiedBy,
              );
              if (mounted) _openChannel(ch);
            },
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }
}

// ── Channel tile ────────────────────────────────────────────────

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final VoidCallback onTap;
  const _ChannelTile({required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final myId = CryptoService.instance.publicKeyHex;
    final isAdmin = channel.adminId == myId;
    return ListTile(
      leading: AvatarWidget(
        key: ValueKey(
            'ch_tile_${channel.id}_${channel.avatarImagePath ?? ''}'),
        initials: channel.name.isNotEmpty ? channel.name[0].toUpperCase() : '?',
        color: channel.avatarColor,
        emoji: channel.avatarEmoji,
        imagePath: channel.avatarImagePath,
        size: 48,
      ),
      title: Row(children: [
        Flexible(
          child: Text(channel.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
        ),
        if (channel.verified) ...[
          const SizedBox(width: 4),
          const Icon(Icons.verified, size: 16, color: Colors.blue),
        ],
        if (channel.blocked) ...[
          const SizedBox(width: 4),
          const Icon(Icons.block, size: 14, color: Colors.red),
        ],
        if (isAdmin) ...[
          const SizedBox(width: 6),
          Icon(Icons.star, size: 14, color: Colors.amber.shade700),
        ],
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (channel.foreignAgent)
            const Text(
              'ДАННОЕ СООБЩЕНИЕ СОЗДАНО И (ИЛИ) РАСПРОСТРАНЕНО ИНОСТРАННЫМ АГЕНТОМ',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.orange,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            channel.description ??
                '${channel.subscriberIds.length} подписчиков',
            style: TextStyle(
                fontSize: 13, color: cs.onSurface.withValues(alpha: 0.5)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 2. ChannelViewScreen — channel view with posts feed + admin input
// ══════════════════════════════════════════════════════════════════

class ChannelViewScreen extends StatefulWidget {
  final Channel channel;
  const ChannelViewScreen({super.key, required this.channel});

  @override
  State<ChannelViewScreen> createState() => _ChannelViewScreenState();
}

class _ChannelViewScreenState extends State<ChannelViewScreen> {
  List<ChannelPost> _posts = [];
  late Channel _channel;
  final _postCtrl = TextEditingController();
  final _feedScrollController = ScrollController();
  bool _showScrollToBottomFab = false;
  final _uuid = const Uuid();
  final _picker = ImagePicker();
  bool _isSending = false;
  double _sendProgress = 0.0;
  bool _isRecording = false;
  final _recordingSecondsNotifier = ValueNotifier<double>(0);
  Timer? _recordingTimer;

  String get _myId => CryptoService.instance.publicKeyHex;
  bool get _isAdmin => _channel.adminId == _myId;
  bool get _isModerator => _channel.moderatorIds.contains(_myId);
  bool get _isSubscribed => _channel.subscriberIds.contains(_myId);

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    unawaited(_loadAndMarkRead());
    ChannelService.instance.version.addListener(_load);
    _feedScrollController.addListener(_onFeedScroll);
    // Подтягиваем новые посты из P2P-сети подписчиков. Отвечают все, у кого
    // есть история; дедуп по postId на приёме.
    _requestHistoryDelta();
    NotificationService.instance.currentRoute.value = 'channel:${_channel.id}';
  }

  Future<void> _requestHistoryDelta() async {
    if (!_isSubscribed && _channel.adminId != _myId) return;
    final lastPost = await ChannelService.instance.getLastPost(_channel.id);
    unawaited(GossipRouter.instance.sendChannelHistoryRequest(
      channelId: _channel.id,
      requesterId: _myId,
      adminId: _channel.adminId,
      sinceTs: lastPost?.timestamp ?? 0,
    ));
  }

  Future<void> _openMentionPickerForPost() async {
    await _showContactMentionPicker(context, (hex) {
      insertChannelMentionToken(_postCtrl, hex);
    });
  }

  Future<void> _broadcastVisualAssetBytes({
    required String msgId,
    required Uint8List rawFileBytes,
  }) async {
    final chunks = ImageService.instance.splitToBase64Chunks(rawFileBytes);
    final myId = _myId;
    await GossipRouter.instance.sendImgMeta(
      msgId: msgId,
      totalChunks: chunks.length,
      fromId: myId,
      isAvatar: false,
    );
    for (var i = 0; i < chunks.length; i++) {
      await GossipRouter.instance.sendImgChunk(
        msgId: msgId,
        index: i,
        base64Data: chunks[i],
        fromId: myId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> _syncChannelVisualsAfterEdit({
    required Channel updated,
    required String? prevAvatarPath,
    required String? prevBannerPath,
  }) async {
    if (updated.avatarImagePath != prevAvatarPath &&
        updated.avatarImagePath != null) {
      final rp =
          ImageService.instance.resolveStoredPath(updated.avatarImagePath);
      if (rp != null && File(rp).existsSync()) {
        final bytes = await File(rp).readAsBytes();
        await _broadcastVisualAssetBytes(
          msgId: ChannelService.channelAvatarBroadcastMsgId(updated.id),
          rawFileBytes: bytes,
        );
      }
    }
    if (updated.bannerImagePath != prevBannerPath &&
        updated.bannerImagePath != null) {
      final rp =
          ImageService.instance.resolveStoredPath(updated.bannerImagePath);
      if (rp != null && File(rp).existsSync()) {
        final bytes = await File(rp).readAsBytes();
        await _broadcastVisualAssetBytes(
          msgId: ChannelService.channelBannerBroadcastMsgId(updated.id),
          rawFileBytes: bytes,
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(ChannelService.instance.markChannelRead(_channel.id));
    _feedScrollController.removeListener(_onFeedScroll);
    _feedScrollController.dispose();
    ChannelService.instance.version.removeListener(_load);
    _postCtrl.dispose();
    _recordingTimer?.cancel();
    _recordingSecondsNotifier.dispose();
    if (NotificationService.instance.currentRoute.value ==
        'channel:${_channel.id}') {
      NotificationService.instance.currentRoute.value = null;
    }
    super.dispose();
  }

  Future<void> _load() async {
    final ch = await ChannelService.instance.getChannel(_channel.id);
    if (ch != null && mounted) setState(() => _channel = ch);
    final posts = await ChannelService.instance.getPosts(_channel.id);
    if (mounted) {
      setState(() => _posts = posts);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onFeedScroll());
    }
  }

  Future<void> _loadAndMarkRead() async {
    await _load();
    if (mounted) await ChannelService.instance.markChannelRead(_channel.id);
  }

  void _onFeedScroll() {
    final pos =
        _feedScrollController.hasClients ? _feedScrollController.position : null;
    if (pos == null) return;
    final away = pos.maxScrollExtent - pos.pixels;
    final show = away > 120;
    if (show != _showScrollToBottomFab && mounted) {
      setState(() => _showScrollToBottomFab = show);
    }
  }

  void _scrollFeedToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_feedScrollController.hasClients) {
        _feedScrollController.animateTo(
          _feedScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Text post ───────────────────────────────────────────────

  Future<void> _createPost() async {
    final text = _postCtrl.text.trim();
    if (text.isEmpty) return;
    _postCtrl.clear();

    const chunkLen = 600;
    final parts = <String>[];
    final t = text.trim();
    for (var i = 0; i < t.length; i += chunkLen) {
      final end = (i + chunkLen) > t.length ? t.length : i + chunkLen;
      parts.add(t.substring(i, end));
    }

    for (final partText in parts) {
      final postId = _uuid.v4();
      final now = DateTime.now().millisecondsSinceEpoch;

      final post = ChannelPost(
        id: postId,
        channelId: _channel.id,
        authorId: _myId,
        text: partText,
        timestamp: now,
      );
      await ChannelService.instance.savePost(post);

      await BroadcastOutboxService.instance.enqueueChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: partText,
        timestamp: now,
      );
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
                    decoration: const InputDecoration(labelText: 'Вариант 1'),
                  ),
                  TextField(
                    controller: o2,
                    decoration: const InputDecoration(labelText: 'Вариант 2'),
                  ),
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
                child: const Text('Опубликовать'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _createPollPost() async {
    final poll = await _showPollEditor();
    if (poll == null || !mounted) return;
    final postId = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final pj = poll.encode();
    final post = ChannelPost(
      id: postId,
      channelId: _channel.id,
      authorId: _myId,
      text: '',
      timestamp: now,
      pollJson: pj,
    );
    await ChannelService.instance.savePost(post);
    await BroadcastOutboxService.instance.enqueueChannelPost(
      channelId: _channel.id,
      postId: postId,
      authorId: _myId,
      text: '',
      timestamp: now,
      pollJson: pj,
    );
  }

  // ── Image post ──────────────────────────────────────────────

  Future<void> _pickAndSendImage() async {
    if (_isSending) return;

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    if (picked.path.toLowerCase().endsWith('.gif')) {
      setState(() {
        _isSending = true;
        _sendProgress = 0.0;
      });
      try {
        final path =
            await ImageService.instance.saveChatImageFromPicker(picked.path);
        final bytes = await File(path).readAsBytes();
        final chunks = ImageService.instance.splitToBase64Chunks(bytes);
        final postId = _uuid.v4();
        await GossipRouter.instance.sendImgMeta(
          msgId: postId,
          totalChunks: chunks.length,
          fromId: _myId,
          isAvatar: false,
        );
        for (var i = 0; i < chunks.length; i++) {
          await GossipRouter.instance.sendImgChunk(
            msgId: postId,
            index: i,
            base64Data: chunks[i],
            fromId: _myId,
          );
          if (mounted) setState(() => _sendProgress = (i + 1) / chunks.length);
        }
        final cap = _postCtrl.text.trim();
        final post = ChannelPost(
          id: postId,
          channelId: _channel.id,
          authorId: _myId,
          text: cap.isEmpty ? '🎞 GIF' : cap,
          imagePath: path,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        await ChannelService.instance.savePost(post);
        await BroadcastOutboxService.instance.enqueueChannelPost(
          channelId: _channel.id,
          postId: postId,
          authorId: _myId,
          text: post.text,
          timestamp: post.timestamp,
          hasImage: true,
        );
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
      return;
    }

    final editedBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
          builder: (_) => ImageEditorScreen(imagePath: picked.path)),
    );
    if (editedBytes == null || !mounted) return;

    final quality = await _showQualityPicker();
    if (quality == null || !mounted) return;

    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
          '${tmpDir.path}/ch_edit_${DateTime.now().millisecondsSinceEpoch}.png');
      await tmpFile.writeAsBytes(editedBytes);
      final path = await ImageService.instance.compressAndSave(
        tmpFile.path,
        quality: quality.quality,
        maxSize: quality.maxSize,
      );
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final postId = _uuid.v4();

      // Broadcast image via chunks (reusing img_meta / img_chunk protocol)
      await GossipRouter.instance.sendImgMeta(
        msgId: postId,
        totalChunks: chunks.length,
        fromId: _myId,
        isAvatar: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: postId,
          index: i,
          base64Data: chunks[i],
          fromId: _myId,
        );
        if (mounted) setState(() => _sendProgress = (i + 1) / chunks.length);
      }

      // Save post locally
      final post = ChannelPost(
        id: postId,
        channelId: _channel.id,
        authorId: _myId,
        text: _postCtrl.text.trim(),
        imagePath: path,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      await ChannelService.instance.savePost(post);

      await BroadcastOutboxService.instance.enqueueChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: post.text,
        timestamp: post.timestamp,
        hasImage: true,
      );
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

  // ── Video post (gallery) ──────────────────────────────────────

  Future<void> _pickAndSendVideo() async {
    if (_isSending) return;
    if (!mounted) return;

    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final path =
          await ImageService.instance.saveVideo(picked.path, isSquare: false);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final postId = _uuid.v4();

      await GossipRouter.instance.sendImgMeta(
        msgId: postId,
        totalChunks: chunks.length,
        fromId: _myId,
        isAvatar: false,
        isVideo: true,
        isSquare: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: postId,
          index: i,
          base64Data: chunks[i],
          fromId: _myId,
        );
        if (mounted) setState(() => _sendProgress = (i + 1) / chunks.length);
      }

      final post = ChannelPost(
        id: postId,
        channelId: _channel.id,
        authorId: _myId,
        text: '',
        videoPath: path,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      await ChannelService.instance.savePost(post);

      await BroadcastOutboxService.instance.enqueueChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: '',
        timestamp: post.timestamp,
        hasVideo: true,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка видео: $e'), backgroundColor: Colors.red),
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

  // ── File post ───────────────────────────────────────────────

  Future<void> _pickAndSendFile() async {
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
    final fileBytes = await File(srcPath).readAsBytes();
    if (!mounted) return;

    if (fileBytes.length > 500 * 1024) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Большой файл'),
          content: Text(
            'Файл ${(fileBytes.length / 1024).toStringAsFixed(0)} КБ — '
            'передача по Bluetooth займёт несколько минут. Продолжить?',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Отправить')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files');
      if (!filesDir.existsSync()) filesDir.createSync(recursive: true);
      final destPath = '${filesDir.path}/$originalName';
      await File(srcPath).copy(destPath);

      final chunks = ImageService.instance.splitToBase64Chunks(fileBytes);
      final postId = _uuid.v4();

      await GossipRouter.instance.sendImgMeta(
        msgId: postId,
        totalChunks: chunks.length,
        fromId: _myId,
        isAvatar: false,
        isFile: true,
        fileName: originalName,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: postId,
          index: i,
          base64Data: chunks[i],
          fromId: _myId,
        );
        if (mounted) setState(() => _sendProgress = (i + 1) / chunks.length);
      }

      final post = ChannelPost(
        id: postId,
        channelId: _channel.id,
        authorId: _myId,
        text: '\u{1F4CE} $originalName',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        filePath: destPath,
        fileName: originalName,
        fileSize: fileBytes.length,
      );
      await ChannelService.instance.savePost(post);

      await BroadcastOutboxService.instance.enqueueChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: post.text,
        timestamp: post.timestamp,
        hasFile: true,
        fileName: originalName,
      );
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

  // ── Voice post ──────────────────────────────────────────────

  Future<void> _startVoiceRecording() async {
    if (_isSending || _isRecording) return;
    final hasPerm = await VoiceService.instance.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нет доступа к микрофону — проверьте разрешения'),
          ),
        );
      }
      return;
    }
    final path = await VoiceService.instance.startRecording();
    if (path == null) return;
    _recordingSecondsNotifier.value = 0;
    setState(() {
      _isRecording = true;
    });
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_isRecording) return;
      _recordingSecondsNotifier.value += 0.25;
      if (_recordingSecondsNotifier.value >= 60) {
        _stopAndSendVoice();
      }
    });
  }

  Future<void> _stopAndSendVoice() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;

    final path = await VoiceService.instance.stopRecording();
    final duration = _recordingSecondsNotifier.value;
    _recordingSecondsNotifier.value = 0;
    setState(() {
      _isRecording = false;
    });

    if (path == null || duration < 0.5) return;

    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final postId = _uuid.v4();

      await GossipRouter.instance.sendImgMeta(
        msgId: postId,
        totalChunks: chunks.length,
        fromId: _myId,
        isAvatar: false,
        isVoice: true,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: postId,
          index: i,
          base64Data: chunks[i],
          fromId: _myId,
        );
        if (mounted) setState(() => _sendProgress = (i + 1) / chunks.length);
      }

      final post = ChannelPost(
        id: postId,
        channelId: _channel.id,
        authorId: _myId,
        text: '\u{1F3A4} Голосовое',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        voicePath: path,
      );
      await ChannelService.instance.savePost(post);

      await BroadcastOutboxService.instance.enqueueChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: post.text,
        timestamp: post.timestamp,
        hasVoice: true,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка голосового: $e'),
              backgroundColor: Colors.red),
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

  // ── Quality picker (same as chat) ──────────────────────────

  Future<_ImageQuality?> _showQualityPicker() async {
    return showModalBottomSheet<_ImageQuality>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Качество фото',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.flash_on, color: Colors.green),
              title: const Text('Быстрое'),
              subtitle: const Text('160px, маленький размер'),
              onTap: () => Navigator.pop(
                  ctx, const _ImageQuality(quality: 40, maxSize: 160)),
            ),
            ListTile(
              leading: const Icon(Icons.tune, color: Colors.orange),
              title: const Text('Стандарт'),
              subtitle: const Text('320px, баланс скорость/качество'),
              onTap: () => Navigator.pop(
                  ctx, const _ImageQuality(quality: 55, maxSize: 320)),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality, color: Colors.blue),
              title: const Text('Высокое'),
              subtitle: const Text('640px, дольше передача'),
              onTap: () => Navigator.pop(
                  ctx, const _ImageQuality(quality: 70, maxSize: 640)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Admin actions ───────────────────────────────────────────

  Future<void> _deletePost(String postId) async {
    await ChannelService.instance.deletePost(postId);
    await GossipRouter.instance.sendChannelDeletePost(
      postId: postId,
      authorId: _myId,
    );
  }

  void _toggleComments() async {
    final updated =
        _channel.copyWith(commentsEnabled: !_channel.commentsEnabled);
    await ChannelService.instance.updateChannel(updated);
    await GossipRouter.instance.broadcastChannelMeta(
      channelId: _channel.id,
      name: _channel.name,
      adminId: _channel.adminId,
      avatarColor: _channel.avatarColor,
      avatarEmoji: _channel.avatarEmoji,
      description: _channel.description,
      commentsEnabled: updated.commentsEnabled,
      createdAt: _channel.createdAt,
      verified: _channel.verified,
      verifiedBy: _channel.verifiedBy,
      moderatorIds: _channel.moderatorIds,
    );
  }

  void _requestVerification() async {
    if (_channel.verified) return;
    final canAutoVerify = ChannelService.instance.checkAutoVerify(_channel);
    if (canAutoVerify) {
      await ChannelService.instance.verifyChannel(_channel.id, 'auto');
      await GossipRouter.instance.broadcastChannelMeta(
        channelId: _channel.id,
        name: _channel.name,
        adminId: _channel.adminId,
        avatarColor: _channel.avatarColor,
        avatarEmoji: _channel.avatarEmoji,
        description: _channel.description,
        commentsEnabled: _channel.commentsEnabled,
        createdAt: _channel.createdAt,
        verified: true,
        verifiedBy: 'auto',
        moderatorIds: _channel.moderatorIds,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Канал верифицирован!')),
        );
      }
    } else {
      // Send verification request to network admins.
      await GossipRouter.instance.sendVerificationRequest(
        channelId: _channel.id,
        channelName: _channel.name,
        adminId: _channel.adminId,
        subscriberCount: _channel.subscriberIds.length,
        avatarEmoji: _channel.avatarEmoji,
        description: _channel.description,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Заявка на верификацию отправлена администраторам сети'),
          ),
        );
      }
    }
  }

  // ── Edit channel profile ─────────────────────────────────────

  static const _accentColors = [
    0xFF42A5F5, // голубой (по умолчанию)
    0xFF66BB6A, // зелёный
    0xFFEF5350, // красный
    0xFFAB47BC, // фиолетовый
    0xFFFFA726, // оранжевый
    0xFF26C6DA, // бирюзовый
    0xFFEC407A, // розовый
    0xFF8D6E63, // коричневый
    0xFF78909C, // серо-стальной
  ];

  void _editChannel() {
    final nameCtrl = TextEditingController(text: _channel.name);
    final descCtrl = TextEditingController(text: _channel.description ?? '');
    final emojiCtrl = TextEditingController(text: _channel.avatarEmoji);
    String? pickedImagePath = _channel.avatarImagePath;
    String? pickedBannerPath = _channel.bannerImagePath;
    int pickedColor = _channel.avatarColor;
    bool commentsEnabled = _channel.commentsEnabled;
    bool isPublic = _channel.isPublic;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final cs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: const Text('Настройки канала'),
            contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            content: Padding(
              padding:
                  EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Avatar image picker
                    Center(
                      child: GestureDetector(
                        onTap: () async {
                          final picked = await ImagePicker()
                              .pickImage(source: ImageSource.gallery);
                          if (picked == null) return;
                          final saved =
                              await ImageService.instance.compressAndSave(
                            picked.path,
                            isAvatar: true,
                          );
                          if (!ctx.mounted) return;
                          setDialogState(() => pickedImagePath = saved);
                        },
                        child: CircleAvatar(
                          radius: 36,
                          backgroundColor: Color(pickedColor),
                          backgroundImage: () {
                            if (pickedImagePath == null) return null;
                            final rp = ImageService.instance
                                .resolveStoredPath(pickedImagePath);
                            if (rp != null && File(rp).existsSync()) {
                              return FileImage(File(rp));
                            }
                            return null;
                          }(),
                          child: () {
                            if (pickedImagePath == null) {
                              return Text(
                                  emojiCtrl.text.isEmpty
                                      ? '📢'
                                      : emojiCtrl.text,
                                  style: const TextStyle(fontSize: 28));
                            }
                            final rp = ImageService.instance
                                .resolveStoredPath(pickedImagePath);
                            if (rp != null && File(rp).existsSync()) {
                              return null;
                            }
                            return Text(
                                emojiCtrl.text.isEmpty ? '📢' : emojiCtrl.text,
                                style: const TextStyle(fontSize: 28));
                          }(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text('Баннер профиля',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: GestureDetector(
                        onTap: () async {
                          final picked = await ImagePicker()
                              .pickImage(source: ImageSource.gallery);
                          if (picked == null) return;
                          final saved =
                              await ImageService.instance.compressAndSave(
                            picked.path,
                            isAvatar: false,
                            maxSize: 1200,
                            quality: 82,
                          );
                          if (!ctx.mounted) return;
                          setDialogState(() => pickedBannerPath = saved);
                        },
                        child: SizedBox(
                          width:
                              math.min(MediaQuery.sizeOf(ctx).width - 48, 520),
                          height: 100,
                          child: ColoredBox(
                            color: cs.surfaceContainerHighest,
                            child: pickedBannerPath == null
                                ? Center(
                                    child: Text(
                                      'Нажмите, чтобы выбрать баннер',
                                      style:
                                          TextStyle(color: cs.onSurfaceVariant),
                                    ),
                                  )
                                : Builder(builder: (_) {
                                    final bp = ImageService.instance
                                        .resolveStoredPath(pickedBannerPath);
                                    if (bp != null && File(bp).existsSync()) {
                                      return Image.file(
                                        File(bp),
                                        fit: BoxFit.cover,
                                        width: math.min(
                                            MediaQuery.sizeOf(ctx).width - 48,
                                            520),
                                        height: 100,
                                        errorBuilder: (_, __, ___) => Center(
                                          child: Icon(
                                            Icons.broken_image_outlined,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      );
                                    }
                                    return Center(
                                      child: Icon(
                                          Icons.add_photo_alternate_outlined,
                                          color: cs.onSurfaceVariant),
                                    );
                                  }),
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () =>
                            setDialogState(() => pickedBannerPath = null),
                        child: const Text('Убрать баннер'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: nameCtrl,
                      maxLength: 30,
                      autofocus: false,
                      decoration: const InputDecoration(
                        labelText: 'Название канала',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.drive_file_rename_outline),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descCtrl,
                      maxLength: 200,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Описание',
                        hintText: 'Краткое описание канала...',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.info_outline),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: emojiCtrl,
                      maxLength: 2,
                      decoration: const InputDecoration(
                        labelText: 'Эмодзи',
                        hintText: '📢',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.emoji_emotions_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Color palette
                    Text('Цвет канала',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _accentColors.map((c) {
                        final sel = c == pickedColor;
                        return GestureDetector(
                          onTap: () => setDialogState(() => pickedColor = c),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: sel
                                  ? Border.all(color: cs.onSurface, width: 2.5)
                                  : null,
                            ),
                            child: sel
                                ? const Icon(Icons.check,
                                    color: Colors.white, size: 16)
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    // Toggles
                    SwitchListTile(
                      value: commentsEnabled,
                      onChanged: (v) =>
                          setDialogState(() => commentsEnabled = v),
                      title: const Text('Комментарии'),
                      subtitle: const Text(
                          'Подписчики могут комментировать посты',
                          style: TextStyle(fontSize: 12)),
                      secondary: const Icon(Icons.comment_outlined),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    SwitchListTile(
                      value: isPublic,
                      onChanged: (v) => setDialogState(() => isPublic = v),
                      title: const Text('Публичный канал'),
                      subtitle: Text(
                          isPublic
                              ? 'Найдётся в поиске'
                              : 'Скрытый — только по прямой ссылке',
                          style: const TextStyle(fontSize: 12)),
                      secondary:
                          Icon(isPublic ? Icons.public : Icons.lock_outline),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    const SizedBox(height: 4),
                    // Manage subscribers link
                    ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: const Text('Управление подписчиками'),
                      trailing: const Icon(Icons.chevron_right),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      onTap: () {
                        Navigator.pop(ctx);
                        _manageSubscribers();
                      },
                    ),
                    // Manage moderators link
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: const Text('Редакторы канала'),
                      trailing: const Icon(Icons.chevron_right),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      onTap: () {
                        Navigator.pop(ctx);
                        _manageModerators();
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена')),
              FilledButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final prevAvatar = _channel.avatarImagePath;
                  final prevBanner = _channel.bannerImagePath;
                  final updated = _channel.copyWith(
                    name: name,
                    description: descCtrl.text.trim().isEmpty
                        ? null
                        : descCtrl.text.trim(),
                    avatarEmoji: emojiCtrl.text.trim().isEmpty
                        ? _channel.avatarEmoji
                        : emojiCtrl.text.trim(),
                    avatarImagePath: pickedImagePath,
                    bannerImagePath: pickedBannerPath,
                    avatarColor: pickedColor,
                    commentsEnabled: commentsEnabled,
                    isPublic: isPublic,
                  );
                  await ChannelService.instance.updateChannel(updated);
                  if (!mounted) return;
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  setState(() => _channel = updated);
                  _load();
                  unawaited(GossipRouter.instance.broadcastChannelMeta(
                    channelId: updated.id,
                    name: updated.name,
                    adminId: updated.adminId,
                    avatarColor: updated.avatarColor,
                    avatarEmoji: updated.avatarEmoji,
                    description: updated.description,
                    commentsEnabled: updated.commentsEnabled,
                    createdAt: updated.createdAt,
                    verified: updated.verified,
                    verifiedBy: updated.verifiedBy,
                    subscriberIds: updated.subscriberIds,
                    moderatorIds: updated.moderatorIds,
                    username: updated.username,
                    universalCode: updated.universalCode,
                    isPublic: updated.isPublic,
                  ));
                  unawaited(_syncChannelVisualsAfterEdit(
                    updated: updated,
                    prevAvatarPath: prevAvatar,
                    prevBannerPath: prevBanner,
                  ));
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Delete channel (admin only) ────────────────────────────

  Future<void> _deleteChannel() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить канал?'),
        content: const Text('Канал и все посты будут удалены навсегда.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await ChannelService.instance.deleteChannel(_channel.id);
    if (mounted) Navigator.pop(context);
  }

  // ── Manage subscribers (kick) ───────────────────────────────

  void _manageSubscribers() {
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
          final current = _channel.subscriberIds
              .where((id) => id != _channel.adminId && id != _myId)
              .toList();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Подписчики канала',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (current.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx2).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: current.length,
                      itemBuilder: (_, i) {
                        final uid = current[i];
                        final isMod = _channel.moderatorIds.contains(uid);
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
                              await ChannelService.instance
                                  .removeSubscriber(_channel.id, uid);
                              final ch = await ChannelService.instance
                                  .getChannel(_channel.id);
                              if (ch != null && mounted) {
                                setState(() => _channel = ch);
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

  // ── Subscribe / Unsubscribe ─────────────────────────────────

  Future<void> _toggleSubscribe() async {
    final wasSubscribed = _isSubscribed;
    if (wasSubscribed) {
      // Broadcast unsubscribe first (while we still have channel data)
      unawaited(GossipRouter.instance.broadcastChannelSubscribe(
        channelId: _channel.id,
        userId: _myId,
        unsubscribe: true,
      ));
      // Remove channel completely from local DB and pop back
      await ChannelService.instance.deleteChannel(_channel.id);
      if (mounted) Navigator.pop(context);
    } else {
      await ChannelService.instance.subscribe(_channel.id, _myId);
      unawaited(GossipRouter.instance.broadcastChannelSubscribe(
        channelId: _channel.id,
        userId: _myId,
      ));
      // Запрашиваем историю канала у админа — он (или старый подписчик)
      // пришлёт накопившиеся посты через gossip.
      final lastPost = await ChannelService.instance.getLastPost(_channel.id);
      unawaited(GossipRouter.instance.sendChannelHistoryRequest(
        channelId: _channel.id,
        requesterId: _myId,
        adminId: _channel.adminId,
        sinceTs: lastPost?.timestamp ?? 0,
      ));
      _load();
    }
  }

  void _inviteSubscriber() {
    final contacts = ChatStorageService.instance.contactsNotifier.value;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет контактов для приглашения')),
      );
      return;
    }
    // Filter out already subscribed
    final available = contacts
        .where((c) => !_channel.subscriberIds.contains(c.publicKeyHex))
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Все контакты уже подписаны')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Пригласить в канал',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ...available.map((c) => ListTile(
                  leading: AvatarWidget(
                    initials: c.nickname.isNotEmpty
                        ? c.nickname[0].toUpperCase()
                        : '?',
                    color: c.avatarColor,
                    emoji: c.avatarEmoji,
                    imagePath: c.avatarImagePath,
                    size: 40,
                  ),
                  title: Text(c.nickname),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final myProfile = ProfileService.instance.profile;
                    // Send directed channel invite
                    await GossipRouter.instance.sendChannelInvite(
                      channelId: _channel.id,
                      channelName: _channel.name,
                      adminId: _channel.adminId,
                      inviterId: CryptoService.instance.publicKeyHex,
                      inviterNick: myProfile?.nickname ?? '',
                      targetPublicKey: c.publicKeyHex,
                      avatarColor: _channel.avatarColor,
                      avatarEmoji: _channel.avatarEmoji,
                      description: _channel.description,
                      createdAt: _channel.createdAt,
                    );
                    // Also broadcast updated meta
                    await GossipRouter.instance.broadcastChannelMeta(
                      channelId: _channel.id,
                      name: _channel.name,
                      adminId: _channel.adminId,
                      avatarColor: _channel.avatarColor,
                      avatarEmoji: _channel.avatarEmoji,
                      description: _channel.description,
                      commentsEnabled: _channel.commentsEnabled,
                      createdAt: _channel.createdAt,
                      verified: _channel.verified,
                      verifiedBy: _channel.verifiedBy,
                      moderatorIds: _channel.moderatorIds,
                    );
                    _load();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('${c.nickname} приглашён в канал')),
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

  // ── Moderator management ─────────────────────────────────────

  void _manageModerators() {
    final subscribers =
        _channel.subscriberIds.where((id) => id != _channel.adminId).toList();
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
          final mods = _channel.moderatorIds;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Модераторы канала',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (subscribers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков для назначения',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx2).size.height * 0.5,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: subscribers.length,
                      itemBuilder: (_, i) {
                        final uid = subscribers[i];
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
                            final updated = await ChannelService.instance
                                .setModerator(_channel.id, uid, val);
                            if (updated != null && mounted) {
                              setState(() => _channel = updated);
                              setModal(() {});
                              // Broadcast updated meta so other devices sync
                              unawaited(
                                  GossipRouter.instance.broadcastChannelMeta(
                                channelId: _channel.id,
                                name: _channel.name,
                                adminId: _channel.adminId,
                                avatarColor: _channel.avatarColor,
                                avatarEmoji: _channel.avatarEmoji,
                                description: _channel.description,
                                commentsEnabled: _channel.commentsEnabled,
                                createdAt: _channel.createdAt,
                                verified: _channel.verified,
                                verifiedBy: _channel.verifiedBy,
                                moderatorIds: updated.moderatorIds,
                              ));
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

  // ── Helpers ─────────────────────────────────────────────────

  String _nickFor(String id) {
    if (id == _myId) return 'Вы';
    final contact = ChatStorageService.instance.contactsNotifier.value
        .where((c) => c.publicKeyHex == id)
        .firstOrNull;
    return contact?.nickname ?? '${id.substring(0, 8)}...';
  }

  // ── Build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ChannelProfileScreen(channelId: _channel.id),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                      child: Text(_channel.name,
                          style: const TextStyle(fontSize: 16),
                          overflow: TextOverflow.ellipsis)),
                  if (_channel.verified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified, size: 16, color: Colors.blue),
                  ],
                ],
              ),
              Text('${_channel.subscriberIds.length} подписчиков',
                  style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.5))),
            ],
          ),
        ),
        actions: [
          // Subscribe / Unsubscribe for non-admins
          if (!_isAdmin)
            TextButton.icon(
              onPressed: _toggleSubscribe,
              icon: Icon(
                _isSubscribed
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_outlined,
                size: 18,
              ),
              label: Text(
                _isSubscribed ? 'Отписаться' : 'Подписаться',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: 'Пригласить',
              onPressed: _inviteSubscriber,
            ),
          if (_isAdmin || _isModerator)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _editChannel();
                if (v == 'comments') _toggleComments();
                if (v == 'verify') _requestVerification();
                if (v == 'mods') _manageModerators();
                if (v == 'subscribers') _manageSubscribers();
                if (v == 'delete') _deleteChannel();
              },
              itemBuilder: (_) => [
                if (_isAdmin || _isModerator)
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(children: [
                      Icon(Icons.edit_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Редактировать'),
                    ]),
                  ),
                if (_isAdmin || _isModerator)
                  const PopupMenuItem(
                    value: 'subscribers',
                    child: Row(children: [
                      Icon(Icons.people_outline, size: 18),
                      SizedBox(width: 8),
                      Text('Подписчики'),
                    ]),
                  ),
                if (_isAdmin)
                  PopupMenuItem(
                    value: 'comments',
                    child: Row(children: [
                      Icon(
                        _channel.commentsEnabled
                            ? Icons.comments_disabled_outlined
                            : Icons.comment_outlined,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(_channel.commentsEnabled
                          ? 'Выключить комментарии'
                          : 'Включить комментарии'),
                    ]),
                  ),
                if (_isAdmin)
                  const PopupMenuItem(
                    value: 'mods',
                    child: Row(children: [
                      Icon(Icons.manage_accounts_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Модераторы'),
                    ]),
                  ),
                if (_isAdmin && !_channel.verified)
                  const PopupMenuItem(
                    value: 'verify',
                    child: Row(children: [
                      Icon(Icons.verified_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Подать на верификацию'),
                    ]),
                  ),
                if (_isAdmin)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline, size: 18, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Удалить канал',
                          style: TextStyle(color: Colors.red)),
                    ]),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (_channel.foreignAgent)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.orange.withValues(alpha: 0.15),
              child: const Text(
                'ДАННОЕ СООБЩЕНИЕ (МАТЕРИАЛ) СОЗДАНО И (ИЛИ) РАСПРОСТРАНЕНО ИНОСТРАННЫМ АГЕНТОМ',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Colors.orange,
                ),
              ),
            ),
          if (_channel.blocked)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.withValues(alpha: 0.15),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.block, size: 16, color: Colors.red),
                  SizedBox(width: 6),
                  Text(
                    'Канал заблокирован администратором сети',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          if (_channel.description != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
              child: Text(_channel.description!,
                  style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6))),
            ),
          Expanded(
            child: _posts.isEmpty
                ? Center(
                    child: Text('Нет постов',
                        style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.3))))
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      ListView.builder(
                        controller: _feedScrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _posts.length,
                        itemBuilder: (_, i) => RepaintBoundary(
                          child: _PostCard(
                            post: _posts[i],
                            isAdmin: _isAdmin,
                            commentsEnabled: _channel.commentsEnabled,
                            nickFor: _nickFor,
                            onDelete: _channel.canPost(_myId)
                                ? () => _deletePost(_posts[i].id)
                                : null,
                            channelId: _channel.id,
                            channelName: _channel.name,
                            channelAdminId: _channel.adminId,
                          ),
                        ),
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
                              onTap: _scrollFeedToBottom,
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
          // Post input bar for admin + moderators (hidden if channel blocked)
          if (_channel.canPost(_myId) && !_channel.blocked)
            _ChannelInputBar(
              controller: _postCtrl,
              isSending: _isSending,
              sendProgress: _sendProgress,
              isRecording: _isRecording,
              recordingSecondsNotifier: _recordingSecondsNotifier,
              onSend: _createPost,
              onPickImage: _pickAndSendImage,
              onPickVideo: _pickAndSendVideo,
              onPickFile: _pickAndSendFile,
              onCreatePoll: _createPollPost,
              onMicDown: _startVoiceRecording,
              onMicUp: _stopAndSendVoice,
              onMentionPicker: _openMentionPickerForPost,
            ),
        ],
      ),
    );
  }
}

// ── Image quality helper ────────────────────────────────────────

class _ImageQuality {
  final int quality;
  final int maxSize;
  const _ImageQuality({required this.quality, required this.maxSize});
}

// ══════════════════════════════════════════════════════════════════
// Channel Input Bar — admin post bar with full media support
// ══════════════════════════════════════════════════════════════════

class _ChannelInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final double sendProgress;
  final bool isRecording;
  final ValueNotifier<double> recordingSecondsNotifier;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onPickVideo;
  final VoidCallback onPickFile;
  final VoidCallback onCreatePoll;
  final VoidCallback onMicDown;
  final VoidCallback onMicUp;
  final VoidCallback? onMentionPicker;

  const _ChannelInputBar({
    required this.controller,
    required this.isSending,
    this.sendProgress = 0.0,
    required this.isRecording,
    required this.recordingSecondsNotifier,
    required this.onSend,
    required this.onPickImage,
    required this.onPickVideo,
    required this.onPickFile,
    required this.onCreatePoll,
    required this.onMicDown,
    required this.onMicUp,
    this.onMentionPicker,
  });

  @override
  State<_ChannelInputBar> createState() => _ChannelInputBarState();
}

class _ChannelInputBarState extends State<_ChannelInputBar> {
  bool _hasText = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) {
      setState(() => _hasText = has);
    }
  }

  void _wrapSelection(String prefix, String suffix) {
    final sel = widget.controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final text = widget.controller.text;
    final selected = text.substring(sel.start, sel.end);
    final newText =
        text.replaceRange(sel.start, sel.end, '$prefix$selected$suffix');
    final newOffset = sel.end + prefix.length + suffix.length;
    widget.controller.value = widget.controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  Future<void> _attachLinkToSelection() async {
    final sel = widget.controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final fullText = widget.controller.text;
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
    widget.controller.value = widget.controller.value.copyWith(
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
          unawaited(_attachLinkToSelection());
        },
      ),
    ];

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surface,
          border:
              Border(top: BorderSide(color: cs.outline.withValues(alpha: 0.3))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Send progress bar
            if (widget.isSending && widget.sendProgress > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: widget.sendProgress,
                    minHeight: 3,
                    backgroundColor: cs.outline.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                  ),
                ),
              ),
            Row(children: [
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (widget.isSending) return;
                  switch (value) {
                    case 'photo':
                      widget.onPickImage();
                      break;
                    case 'video':
                      widget.onPickVideo();
                      break;
                    case 'file':
                      widget.onPickFile();
                      break;
                    case 'poll':
                      widget.onCreatePoll();
                      break;
                  }
                },
                icon: Icon(Icons.add_rounded,
                    color: cs.onSurfaceVariant, size: 26),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: 'Прикрепить',
                position: PopupMenuPosition.over,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'photo',
                    child: Row(children: [
                      Icon(Icons.photo_library_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Фото'),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'video',
                    child: Row(children: [
                      Icon(Icons.video_library_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Видео'),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'file',
                    child: Row(children: [
                      Icon(Icons.attach_file_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Файл'),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'poll',
                    child: Row(children: [
                      Icon(Icons.poll_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Опрос'),
                    ]),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: ValueListenableBuilder<double>(
                    valueListenable: widget.recordingSecondsNotifier,
                    builder: (_, secs, __) {
                      final s = secs.floor();
                      final t = ((secs % 1) * 10).floor();
                      return TextField(
                        controller: widget.controller,
                        focusNode: _focusNode,
                        onTapOutside: (_) => _focusNode.unfocus(),
                        enabled: !widget.isRecording,
                        contextMenuBuilder: _buildContextMenu,
                        maxLines: 4,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: widget.isRecording
                              ? 'Запись... ${s}s.$t'
                              : 'Новый пост...',
                          hintStyle: TextStyle(
                              color:
                                  cs.onSurfaceVariant.withValues(alpha: 0.6)),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (widget.onMentionPicker != null)
                IconButton(
                  onPressed: widget.isSending || widget.isRecording
                      ? null
                      : widget.onMentionPicker,
                  icon: Icon(Icons.alternate_email_rounded,
                      color: cs.onSurfaceVariant, size: 22),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'Отметить человека',
                ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap:
                    widget.isRecording ? widget.onMicUp : widget.onMicDown,
                onLongPressStart: (_) {
                  if (!widget.isRecording) widget.onMicDown();
                },
                onLongPressEnd: (_) {
                  if (widget.isRecording) widget.onMicUp();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: widget.isRecording
                        ? Colors.redAccent
                        : cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.isRecording
                        ? Icons.stop_rounded
                        : Icons.mic_rounded,
                    color: cs.onPrimary,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_hasText || widget.isSending)
                GestureDetector(
                  onTap: widget.isSending || widget.isRecording
                      ? null
                      : widget.onSend,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: (widget.isSending || widget.isRecording)
                          ? cs.onSurface.withValues(alpha: 0.3)
                          : cs.primary,
                      shape: BoxShape.circle,
                    ),
                    child: widget.isSending
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                                value: widget.sendProgress > 0
                                    ? widget.sendProgress
                                    : null,
                                strokeWidth: 2,
                                color: cs.onPrimary))
                        : Icon(Icons.send_rounded,
                            color: cs.onPrimary, size: 20),
                  ),
                )
              else
                GestureDetector(
                  onTap: widget.isSending ? null : widget.onPickVideo,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: widget.isSending
                          ? cs.onSurface.withValues(alpha: 0.3)
                          : cs.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.video_library_rounded,
                        color: cs.onPrimary, size: 22),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Post card — shows a single post with comment icon
// ══════════════════════════════════════════════════════════════════

class _PostCard extends StatelessWidget {
  final ChannelPost post;
  final bool isAdmin;
  final bool commentsEnabled;
  final String Function(String) nickFor;
  final VoidCallback? onDelete;
  final String channelId;
  final String channelName;
  final String channelAdminId;

  const _PostCard({
    required this.post,
    required this.isAdmin,
    required this.commentsEnabled,
    required this.nickFor,
    this.onDelete,
    required this.channelId,
    this.channelName = '',
    required this.channelAdminId,
  });

  Future<void> _togglePostReaction(BuildContext context, String emoji) async {
    final myId = CryptoService.instance.publicKeyHex;
    await ChannelService.instance.togglePostReaction(post.id, emoji, myId);
    await BroadcastOutboxService.instance.enqueueReactionExt(
      kind: 'channel_post',
      targetId: post.id,
      emoji: emoji,
      fromId: myId,
    );
  }

  Future<void> _openReactionPicker(BuildContext context) async {
    final emoji = await showReactionPickerSheet(context);
    if (emoji == null) return;
    if (!context.mounted) return;
    await _togglePostReaction(context, emoji);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dt = DateTime.fromMillisecondsSinceEpoch(post.timestamp);
    final myId = CryptoService.instance.publicKeyHex;
    final missing = channelPostMissingLocalMedia(post);
    // Show channel name as sender (like Telegram). In parentheses show author only
    // if it's a moderator posting (not admin), so admins know who posted.
    final senderLabel =
        channelName.isNotEmpty ? channelName : nickFor(post.authorId);

    return GestureDetector(
      onLongPress: () async {
        final action = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.emoji_emotions_outlined),
                  title: const Text('Реакция…'),
                  onTap: () => Navigator.pop(ctx, 'react'),
                ),
                ListTile(
                  leading: const Icon(Icons.forward),
                  title: const Text('Переслать…'),
                  onTap: () => Navigator.pop(ctx, 'fwd'),
                ),
                if (post.text.trim().isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.copy),
                    title: const Text('Копировать текст'),
                    onTap: () => Navigator.pop(ctx, 'copy'),
                  ),
              ],
            ),
          ),
        );
        if (!context.mounted) return;
        if (action == 'react') {
          await _openReactionPicker(context);
        } else if (action == 'fwd') {
          final msg = _channelPostToForwardMessage(post, channelId);
          final authorNick = nickFor(post.authorId);
          final label = channelName.isNotEmpty
              ? '$channelName · $authorNick'
              : 'Канал · $authorNick';
          await _pickForwardChannelContent(
            context,
            forwardMessage: msg,
            forwardAuthorId: post.authorId,
            originalAuthorNick: label,
          );
        } else if (action == 'copy') {
          await Clipboard.setData(ClipboardData(text: post.text));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Текст скопирован')),
            );
          }
        }
      },
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header — shows channel name as the author (Telegram-style)
              Row(children: [
                Text(senderLabel,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.primary)),
                const Spacer(),
                Text(
                  '${dt.day}.${dt.month.toString().padLeft(2, '0')} '
                  '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4)),
                ),
                if (onDelete != null)
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 16, color: Colors.red.shade300),
                    onPressed: onDelete,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ]),
              const SizedBox(height: 6),
              if (missing)
                ClearedMediaPlaceholder(
                  isOutgoing: false,
                  isDirectChat: false,
                  colorScheme: cs,
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Откройте канал при подключении к сети — '
                          'запросится история и вложения.',
                        ),
                      ),
                    );
                  },
                ),
              // Image
              if (!missing && post.imagePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Builder(builder: (context) {
                      final p = ImageService.instance
                          .resolveStoredPath(post.imagePath);
                      if (p == null) return const SizedBox.shrink();
                      return ChannelFeedImage(resolvedPath: p);
                    }),
                  ),
                ),
              if (!missing && post.videoPath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ChannelSquareVideoTile(storedPath: post.videoPath!),
                ),
              if (!missing && post.voicePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ChannelVoiceRow(storedPath: post.voicePath!),
                ),
              if (!missing && post.filePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ChannelFileAttachRow(
                    storedPath: post.filePath!,
                    fileName: post.fileName ?? 'Файл',
                    fileSize: post.fileSize,
                  ),
                ),
              // Text
              if (post.text.isNotEmpty &&
                  !(missing && isSyntheticMediaCaption(post.text)))
                ValueListenableBuilder<List<Contact>>(
                  valueListenable: ChatStorageService.instance.contactsNotifier,
                  builder: (_, contacts, __) {
                    return RichMessageText(
                      text: post.text,
                      textColor: cs.onSurface,
                      isOut: false,
                      mentionLabelFor: (hex) => resolveChannelMentionDisplay(
                        hex,
                        contacts,
                        ProfileService.instance.profile,
                      ),
                    );
                  },
                ),
              if (MessagePoll.tryDecode(post.pollJson) case final poll?)
                PollMessageCard(
                  targetId: post.id,
                  kind: 'channel_post',
                  poll: poll,
                  cs: cs,
                  isOutgoing: false,
                  compact: true,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final e in kQuickReactionEmojis)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: InkWell(
                            onTap: () => _togglePostReaction(context, e),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 3),
                              child: Text(e,
                                  style: const TextStyle(fontSize: 18)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (post.reactions.isNotEmpty) ...[
                ReactionsBar(
                  reactions: post.reactions,
                  myId: myId,
                  onTap: (e) => _togglePostReaction(context, e),
                  compact: true,
                ),
                const SizedBox(height: 6),
              ],
              Row(children: [
                // React button
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _openReactionPicker(context),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(children: [
                      Icon(Icons.add_reaction_outlined,
                          size: 14,
                          color: cs.onSurface.withValues(alpha: 0.55)),
                      const SizedBox(width: 4),
                      Text('Реакция',
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.5))),
                    ]),
                  ),
                ),
                const SizedBox(width: 12),
                // Comments button — navigates to PostCommentsScreen
                if (commentsEnabled)
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PostCommentsScreen(
                              post: post,
                              channelId: channelId,
                              channelName: channelName,
                              channelAdminId: channelAdminId,
                              nickFor: nickFor,
                            ),
                          ),
                        );
                      },
                      child: Row(children: [
                        Icon(Icons.comment_outlined,
                            size: 14,
                            color: cs.onSurface.withValues(alpha: 0.4)),
                        const SizedBox(width: 4),
                        Text(
                          post.comments.isEmpty
                              ? 'Комментировать'
                              : '${post.comments.length} комментариев',
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.5)),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right,
                            size: 14,
                            color: cs.onSurface.withValues(alpha: 0.3)),
                      ]),
                    ),
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 3. PostCommentsScreen — separate screen for post discussion
// ══════════════════════════════════════════════════════════════════

class PostCommentsScreen extends StatefulWidget {
  final ChannelPost post;
  final String channelId;
  final String channelName;
  final String channelAdminId;
  final String Function(String) nickFor;

  const PostCommentsScreen({
    super.key,
    required this.post,
    required this.channelId,
    this.channelName = '',
    required this.channelAdminId,
    required this.nickFor,
  });

  @override
  State<PostCommentsScreen> createState() => _PostCommentsScreenState();
}

class _PostCommentsScreenState extends State<PostCommentsScreen> {
  final _commentCtrl = TextEditingController();
  final _scrollController = ScrollController();
  final _commentImagePicker = ImagePicker();
  final _commentFocus = FocusNode();
  List<ChannelComment> _comments = [];
  String get _myId => CryptoService.instance.publicKeyHex;
  bool _isSendingComment = false;
  double _commentSendProgress = 0;
  bool _isRecordingComment = false;
  Timer? _commentRecordingTimer;
  final _commentRecordingSeconds = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _comments = List.from(widget.post.comments);
    _loadComments();
    ChannelService.instance.version.addListener(_loadComments);
  }

  @override
  void dispose() {
    ChannelService.instance.version.removeListener(_loadComments);
    _commentRecordingTimer?.cancel();
    _commentRecordingSeconds.dispose();
    _commentCtrl.dispose();
    _commentFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _loadComments() async {
    final comments = await ChannelService.instance.getComments(widget.post.id);
    if (mounted) setState(() => _comments = comments);
  }

  Future<void> _openMentionPickerForComment() async {
    await _showContactMentionPicker(context, (hex) {
      insertChannelMentionToken(_commentCtrl, hex);
      if (mounted) setState(() {});
    });
  }

  Future<_ImageQuality?> _commentPickImageQuality() async {
    return showModalBottomSheet<_ImageQuality>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Качество фото',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.flash_on, color: Colors.green),
              title: const Text('Быстрое'),
              subtitle: const Text('160px, маленький размер'),
              onTap: () => Navigator.pop(
                  ctx, const _ImageQuality(quality: 40, maxSize: 160)),
            ),
            ListTile(
              leading: const Icon(Icons.tune, color: Colors.orange),
              title: const Text('Стандарт'),
              subtitle: const Text('320px, баланс скорость/качество'),
              onTap: () => Navigator.pop(
                  ctx, const _ImageQuality(quality: 55, maxSize: 320)),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality, color: Colors.blue),
              title: const Text('Высокое'),
              subtitle: const Text('640px, дольше передача'),
              onTap: () => Navigator.pop(
                  ctx, const _ImageQuality(quality: 70, maxSize: 640)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _runCommentChunks({
    required String commentId,
    required List<String> chunks,
    bool isVideo = false,
    bool isSquare = false,
    bool isVoice = false,
    bool isFile = false,
    String? fileName,
  }) async {
    await GossipRouter.instance.sendImgMeta(
      msgId: commentId,
      totalChunks: chunks.length,
      fromId: _myId,
      isAvatar: false,
      isVideo: isVideo,
      isSquare: isSquare,
      isVoice: isVoice,
      isFile: isFile,
      fileName: fileName,
    );
    for (var i = 0; i < chunks.length; i++) {
      await GossipRouter.instance.sendImgChunk(
        msgId: commentId,
        index: i,
        base64Data: chunks[i],
        fromId: _myId,
      );
      if (mounted) {
        setState(() => _commentSendProgress = (i + 1) / chunks.length);
      }
    }
  }

  Future<void> _sendCommentImage() async {
    if (_isSendingComment) return;
    final picked =
        await _commentImagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final editedBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
          builder: (_) => ImageEditorScreen(imagePath: picked.path)),
    );
    if (editedBytes == null || !mounted) return;
    final quality = await _commentPickImageQuality();
    if (quality == null || !mounted) return;

    setState(() {
      _isSendingComment = true;
      _commentSendProgress = 0;
    });
    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
          '${tmpDir.path}/chc_edit_${DateTime.now().millisecondsSinceEpoch}.png');
      await tmpFile.writeAsBytes(editedBytes);
      final path = await ImageService.instance.compressAndSave(
        tmpFile.path,
        quality: quality.quality,
        maxSize: quality.maxSize,
      );
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final commentId = const Uuid().v4();
      await _runCommentChunks(commentId: commentId, chunks: chunks);

      final caption = _commentCtrl.text.trim();
      final textForDb = caption.isEmpty ? ' ' : caption;
      final comment = ChannelComment(
        id: commentId,
        postId: widget.post.id,
        authorId: _myId,
        text: textForDb,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: path,
      );
      await ChannelService.instance.saveComment(comment);
      await ChannelService.instance.flushPendingMediaForComment(commentId);
      await BroadcastOutboxService.instance.enqueueChannelComment(
        postId: widget.post.id,
        commentId: commentId,
        authorId: _myId,
        text: textForDb,
        timestamp: comment.timestamp,
        hasImage: true,
      );
      _commentCtrl.clear();
      _loadComments();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка фото: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingComment = false;
          _commentSendProgress = 0;
        });
      }
    }
  }

  Future<void> _sendCommentVideo() async {
    if (_isSendingComment) return;
    final picked =
        await _commentImagePicker.pickVideo(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    setState(() {
      _isSendingComment = true;
      _commentSendProgress = 0;
    });
    try {
      final path =
          await ImageService.instance.saveVideo(picked.path, isSquare: false);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final commentId = const Uuid().v4();
      await _runCommentChunks(
        commentId: commentId,
        chunks: chunks,
        isVideo: true,
        isSquare: false,
      );

      final caption = _commentCtrl.text.trim();
      final textForDb = caption.isEmpty ? ' ' : caption;
      final comment = ChannelComment(
        id: commentId,
        postId: widget.post.id,
        authorId: _myId,
        text: textForDb,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        videoPath: path,
      );
      await ChannelService.instance.saveComment(comment);
      await ChannelService.instance.flushPendingMediaForComment(commentId);
      await BroadcastOutboxService.instance.enqueueChannelComment(
        postId: widget.post.id,
        commentId: commentId,
        authorId: _myId,
        text: textForDb,
        timestamp: comment.timestamp,
        hasVideo: true,
      );
      _commentCtrl.clear();
      _loadComments();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingComment = false;
          _commentSendProgress = 0;
        });
      }
    }
  }

  Future<void> _sendCommentFile() async {
    if (_isSendingComment) return;
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
    final fileBytes = await File(srcPath).readAsBytes();
    if (!mounted) return;

    if (fileBytes.length > 500 * 1024) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Большой файл'),
          content: Text(
            'Файл ${(fileBytes.length / 1024).toStringAsFixed(0)} КБ — '
            'передача по Bluetooth займёт несколько минут. Продолжить?',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Отправить')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() {
      _isSendingComment = true;
      _commentSendProgress = 0;
    });
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files');
      if (!filesDir.existsSync()) filesDir.createSync(recursive: true);
      final destPath = '${filesDir.path}/$originalName';
      await File(srcPath).copy(destPath);

      final chunks = ImageService.instance.splitToBase64Chunks(fileBytes);
      final commentId = const Uuid().v4();
      await _runCommentChunks(
        commentId: commentId,
        chunks: chunks,
        isFile: true,
        fileName: originalName,
      );

      final caption = _commentCtrl.text.trim();
      final textForDb = caption.isEmpty ? '\u{1F4CE} $originalName' : caption;
      final comment = ChannelComment(
        id: commentId,
        postId: widget.post.id,
        authorId: _myId,
        text: textForDb,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        filePath: destPath,
        fileName: originalName,
        fileSize: fileBytes.length,
      );
      await ChannelService.instance.saveComment(comment);
      await ChannelService.instance.flushPendingMediaForComment(commentId);
      await BroadcastOutboxService.instance.enqueueChannelComment(
        postId: widget.post.id,
        commentId: commentId,
        authorId: _myId,
        text: textForDb,
        timestamp: comment.timestamp,
        hasFile: true,
        fileName: originalName,
      );
      _commentCtrl.clear();
      _loadComments();
      _scrollToBottom();
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
          _isSendingComment = false;
          _commentSendProgress = 0;
        });
      }
    }
  }

  Future<void> _commentMicDown() async {
    if (_isSendingComment || _isRecordingComment) return;
    final hasPerm = await VoiceService.instance.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нет доступа к микрофону — проверьте разрешения'),
          ),
        );
      }
      return;
    }
    final path = await VoiceService.instance.startRecording();
    if (path == null) return;
    _commentRecordingSeconds.value = 0;
    setState(() => _isRecordingComment = true);
    _commentRecordingTimer?.cancel();
    _commentRecordingTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_isRecordingComment) return;
      _commentRecordingSeconds.value += 0.25;
      if (_commentRecordingSeconds.value >= 60) {
        unawaited(_commentMicUp());
      }
    });
  }

  Future<void> _commentMicUp() async {
    if (!_isRecordingComment) return;
    _commentRecordingTimer?.cancel();
    _commentRecordingTimer = null;

    final path = await VoiceService.instance.stopRecording();
    final duration = _commentRecordingSeconds.value;
    _commentRecordingSeconds.value = 0;
    setState(() => _isRecordingComment = false);

    if (path == null || duration < 0.5) return;

    setState(() {
      _isSendingComment = true;
      _commentSendProgress = 0;
    });
    try {
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final commentId = const Uuid().v4();
      await _runCommentChunks(
        commentId: commentId,
        chunks: chunks,
        isVoice: true,
      );

      final caption = _commentCtrl.text.trim();
      final textForDb = caption.isEmpty ? '\u{1F3A4} Голосовое' : caption;
      final comment = ChannelComment(
        id: commentId,
        postId: widget.post.id,
        authorId: _myId,
        text: textForDb,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        voicePath: path,
      );
      await ChannelService.instance.saveComment(comment);
      await ChannelService.instance.flushPendingMediaForComment(commentId);
      await BroadcastOutboxService.instance.enqueueChannelComment(
        postId: widget.post.id,
        commentId: commentId,
        authorId: _myId,
        text: textForDb,
        timestamp: comment.timestamp,
        hasVoice: true,
      );
      _commentCtrl.clear();
      _loadComments();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка голосового: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingComment = false;
          _commentSendProgress = 0;
        });
      }
    }
  }

  Future<void> _addComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    _commentCtrl.clear();

    final commentId = const Uuid().v4();
    final comment = ChannelComment(
      id: commentId,
      postId: widget.post.id,
      authorId: _myId,
      text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await ChannelService.instance.saveComment(comment);

    await BroadcastOutboxService.instance.enqueueChannelComment(
      postId: widget.post.id,
      commentId: commentId,
      authorId: _myId,
      text: text,
      timestamp: comment.timestamp,
    );

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _confirmDeleteComment(ChannelComment c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить комментарий?'),
        content: const Text('У всех подписчиков он исчезнет.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ChannelService.instance.deleteCommentById(c.id);
    await GossipRouter.instance.sendChannelCommentDelete(
      channelId: widget.channelId,
      postId: widget.post.id,
      commentId: c.id,
      byUserId: _myId,
    );
    _loadComments();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final postDt = DateTime.fromMillisecondsSinceEpoch(widget.post.timestamp);
    final postMissing = channelPostMissingLocalMedia(widget.post);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Обсуждение'),
      ),
      body: Column(
        children: [
          // ── Original post card at the top ──
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(widget.nickFor(widget.post.authorId),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.primary)),
                  const Spacer(),
                  Text(
                    '${postDt.day}.${postDt.month.toString().padLeft(2, '0')} '
                    '${postDt.hour.toString().padLeft(2, '0')}:${postDt.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.4)),
                  ),
                ]),
                const SizedBox(height: 6),
                if (postMissing)
                  ClearedMediaPlaceholder(
                    isOutgoing: false,
                    isDirectChat: false,
                    colorScheme: cs,
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Откройте канал при подключении к сети — '
                            'запросится история и вложения.',
                          ),
                        ),
                      );
                    },
                  ),
                if (!postMissing && widget.post.imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Builder(builder: (_) {
                        final p = ImageService.instance
                            .resolveStoredPath(widget.post.imagePath);
                        if (p == null) return const SizedBox.shrink();
                        return ChannelFeedImage(resolvedPath: p);
                      }),
                    ),
                  ),
                if (!postMissing && widget.post.videoPath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ChannelSquareVideoTile(
                      storedPath: widget.post.videoPath!,
                      size: 140,
                    ),
                  ),
                if (!postMissing && widget.post.voicePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ChannelVoiceRow(storedPath: widget.post.voicePath!),
                  ),
                if (!postMissing && widget.post.filePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ChannelFileAttachRow(
                      storedPath: widget.post.filePath!,
                      fileName: widget.post.fileName ?? 'Файл',
                      fileSize: widget.post.fileSize,
                    ),
                  ),
                if (widget.post.text.trim().isNotEmpty &&
                    !(postMissing &&
                        isSyntheticMediaCaption(widget.post.text)))
                  ValueListenableBuilder<List<Contact>>(
                    valueListenable:
                        ChatStorageService.instance.contactsNotifier,
                    builder: (_, contacts, __) {
                      return RichMessageText(
                        text: widget.post.text,
                        textColor: cs.onSurface,
                        isOut: false,
                        mentionLabelFor: (hex) => resolveChannelMentionDisplay(
                          hex,
                          contacts,
                          ProfileService.instance.profile,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),

          // ── Divider ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Icon(Icons.chat_bubble_outline,
                  size: 14, color: cs.onSurface.withValues(alpha: 0.4)),
              const SizedBox(width: 6),
              Text(
                _comments.isEmpty
                    ? 'Нет комментариев'
                    : '${_comments.length} комментариев',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface.withValues(alpha: 0.5)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(color: cs.outline.withValues(alpha: 0.2)),
              ),
            ]),
          ),
          const SizedBox(height: 4),

          // ── Comments list (chat-like bubbles) ──
          Expanded(
            child: _comments.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.forum_outlined,
                            size: 48,
                            color: cs.onSurface.withValues(alpha: 0.2)),
                        const SizedBox(height: 8),
                        Text('Будьте первым!',
                            style: TextStyle(
                                fontSize: 14,
                                color: cs.onSurface.withValues(alpha: 0.3))),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    itemCount: _comments.length,
                    itemBuilder: (_, i) {
                      final c = _comments[i];
                      final isMe = c.authorId == _myId;
                      final cDt =
                          DateTime.fromMillisecondsSinceEpoch(c.timestamp);
                      return _CommentBubble(
                        comment: c,
                        nick: widget.nickFor(c.authorId),
                        text: c.text,
                        time:
                            '${cDt.hour.toString().padLeft(2, '0')}:${cDt.minute.toString().padLeft(2, '0')}',
                        isMe: isMe,
                        canDelete: isMe || _myId == widget.channelAdminId,
                        onDelete: () => _confirmDeleteComment(c),
                        channelId: widget.channelId,
                        channelName: widget.channelName,
                        nickFor: widget.nickFor,
                      );
                    },
                  ),
          ),

          // ── Comment input ──
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                    top: BorderSide(color: cs.outline.withValues(alpha: 0.3))),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isSendingComment)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: _commentSendProgress > 0
                              ? _commentSendProgress
                              : null,
                          minHeight: 3,
                          backgroundColor: cs.outline.withValues(alpha: 0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                        ),
                      ),
                    ),
                  Row(children: [
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (_isSendingComment || _isRecordingComment) return;
                        switch (value) {
                          case 'photo':
                            unawaited(_sendCommentImage());
                            break;
                          case 'video':
                            unawaited(_sendCommentVideo());
                            break;
                          case 'file':
                            unawaited(_sendCommentFile());
                            break;
                        }
                      },
                      icon: Icon(Icons.add_rounded,
                          color: cs.onSurfaceVariant, size: 26),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 36, minHeight: 36),
                      tooltip: 'Прикрепить',
                      position: PopupMenuPosition.over,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'photo',
                          child: Row(children: [
                            Icon(Icons.photo_library_outlined, size: 20),
                            SizedBox(width: 12),
                            Text('Фото'),
                          ]),
                        ),
                        const PopupMenuItem(
                          value: 'video',
                          child: Row(children: [
                            Icon(Icons.video_library_outlined, size: 20),
                            SizedBox(width: 12),
                            Text('Видео'),
                          ]),
                        ),
                        const PopupMenuItem(
                          value: 'file',
                          child: Row(children: [
                            Icon(Icons.attach_file_outlined, size: 20),
                            SizedBox(width: 12),
                            Text('Файл'),
                          ]),
                        ),
                      ],
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: ValueListenableBuilder<double>(
                          valueListenable: _commentRecordingSeconds,
                          builder: (_, secs, __) {
                            final s = secs.floor();
                            final t = ((secs % 1) * 10).floor();
                            return TextField(
                              controller: _commentCtrl,
                              focusNode: _commentFocus,
                              onTapOutside: (_) => _commentFocus.unfocus(),
                              enabled: !_isRecordingComment,
                              maxLines: 3,
                              minLines: 1,
                              textInputAction: TextInputAction.newline,
                              style: const TextStyle(fontSize: 15),
                              decoration: InputDecoration(
                                hintText: _isRecordingComment
                                    ? 'Запись... ${s}s.$t'
                                    : 'Комментарий...',
                                hintStyle: TextStyle(
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.6)),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                              ),
                              onSubmitted: (_) => _addComment(),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: _isSendingComment || _isRecordingComment
                          ? null
                          : _openMentionPickerForComment,
                      icon: Icon(Icons.alternate_email_rounded,
                          color: cs.onSurfaceVariant, size: 22),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                      tooltip: 'Отметить человека',
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: _isRecordingComment
                          ? () => unawaited(_commentMicUp())
                          : () => unawaited(_commentMicDown()),
                      onLongPressStart: (_) {
                        if (!_isRecordingComment) {
                          unawaited(_commentMicDown());
                        }
                      },
                      onLongPressEnd: (_) {
                        if (_isRecordingComment) {
                          unawaited(_commentMicUp());
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _isRecordingComment
                              ? Colors.redAccent
                              : cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isRecordingComment
                              ? Icons.stop_rounded
                              : Icons.mic_rounded,
                          color: cs.onPrimary,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _isSendingComment || _isRecordingComment
                          ? null
                          : _addComment,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _isSendingComment || _isRecordingComment
                              ? cs.onSurface.withValues(alpha: 0.3)
                              : cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: _isSendingComment
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: cs.onPrimary))
                            : Icon(Icons.send_rounded,
                                color: cs.onPrimary, size: 20),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Channel media helpers (posts / comments) ────────────────────

class _ChannelVoiceRow extends StatelessWidget {
  final String storedPath;

  const _ChannelVoiceRow({required this.storedPath});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final abs =
        ImageService.instance.resolveStoredPath(storedPath) ?? storedPath;
    if (!File(abs).existsSync()) return const SizedBox.shrink();
    final iconColor = cs.onSurface;
    final activeColor = cs.primary;
    final inactiveColor = cs.onSurface.withValues(alpha: 0.35);

    return ValueListenableBuilder<String?>(
      valueListenable: VoiceService.instance.currentlyPlaying,
      builder: (_, playing, __) {
        final isPlaying = playing == abs;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () async {
                try {
                  if (isPlaying) {
                    await VoiceService.instance.stop();
                  } else {
                    await VoiceService.instance.play(abs);
                  }
                } catch (e) {
                  debugPrint('[ChannelVoice] $e');
                }
              },
              icon: Icon(
                isPlaying
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                color: iconColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 4),
            ValueListenableBuilder<double>(
              valueListenable: VoiceService.instance.playProgress,
              builder: (_, progress, __) => SizedBox(
                width: 110,
                height: 28,
                child: CustomPaint(
                  painter: _ChannelWaveformPainter(
                    seed: abs.hashCode,
                    progress: isPlaying ? progress : 0,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChannelWaveformPainter extends CustomPainter {
  final int seed;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  _ChannelWaveformPainter({
    required this.seed,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const barCount = 28;
    final spacing = size.width / barCount;
    final barWidth = spacing * 0.55;
    final rng = math.Random(seed);
    final activePaint = Paint()..color = activeColor;
    final inactivePaint = Paint()..color = inactiveColor;
    final activeBar = (progress * barCount).floor();

    for (int i = 0; i < barCount; i++) {
      final heightFraction = 0.25 + rng.nextDouble() * 0.75;
      final h = heightFraction * size.height;
      final x = i * spacing + (spacing - barWidth) / 2;
      final paint = i <= activeBar ? activePaint : inactivePaint;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, barWidth, h),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ChannelWaveformPainter old) =>
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.seed != seed;
}

class _ChannelFileAttachRow extends StatelessWidget {
  final String storedPath;
  final String fileName;
  final int? fileSize;

  const _ChannelFileAttachRow({
    required this.storedPath,
    required this.fileName,
    this.fileSize,
  });

  String _fmtSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final abs =
        ImageService.instance.resolveStoredPath(storedPath) ?? storedPath;
    final exists = File(abs).existsSync();
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: exists
            ? () async {
                await OpenFilex.open(abs);
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(Icons.insert_drive_file_outlined, color: cs.primary, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface),
                  ),
                  if (fileSize != null)
                    Text(
                      _fmtSize(fileSize),
                      style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.5)),
                    ),
                ],
              ),
            ),
            Icon(Icons.open_in_new,
                size: 18, color: cs.onSurface.withValues(alpha: 0.45)),
          ]),
        ),
      ),
    );
  }
}

class _ChannelSquareVideoTile extends StatefulWidget {
  final String storedPath;
  final double size;

  const _ChannelSquareVideoTile({
    required this.storedPath,
    this.size = 160,
  });

  @override
  State<_ChannelSquareVideoTile> createState() =>
      _ChannelSquareVideoTileState();
}

class _ChannelSquareVideoTileState extends State<_ChannelSquareVideoTile> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _playing = false;

  String? get _abs {
    final r = ImageService.instance.resolveStoredPath(widget.storedPath);
    return (r != null && File(r).existsSync()) ? r : null;
  }

  @override
  void initState() {
    super.initState();
    final p = _abs;
    if (p != null) _init(p);
  }

  @override
  void didUpdateWidget(_ChannelSquareVideoTile oldWidget) {
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
      ctrl.setLooping(true);
      if (mounted) {
        setState(() {
          _ctrl = ctrl;
          _initialized = true;
        });
      } else {
        ctrl.dispose();
      }
    } catch (e) {
      debugPrint('[ChannelVideoTile] $e');
      ctrl.dispose();
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_ctrl == null || !_initialized) return;
    setState(() {
      if (_playing) {
        _ctrl!.pause();
        _playing = false;
      } else {
        _ctrl!.play();
        _playing = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _abs;
    if (p == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Icon(Icons.videocam_off_outlined,
              color: Colors.white38, size: 36),
        ),
      );
    }
    return GestureDetector(
      onTap: _togglePlay,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
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
                        color: Colors.white, size: 48),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Comment bubble widget ───────────────────────────────────────

class _CommentBubble extends StatelessWidget {
  final ChannelComment comment;
  final String nick;
  final String text;
  final String time;
  final bool isMe;
  final bool canDelete;
  final VoidCallback onDelete;
  final String channelId;
  final String channelName;
  final String Function(String) nickFor;

  const _CommentBubble({
    required this.comment,
    required this.nick,
    required this.text,
    required this.time,
    required this.isMe,
    required this.canDelete,
    required this.onDelete,
    required this.channelId,
    required this.channelName,
    required this.nickFor,
  });

  Future<void> _toggle(BuildContext context, String emoji) async {
    final myId = CryptoService.instance.publicKeyHex;
    await ChannelService.instance
        .toggleCommentReaction(comment.id, emoji, myId);
    await BroadcastOutboxService.instance.enqueueReactionExt(
      kind: 'channel_comment',
      targetId: comment.id,
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
    final cs = Theme.of(context).colorScheme;
    final myId = CryptoService.instance.publicKeyHex;
    final missing = channelCommentMissingLocalMedia(comment);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () async {
          final action = await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.add_reaction_outlined),
                    title: const Text('Реакция…'),
                    onTap: () => Navigator.pop(ctx, 'react'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.forward),
                    title: const Text('Переслать…'),
                    onTap: () => Navigator.pop(ctx, 'fwd'),
                  ),
                  if (text.trim().isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.copy),
                      title: const Text('Копировать текст'),
                      onTap: () => Navigator.pop(ctx, 'copy'),
                    ),
                  if (canDelete)
                    ListTile(
                      leading: Icon(Icons.delete_outline, color: cs.error),
                      title: Text('Удалить', style: TextStyle(color: cs.error)),
                      onTap: () => Navigator.pop(ctx, 'del'),
                    ),
                ],
              ),
            ),
          );
          if (!context.mounted) return;
          if (action == 'react') {
            await _openPicker(context);
          } else if (action == 'fwd') {
            final msg = _channelCommentToForwardMessage(comment, channelId);
            final authorNick = nickFor(comment.authorId);
            final label = channelName.isNotEmpty
                ? '$channelName · комментарий — $authorNick'
                : 'Канал · комментарий — $authorNick';
            await _pickForwardChannelContent(
              context,
              forwardMessage: msg,
              forwardAuthorId: comment.authorId,
              originalAuthorNick: label,
            );
          } else if (action == 'copy') {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Текст скопирован')),
              );
            }
          } else if (action == 'del') {
            onDelete();
          }
        },
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isMe
                ? cs.primary.withValues(alpha: 0.15)
                : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(nick,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.primary)),
              const SizedBox(height: 2),
              if (missing)
                ClearedMediaPlaceholder(
                  isOutgoing: isMe,
                  isDirectChat: false,
                  colorScheme: cs,
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Откройте канал при подключении к сети — '
                          'запросится история и вложения.',
                        ),
                      ),
                    );
                  },
                ),
              if (!missing && comment.imagePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Builder(builder: (_) {
                      final p = ImageService.instance
                          .resolveStoredPath(comment.imagePath);
                      if (p == null) return const SizedBox.shrink();
                      return ChannelCommentImage(resolvedPath: p);
                    }),
                  ),
                ),
              if (!missing && comment.videoPath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ChannelSquareVideoTile(
                    storedPath: comment.videoPath!,
                    size: 140,
                  ),
                ),
              if (!missing && comment.voicePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ChannelVoiceRow(storedPath: comment.voicePath!),
                ),
              if (!missing && comment.filePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ChannelFileAttachRow(
                    storedPath: comment.filePath!,
                    fileName: comment.fileName ?? 'Файл',
                    fileSize: comment.fileSize,
                  ),
                ),
              if (text.trim().isNotEmpty &&
                  !(missing && isSyntheticMediaCaption(comment.text)))
                ValueListenableBuilder<List<Contact>>(
                  valueListenable: ChatStorageService.instance.contactsNotifier,
                  builder: (_, contacts, __) {
                    return RichMessageText(
                      text: text,
                      textColor: cs.onSurface,
                      isOut: isMe,
                      mentionLabelFor: (hex) => resolveChannelMentionDisplay(
                        hex,
                        contacts,
                        ProfileService.instance.profile,
                      ),
                    );
                  },
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment:
                        isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                    children: [
                      for (final e in kQuickReactionEmojis)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: InkWell(
                            onTap: () => _toggle(context, e),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              child: Text(e,
                                  style: const TextStyle(fontSize: 18)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(time,
                  style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurface.withValues(alpha: 0.4))),
              if (comment.reactions.isNotEmpty) ...[
                const SizedBox(height: 4),
                ReactionsBar(
                  reactions: comment.reactions,
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
}

// ══════════════════════════════════════════════════════════════════
// Channel Invite Card — shown at top of channels list
// ══════════════════════════════════════════════════════════════════

class _ChannelInviteCard extends StatelessWidget {
  final ChannelInvite invite;
  const _ChannelInviteCard({required this.invite});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
              initials: invite.channelName.isNotEmpty
                  ? invite.channelName[0].toUpperCase()
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
                  Text(invite.channelName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: cs.onPrimaryContainer,
                      )),
                  Text('${invite.inviterNick} приглашает',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                      )),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                ChannelService.instance.removeChannelInvite(invite.channelId);
              },
              child: Text('Нет',
                  style: TextStyle(
                      color: cs.onPrimaryContainer.withValues(alpha: 0.6))),
            ),
            FilledButton(
              onPressed: () async {
                final myId = CryptoService.instance.publicKeyHex;
                final channel = Channel(
                  id: invite.channelId,
                  name: invite.channelName,
                  adminId: invite.adminId,
                  subscriberIds: [invite.adminId, myId],
                  avatarColor: invite.avatarColor,
                  avatarEmoji: invite.avatarEmoji,
                  description: invite.description,
                  createdAt: invite.createdAt,
                );
                await ChannelService.instance.saveChannelFromBroadcast(channel);
                await ChannelService.instance.subscribe(invite.channelId, myId);
                ChannelService.instance.removeChannelInvite(invite.channelId);
              },
              child: const Text('Подписаться'),
            ),
          ]),
        ),
      ),
    );
  }
}
