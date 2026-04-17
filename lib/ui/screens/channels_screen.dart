import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/channel.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/image_service.dart';
import '../../services/voice_service.dart';
import '../widgets/animated_transitions.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';
import 'image_editor_screen.dart';
import 'square_video_recorder_screen.dart';

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
                  child: _ChannelTile(channel: filtered[i], onTap: () => _openChannel(filtered[i])),
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
                description: descCtrl.text.trim().isEmpty
                    ? null
                    : descCtrl.text.trim(),
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
    _load();
    ChannelService.instance.version.addListener(_load);
  }

  @override
  void dispose() {
    ChannelService.instance.version.removeListener(_load);
    _postCtrl.dispose();
    _recordingTimer?.cancel();
    _recordingSecondsNotifier.dispose();
    super.dispose();
  }

  void _load() async {
    final ch = await ChannelService.instance.getChannel(_channel.id);
    if (ch != null && mounted) setState(() => _channel = ch);
    final posts = await ChannelService.instance.getPosts(_channel.id);
    if (mounted) setState(() => _posts = posts);
  }

  // ── Text post ───────────────────────────────────────────────

  Future<void> _createPost() async {
    final text = _postCtrl.text.trim();
    if (text.isEmpty) return;
    _postCtrl.clear();

    final postId = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    final post = ChannelPost(
      id: postId,
      channelId: _channel.id,
      authorId: _myId,
      text: text,
      timestamp: now,
    );
    await ChannelService.instance.savePost(post);

    await GossipRouter.instance.sendChannelPost(
      channelId: _channel.id,
      postId: postId,
      authorId: _myId,
      text: text,
    );
  }

  // ── Image post ──────────────────────────────────────────────

  Future<void> _pickAndSendImage() async {
    if (_isSending) return;

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final editedBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => ImageEditorScreen(imagePath: picked.path)),
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

      await GossipRouter.instance.sendChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: post.text,
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

  // ── Video (square) post ─────────────────────────────────────

  Future<void> _pickAndSendVideo() async {
    if (_isSending) return;
    if (!mounted) return;

    final videoPath = await showSquareVideoRecorder(context);
    if (videoPath == null || !mounted) return;

    setState(() {
      _isSending = true;
      _sendProgress = 0.0;
    });
    try {
      final path =
          await ImageService.instance.saveVideo(videoPath, isSquare: true);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final postId = _uuid.v4();

      await GossipRouter.instance.sendImgMeta(
        msgId: postId,
        totalChunks: chunks.length,
        fromId: _myId,
        isAvatar: false,
        isVideo: true,
        isSquare: true,
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

      await GossipRouter.instance.sendChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: '',
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
      );
      await ChannelService.instance.savePost(post);

      await GossipRouter.instance.sendChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: post.text,
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
      );
      await ChannelService.instance.savePost(post);

      await GossipRouter.instance.sendChannelPost(
        channelId: _channel.id,
        postId: postId,
        authorId: _myId,
        text: post.text,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка голосового: $e'),
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
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.flash_on, color: Colors.green),
              title: const Text('Быстрое'),
              subtitle: const Text('160px, маленький размер'),
              onTap: () =>
                  Navigator.pop(ctx, const _ImageQuality(quality: 40, maxSize: 160)),
            ),
            ListTile(
              leading: const Icon(Icons.tune, color: Colors.orange),
              title: const Text('Стандарт'),
              subtitle: const Text('320px, баланс скорость/качество'),
              onTap: () =>
                  Navigator.pop(ctx, const _ImageQuality(quality: 55, maxSize: 320)),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality, color: Colors.blue),
              title: const Text('Высокое'),
              subtitle: const Text('640px, дольше передача'),
              onTap: () =>
                  Navigator.pop(ctx, const _ImageQuality(quality: 70, maxSize: 640)),
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
            content: Text('Заявка на верификацию отправлена администраторам сети'),
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
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar image picker
                  Center(
                    child: GestureDetector(
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
                        backgroundColor: Color(pickedColor),
                        backgroundImage: pickedImagePath != null && File(pickedImagePath!).existsSync()
                            ? FileImage(File(pickedImagePath!)) : null,
                        child: pickedImagePath == null || !File(pickedImagePath!).existsSync()
                            ? Text(emojiCtrl.text.isEmpty ? '📢' : emojiCtrl.text,
                                style: const TextStyle(fontSize: 28))
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameCtrl,
                    maxLength: 30,
                    autofocus: true,
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
                  Text('Цвет канала', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
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
                          child: sel ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  // Toggles
                  SwitchListTile(
                    value: commentsEnabled,
                    onChanged: (v) => setDialogState(() => commentsEnabled = v),
                    title: const Text('Комментарии'),
                    subtitle: const Text('Подписчики могут комментировать посты',
                        style: TextStyle(fontSize: 12)),
                    secondary: const Icon(Icons.comment_outlined),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  SwitchListTile(
                    value: isPublic,
                    onChanged: (v) => setDialogState(() => isPublic = v),
                    title: const Text('Публичный канал'),
                    subtitle: Text(isPublic
                        ? 'Найдётся в поиске'
                        : 'Скрытый — только по прямой ссылке',
                        style: const TextStyle(fontSize: 12)),
                    secondary: Icon(isPublic ? Icons.public : Icons.lock_outline),
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
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
              FilledButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  Navigator.pop(ctx);
                  final updated = _channel.copyWith(
                    name: name,
                    description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
                    avatarEmoji: emojiCtrl.text.trim().isEmpty ? _channel.avatarEmoji : emojiCtrl.text.trim(),
                    avatarImagePath: pickedImagePath,
                    avatarColor: pickedColor,
                    commentsEnabled: commentsEnabled,
                    isPublic: isPublic,
                  );
                  await ChannelService.instance.updateChannel(updated);
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
                    moderatorIds: updated.moderatorIds,
                  ));
                  if (mounted) setState(() => _channel = updated);
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
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
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (current.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков', style: TextStyle(color: Colors.grey)),
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
                            isMod ? 'Модератор · ${uid.substring(0, 12)}…' : '${uid.substring(0, 12)}…',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_remove_outlined, color: Colors.red),
                            tooltip: 'Исключить',
                            onPressed: () async {
                              await ChannelService.instance.removeSubscriber(_channel.id, uid);
                              final ch = await ChannelService.instance.getChannel(_channel.id);
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
                            content:
                                Text('${c.nickname} приглашён в канал')),
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
    final subscribers = _channel.subscriberIds
        .where((id) => id != _channel.adminId)
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
          final mods = _channel.moderatorIds;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Модераторы канала',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
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
                      maxHeight:
                          MediaQuery.of(ctx2).size.height * 0.5,
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
                            final updated =
                                await ChannelService.instance
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
        title: Column(
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
        actions: [
          // Subscribe / Unsubscribe for non-admins
          if (!_isAdmin)
            TextButton.icon(
              onPressed: _toggleSubscribe,
              icon: Icon(
                _isSubscribed ? Icons.notifications_off_outlined : Icons.notifications_outlined,
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
                      Text('Удалить канал', style: TextStyle(color: Colors.red)),
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
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _posts.length,
                    itemBuilder: (_, i) => _PostCard(
                      post: _posts[i],
                      isAdmin: _isAdmin,
                      commentsEnabled: _channel.commentsEnabled,
                      nickFor: _nickFor,
                      onDelete: _channel.canPost(_myId)
                          ? () => _deletePost(_posts[i].id)
                          : null,
                      channelId: _channel.id,
                      channelName: _channel.name,
                    ),
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
              onMicDown: _startVoiceRecording,
              onMicUp: _stopAndSendVoice,
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
  final VoidCallback onMicDown;
  final VoidCallback onMicUp;

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
    required this.onMicDown,
    required this.onMicUp,
  });

  @override
  State<_ChannelInputBar> createState() => _ChannelInputBarState();
}

class _ChannelInputBarState extends State<_ChannelInputBar> {
  bool _hasText = false;
  bool _showAttachments = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
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
      setState(() {
        _hasText = has;
        if (has) _showAttachments = false; // auto-hide when typing
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final keyboardVisible = _focusNode.hasFocus;

    return SafeArea(
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
              // When keyboard is visible, show dismiss button
              if (keyboardVisible)
                IconButton(
                  onPressed: () => _focusNode.unfocus(),
                  icon: const Icon(Icons.keyboard_hide_outlined),
                  color: cs.onSurfaceVariant,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'Скрыть клавиатуру',
                ),
              // + button to toggle media icons
              IconButton(
                onPressed: () => setState(() => _showAttachments = !_showAttachments),
                icon: AnimatedRotation(
                  turns: _showAttachments ? 0.125 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.add),
                ),
                color: _showAttachments ? cs.primary : cs.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: 'Прикрепить',
              ),
              // Media icons (shown when + is toggled and not typing)
              if (_showAttachments && !_hasText) ...[
                IconButton(
                  onPressed: widget.isSending ? null : widget.onPickImage,
                  icon: const Icon(Icons.photo_outlined),
                  color: cs.onSurfaceVariant,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'Фото',
                ),
                IconButton(
                  onPressed: widget.isSending ? null : widget.onPickFile,
                  icon: const Icon(Icons.attach_file_outlined),
                  color: cs.onSurfaceVariant,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'Прикрепить файл',
                ),
              ],
              const SizedBox(width: 4),
              // Text field
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
                        enabled: !widget.isRecording,
                        maxLines: 4,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: widget.isRecording
                              ? 'Запись... ${s}s.$t'
                              : 'Новый пост...',
                          hintStyle: TextStyle(
                              color: cs.onSurfaceVariant
                                  .withValues(alpha: 0.6)),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Send button or media buttons
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
                Row(children: [
                  // Square video recorder button
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
                      child: Icon(Icons.videocam_rounded,
                          color: cs.onPrimary, size: 22),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Voice record button
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
                        color:
                            widget.isRecording ? Colors.redAccent : cs.primary,
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
                ]),
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

  const _PostCard({
    required this.post,
    required this.isAdmin,
    required this.commentsEnabled,
    required this.nickFor,
    this.onDelete,
    required this.channelId,
    this.channelName = '',
  });

  Future<void> _togglePostReaction(BuildContext context, String emoji) async {
    final myId = CryptoService.instance.publicKeyHex;
    await ChannelService.instance.togglePostReaction(post.id, emoji, myId);
    await GossipRouter.instance.sendReactionExt(
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
    // Show channel name as sender (like Telegram). In parentheses show author only
    // if it's a moderator posting (not admin), so admins know who posted.
    final senderLabel = channelName.isNotEmpty ? channelName : nickFor(post.authorId);

    return GestureDetector(
      onLongPress: () => _openReactionPicker(context),
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
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.4)),
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
            // Image
            if (post.imagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(post.imagePath!),
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            // Video thumbnail placeholder
            if (post.videoPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  height: 200,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: Icon(Icons.play_circle_outline,
                        size: 48, color: Colors.white70),
                  ),
                ),
              ),
            // Text
            if (post.text.isNotEmpty)
              SelectableText(post.text,
                  style: TextStyle(fontSize: 15, color: cs.onSurface)),
            const SizedBox(height: 8),
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
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
  final String Function(String) nickFor;

  const PostCommentsScreen({
    super.key,
    required this.post,
    required this.channelId,
    required this.nickFor,
  });

  @override
  State<PostCommentsScreen> createState() => _PostCommentsScreenState();
}

class _PostCommentsScreenState extends State<PostCommentsScreen> {
  final _commentCtrl = TextEditingController();
  final _scrollController = ScrollController();
  List<ChannelComment> _comments = [];
  String get _myId => CryptoService.instance.publicKeyHex;

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
    _commentCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _loadComments() async {
    final comments =
        await ChannelService.instance.getComments(widget.post.id);
    if (mounted) setState(() => _comments = comments);
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

    await GossipRouter.instance.sendChannelComment(
      postId: widget.post.id,
      commentId: commentId,
      authorId: _myId,
      text: text,
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final postDt = DateTime.fromMillisecondsSinceEpoch(widget.post.timestamp);

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
              border: Border.all(
                  color: cs.outline.withValues(alpha: 0.2)),
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
                if (widget.post.imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(widget.post.imagePath!),
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                  ),
                if (widget.post.videoPath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      width: double.infinity,
                      height: 180,
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Center(
                        child: Icon(Icons.play_circle_outline,
                            size: 48, color: Colors.white70),
                      ),
                    ),
                  ),
                if (widget.post.text.isNotEmpty)
                  SelectableText(widget.post.text,
                      style:
                          TextStyle(fontSize: 15, color: cs.onSurface)),
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
                child: Divider(
                    color: cs.outline.withValues(alpha: 0.2)),
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
                                color: cs.onSurface
                                    .withValues(alpha: 0.3))),
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
                      final cDt = DateTime.fromMillisecondsSinceEpoch(
                          c.timestamp);
                      return _CommentBubble(
                        comment: c,
                        nick: widget.nickFor(c.authorId),
                        text: c.text,
                        time:
                            '${cDt.hour.toString().padLeft(2, '0')}:${cDt.minute.toString().padLeft(2, '0')}',
                        isMe: isMe,
                      );
                    },
                  ),
          ),

          // ── Comment input ──
          SafeArea(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                    top: BorderSide(
                        color: cs.outline.withValues(alpha: 0.3))),
              ),
              child: Row(children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _commentCtrl,
                      maxLines: 3,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Комментарий...',
                        hintStyle: TextStyle(
                            color: cs.onSurfaceVariant
                                .withValues(alpha: 0.6)),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _addComment(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _addComment,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.send_rounded,
                        color: cs.onPrimary, size: 20),
                  ),
                ),
              ]),
            ),
          ),
        ],
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

  const _CommentBubble({
    required this.comment,
    required this.nick,
    required this.text,
    required this.time,
    required this.isMe,
  });

  Future<void> _toggle(BuildContext context, String emoji) async {
    final myId = CryptoService.instance.publicKeyHex;
    await ChannelService.instance.toggleCommentReaction(comment.id, emoji, myId);
    await GossipRouter.instance.sendReactionExt(
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
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _openPicker(context),
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
              Text(text,
                  style: TextStyle(fontSize: 14, color: cs.onSurface)),
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
                  style: TextStyle(color: cs.onPrimaryContainer.withValues(alpha: 0.6))),
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
