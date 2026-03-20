import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import '../../models/chat_message.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/voice_service.dart';
import '../widgets/avatar_widget.dart';

class ChatScreen extends StatefulWidget {
  final String peerId; // Ed25519 public key получателя
  final String peerNickname;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;

  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerNickname,
    required this.peerAvatarColor,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  final _picker = ImagePicker();
  bool _isSending = false;
  StreamSubscription<IncomingMessage>? _msgSub;
  // Резолвленный публичный ключ пира (может отличаться от widget.peerId если тот BLE UUID)
  late String _resolvedPeerId;
  String? _replyToMessageId;
  String? _replyPreviewText;
  String? _editingMessageId;
  String? _editingPreviewText;
  bool _isRecording = false;
  double _recordingSeconds = 0;
  Timer? _recordingTimer;

  static const _kMaxMessageLength = 280;
  static final _publicKeyRegExp = RegExp(r'^[0-9a-fA-F]{64}$');

  bool _looksLikePublicKey(String id) =>
      _publicKeyRegExp.hasMatch(id.trim());

  Future<bool> _waitForPeerPublicKey({Duration timeout = const Duration(seconds: 6)}) async {
    final deadline = DateTime.now().add(timeout);
    while (mounted && DateTime.now().isBefore(deadline)) {
      final resolved = BleService.instance.resolvePublicKey(widget.peerId);
      if (_looksLikePublicKey(resolved)) {
        setState(() => _resolvedPeerId = resolved);
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _resolvedPeerId = BleService.instance.resolvePublicKey(widget.peerId);
    _load();
    // Следим за изменением маппингов BLE UUID → public key
    BleService.instance.peersCount.addListener(_onPeersChanged);
    BleService.instance.peerMappingsVersion.addListener(_onPeersChanged);
    _msgSub = incomingMessageController.stream.listen((msg) {
      // fromId — Ed25519 public key. Сообщение уже сохранено в main.dart.
      // Проверяем по обоим вариантам: resolvedPeerId и widget.peerId.
      final resolved = BleService.instance.resolvePublicKey(widget.peerId);
      debugPrint(
          '[Chat] isOurPeer: fromId=${msg.fromId.substring(0, 16)} resolved=${resolved.substring(0, 16)}');
      final isOurPeer = msg.fromId == _resolvedPeerId ||
          msg.fromId == widget.peerId ||
          msg.fromId == resolved;
      if (isOurPeer) {
        // Если резолвился новый ключ — перезагружаем под правильным peerId
        if (resolved != _resolvedPeerId && resolved != widget.peerId) {
          _resolvedPeerId = resolved;
          ChatStorageService.instance.loadMessages(_resolvedPeerId);
        }
        _scrollToBottom();
      }
    });
  }

  void _onPeersChanged() {
    final resolved = BleService.instance.resolvePublicKey(widget.peerId);
    if (resolved != _resolvedPeerId && resolved != widget.peerId) {
      setState(() => _resolvedPeerId = resolved);
      // Перезагружаем сообщения под правильным публичным ключом
      ChatStorageService.instance.loadMessages(_resolvedPeerId);
    }
  }

  @override
  void dispose() {
    BleService.instance.peersCount.removeListener(_onPeersChanged);
    BleService.instance.peerMappingsVersion.removeListener(_onPeersChanged);
    _recordingTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _msgSub?.cancel();
    super.dispose();
  }

  // ── Voice recording ───────────────────────────────────────────

  Future<void> _startVoiceRecording() async {
    if (_isSending || _isRecording) return;
    final path = await VoiceService.instance.startRecording();
    if (path == null) return;
    setState(() {
      _isRecording = true;
      _recordingSeconds = 0;
    });
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_isRecording) return;
      setState(() => _recordingSeconds += 0.1);
      if (_recordingSeconds >= 60) {
        _stopAndSendVoice();
      }
    });
  }

  Future<void> _stopAndSendVoice() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;

    final path = await VoiceService.instance.stopRecording();
    final duration = _recordingSeconds;
    setState(() {
      _isRecording = false;
      _recordingSeconds = 0;
    });

    if (path == null || duration < 0.5) return;
    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) return;
    }

    try {
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = _uuid.v4();
      final myId = CryptoService.instance.publicKeyHex;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        recipientId: _resolvedPeerId,
        isAvatar: false,
        isVoice: true,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myId,
          recipientId: _resolvedPeerId,
        );
      }

      await ChatStorageService.instance.saveMessage(ChatMessage(
        id: msgId,
        peerId: _resolvedPeerId,
        text: '🎤 Голосовое',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        voicePath: path,
      ));
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка голосового: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _load() async {
    await ChatStorageService.instance.loadMessages(_resolvedPeerId);
    _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    if (text.length > _kMaxMessageLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Сообщение слишком длинное (макс. $_kMaxMessageLength симв.)')),
      );
      return;
    }

    setState(() => _isSending = true);

    String? msgId;
    try {
      // Peer id might be a BLE UUID until profiles exchange completes.
      if (!_looksLikePublicKey(_resolvedPeerId)) {
        final ok = await _waitForPeerPublicKey();
        if (!ok) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Подождите — идёт обмен профилями'),
              ),
            );
          }
          return;
        }
      }

      // 1) Edit mode: send edit packet for an existing outgoing message.
      if (_editingMessageId != null) {
        final targetId = _editingMessageId!;
        await GossipRouter.instance.sendEditMessage(
          messageId: targetId,
          newText: text,
          senderId: CryptoService.instance.publicKeyHex,
          recipientId: _resolvedPeerId,
        );
        await ChatStorageService.instance.editMessage(targetId, text);
        if (!mounted) return;
        _controller.clear();
        _cancelEdit();
        return;
      }

      // 2) Normal mode: send raw message (optionally as a reply).
      _controller.clear();
      msgId = _uuid.v4();
      final msg = ChatMessage(
        id: msgId,
        peerId: _resolvedPeerId,
        text: text,
        replyToMessageId: _replyToMessageId,
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );
      await ChatStorageService.instance.saveMessage(msg);
      _scrollToBottom();

      await GossipRouter.instance.sendRawMessage(
        text: text,
        senderId: CryptoService.instance.publicKeyHex,
        recipientId: _resolvedPeerId,
        messageId: msgId,
        replyToMessageId: _replyToMessageId,
      );

      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );

      // Clear reply composer after successful send.
      if (mounted) {
        setState(() {
          _replyToMessageId = null;
          _replyPreviewText = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (msgId != null) {
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId,
          MessageStatus.failed,
        );
      }
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendImage() async {
    if (_isSending) return;
    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Подождите — идёт обмен профилями')),
          );
        }
        return;
      }
    }

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    setState(() => _isSending = true);
    try {
      final path = await ImageService.instance.compressAndSave(picked.path);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = _uuid.v4();
      final myId = CryptoService.instance.publicKeyHex;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        recipientId: _resolvedPeerId,
        isAvatar: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myId,
          recipientId: _resolvedPeerId,
        );
      }

      final msg = ChatMessage(
        id: msgId,
        peerId: _resolvedPeerId,
        text: '',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        imagePath: path,
      );
      await ChatStorageService.instance.saveMessage(msg);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
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

  void _startReply(ChatMessage msg) {
    setState(() {
      _editingMessageId = null;
      _editingPreviewText = null;
      _replyToMessageId = msg.id;
      _replyPreviewText = msg.text;
    });
  }

  void _cancelReply() {
    setState(() {
      _replyToMessageId = null;
      _replyPreviewText = null;
    });
  }

  void _startEdit(ChatMessage msg) {
    setState(() {
      _replyToMessageId = null;
      _replyPreviewText = null;
      _editingMessageId = msg.id;
      _editingPreviewText = msg.text;
      _controller.text = msg.text;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingMessageId = null;
      _editingPreviewText = null;
      _controller.clear();
    });
  }

  Future<void> _confirmAndDelete(ChatMessage msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщение?'),
        content: const Text('Сообщение исчезнет у собеседника.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      if (_replyToMessageId == msg.id) {
        _replyToMessageId = null;
        _replyPreviewText = null;
      }
      if (_editingMessageId == msg.id) {
        _editingMessageId = null;
        _editingPreviewText = null;
        _controller.clear();
      }
    });

    try {
      // Удаляем локально для мгновенного отклика.
      await ChatStorageService.instance.deleteMessage(msg.id);
      // Просим получателя удалить копию.
      await GossipRouter.instance.sendDeleteMessage(
        messageId: msg.id,
        senderId: CryptoService.instance.publicKeyHex,
        recipientId: _resolvedPeerId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка удаления: $e'), backgroundColor: Colors.red),
      );
      // Возвращаем UI в согласованное состояние.
      await ChatStorageService.instance.loadMessages(_resolvedPeerId);
    }
  }

  Future<void> _onLongPressMessage(ChatMessage msg) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(ctx);
                _startReply(msg);
              },
            ),
            if (msg.isOutgoing) ...[
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Редактировать'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startEdit(msg);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Удалить'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _confirmAndDelete(msg);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          AvatarWidget(
            initials: widget.peerNickname.isNotEmpty
                ? widget.peerNickname[0].toUpperCase()
                : '?',
            color: widget.peerAvatarColor,
            emoji: widget.peerAvatarEmoji,
            imagePath: widget.peerAvatarImagePath,
            size: 38,
            isOnline: BleService.instance.isPeerConnected(_resolvedPeerId),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.peerNickname,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ValueListenableBuilder<int>(
              valueListenable: BleService.instance.peersCount,
              builder: (_, __, ___) {
                final online =
                    BleService.instance.isPeerConnected(_resolvedPeerId);
                final anyConnected = BleService.instance.peersCount.value > 0;
                return Text(
                  online
                      ? 'в сети'
                      : (anyConnected ? 'нет соединения' : 'BLE выкл'),
                  style: TextStyle(
                    fontSize: 12,
                    color: online ? Colors.green : Colors.grey.shade500,
                  ),
                );
              },
            ),
          ]),
        ]),
        actions: [
          PopupMenuButton(
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'clear', child: Text('Очистить чат')),
            ],
            onSelected: (v) async {
              if (v == 'clear') {
                await ChatStorageService.instance.deleteChat(_resolvedPeerId);
                if (mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ValueListenableBuilder<List<ChatMessage>>(
            valueListenable:
                ChatStorageService.instance.messagesNotifier(_resolvedPeerId),
            builder: (_, messages, __) {
              if (messages.isEmpty) {
                return Center(
                  child: Text('Нет сообщений',
                      style: TextStyle(color: Colors.grey.shade600)),
                );
              }
              final messageTextById = <String, String>{
                for (final m in messages) m.id: m.text,
              };
              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: messages.length,
                itemBuilder: (_, i) {
                  final msg = messages[i];
                  final showDate = i == 0 ||
                      !_sameDay(messages[i - 1].timestamp, msg.timestamp);
                  return Column(children: [
                    if (showDate) _DateDivider(date: msg.timestamp),
                    GestureDetector(
                      onLongPress: () => _onLongPressMessage(msg),
                      child: _MessageBubble(
                        msg: msg,
                        replyPreviewText: msg.replyToMessageId == null
                            ? null
                            : messageTextById[msg.replyToMessageId],
                      ),
                    ),
                  ]);
                },
              );
            },
          ),
        ),
        if (_editingMessageId != null || _replyToMessageId != null)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                border: Border.all(color: Colors.grey.shade800),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _editingMessageId != null
                            ? 'Редактирование'
                            : 'Ответ',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (_editingMessageId != null
                                ? _editingPreviewText
                                : _replyPreviewText) ??
                            '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    if (_editingMessageId != null) {
                      _cancelEdit();
                    } else {
                      _cancelReply();
                    }
                  },
                  icon: const Icon(Icons.close, size: 18),
                  color: Colors.grey.shade400,
                ),
              ]),
            ),
          ),
        _InputBar(
          controller: _controller,
          isSending: _isSending,
          isRecording: _isRecording,
          recordingSeconds: _recordingSeconds,
          maxLength: _kMaxMessageLength,
          onSend: _send,
          onPickImage: _sendImage,
          onMicDown: _startVoiceRecording,
          onMicUp: _stopAndSendVoice,
        ),
      ]),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ── Дата-разделитель ─────────────────────────────────────────────

class _DateDivider extends StatelessWidget {
  final DateTime date;
  const _DateDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    String label;
    if (date.day == now.day) {
      label = 'Сегодня';
    } else if (date.day == now.day - 1) {
      label = 'Вчера';
    } else {
      label = '${date.day}.${date.month}.${date.year}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Expanded(child: Divider(color: Colors.grey.shade800)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        ),
        Expanded(child: Divider(color: Colors.grey.shade800)),
      ]),
    );
  }
}

// ── Пузырь сообщения ─────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final String? replyPreviewText;

  const _MessageBubble({
    required this.msg,
    this.replyPreviewText,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isOut = msg.isOutgoing;

    return Align(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
            left: isOut ? 64 : 12, right: isOut ? 12 : 64, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isOut ? const Color(0xFF1DB954) : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isOut ? 18 : 4),
            bottomRight: Radius.circular(isOut ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (msg.imagePath != null && File(msg.imagePath!).existsSync())
            if (msg.voicePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _VoiceMessageBubble(voicePath: msg.voicePath!, isOut: isOut),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(msg.imagePath!),
                    width: 220,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            if (msg.replyToMessageId != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isOut
                      ? Colors.black.withOpacity(0.18)
                      : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment:
                      isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ответ',
                      style: TextStyle(
                        fontSize: 10,
                        color: isOut ? Colors.white70 : Colors.grey.shade400,
                      ),
                    ),
                    Text(
                      replyPreviewText ?? '...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isOut ? Colors.white : cs.onSurface.withOpacity(0.9),
                      ),
                    ),
                  ],
                ),
              ),
            if (msg.text.isNotEmpty && msg.voicePath == null)
              Text(
                msg.text,
                style: TextStyle(
                  color: isOut ? Colors.white : cs.onSurface,
                  fontSize: 15,
                ),
              ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmt(msg.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isOut ? Colors.white70 : Colors.grey.shade600,
                  ),
                ),
                if (isOut) ...[
                  const SizedBox(width: 4),
                  _statusIcon(msg.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Colors.white70));
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 12, color: Colors.white70);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 12, color: Colors.white);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.red);
    }
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

// ── Поле ввода ───────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final bool isRecording;
  final double recordingSeconds;
  final int maxLength;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onMicDown;
  final VoidCallback onMicUp;

  const _InputBar({
    required this.controller,
    required this.isSending,
    required this.isRecording,
    required this.recordingSeconds,
    required this.maxLength,
    required this.onSend,
    required this.onPickImage,
    required this.onMicDown,
    required this.onMicUp,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  int _length = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      if (mounted) setState(() => _length = widget.controller.text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final near = _length > widget.maxLength * 0.8;
    final over = _length > widget.maxLength;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final secs = widget.recordingSeconds.floor();
    final tenths = ((widget.recordingSeconds % 1) * 10).floor();

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border(top: BorderSide(color: Colors.grey.shade800)),
        ),
        child: Row(children: [
          IconButton(
            onPressed: widget.isSending ? null : widget.onPickImage,
            icon: const Icon(Icons.photo_outlined),
            color: Colors.grey.shade500,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: widget.controller,
                enabled: !widget.isRecording,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: widget.isRecording
                      ? 'Запись... ${secs}s.$tenths'
                      : 'Сообщение...',
                  hintStyle: TextStyle(color: Colors.grey.shade600),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  suffix: near
                      ? Text(
                          '${widget.maxLength - _length}',
                          style: TextStyle(
                            fontSize: 11,
                            color: over ? Colors.red : Colors.grey.shade500,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (hasText || widget.isSending)
            GestureDetector(
              onTap: widget.isSending || over || widget.isRecording ? null : widget.onSend,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (widget.isSending || over || widget.isRecording)
                      ? Colors.grey.shade700
                      : const Color(0xFF1DB954),
                  shape: BoxShape.circle,
                ),
                child: widget.isSending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
              ),
            )
          else
            GestureDetector(
              onLongPressStart: (_) => widget.onMicDown(),
              onLongPressEnd: (_) => widget.onMicUp(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: widget.isRecording
                      ? Colors.redAccent
                      : const Color(0xFF1DB954),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.mic_rounded, color: Colors.white, size: 20),
              ),
            ),
        ]),
      ),
    );
  }
}

class _VoiceMessageBubble extends StatelessWidget {
  final String voicePath;
  final bool isOut;
  const _VoiceMessageBubble({required this.voicePath, required this.isOut});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: VoiceService.instance.currentlyPlaying,
      builder: (_, playing, __) {
        final isPlaying = playing == voicePath;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () async {
                if (isPlaying) {
                  await VoiceService.instance.stop();
                } else {
                  await VoiceService.instance.play(voicePath);
                }
              },
              icon: Icon(
                isPlaying ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                color: isOut ? Colors.white : Colors.white70,
                size: 22,
              ),
            ),
            Text(
              'Голосовое',
              style: TextStyle(
                color: isOut ? Colors.white : Colors.white70,
                fontSize: 13,
              ),
            ),
          ],
        );
      },
    );
  }
}
