import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import '../../models/chat_message.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../widgets/avatar_widget.dart';

class ChatScreen extends StatefulWidget {
  final String peerId; // Ed25519 public key получателя
  final String peerNickname;
  final int peerAvatarColor;
  final String peerAvatarEmoji;

  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerNickname,
    required this.peerAvatarColor,
    this.peerAvatarEmoji = '',
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  bool _isSending = false;
  StreamSubscription<IncomingMessage>? _msgSub;
  // Резолвленный публичный ключ пира (может отличаться от widget.peerId если тот BLE UUID)
  late String _resolvedPeerId;

  static const _kMaxMessageLength = 280;

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
    _controller.dispose();
    _scrollController.dispose();
    _msgSub?.cancel();
    super.dispose();
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
        SnackBar(
            content: Text(
                'Сообщение слишком длинное (макс. $_kMaxMessageLength симв.)')),
      );
      return;
    }

    setState(() => _isSending = true);
    _controller.clear();

    final msgId = _uuid.v4();
    final msg = ChatMessage(
      id: msgId,
      peerId: _resolvedPeerId,
      text: text,
      isOutgoing: true,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );
    await ChatStorageService.instance.saveMessage(msg);
    _scrollToBottom();

    try {
      // senderId = наш публичный ключ, recipientId = публичный ключ получателя
      await GossipRouter.instance.sendRawMessage(
        text: text,
        senderId: CryptoService.instance.publicKeyHex,
        recipientId: _resolvedPeerId,
      );
      await ChatStorageService.instance
          .saveMessage(msg.copyWith(status: MessageStatus.sent));
    } catch (e) {
      await ChatStorageService.instance
          .saveMessage(msg.copyWith(status: MessageStatus.failed));
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
      );
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
                    _MessageBubble(msg: msg),
                  ]);
                },
              );
            },
          ),
        ),
        _InputBar(
          controller: _controller,
          isSending: _isSending,
          maxLength: _kMaxMessageLength,
          onSend: _send,
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
  const _MessageBubble({required this.msg});

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
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
            msg.text,
            style: TextStyle(
              color: isOut ? Colors.white : cs.onSurface,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
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
          ]),
        ]),
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
  final int maxLength;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.isSending,
    required this.maxLength,
    required this.onSend,
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

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border(top: BorderSide(color: Colors.grey.shade800)),
        ),
        child: Row(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: widget.controller,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Сообщение...',
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
          GestureDetector(
            onTap: widget.isSending || over ? null : widget.onSend,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (widget.isSending || over)
                    ? Colors.grey.shade700
                    : const Color(0xFF1DB954),
                shape: BoxShape.circle,
              ),
              child: widget.isSending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded,
                      color: Colors.white, size: 20),
            ),
          ),
        ]),
      ),
    );
  }
}
