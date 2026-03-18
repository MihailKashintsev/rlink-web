import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../main.dart';
import '../../services/ble_service.dart';
import '../../services/crypto_service.dart';
import '../../services/crypto_service.dart' show EncryptedMessage;
import '../../services/gossip_router.dart';
import '../../services/update_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _messages   = <ChatMessage>[];
  final _controller = TextEditingController();
  final _scrollKey  = GlobalKey<AnimatedListState>();
  final _listKey    = GlobalKey();

  StreamSubscription<IncomingMessage>? _msgSub;
  String? _targetPeerId; // ID собеседника (null = broadcast)
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _msgSub = incomingMessageController.stream.listen(_onIncoming);

    // Слушаем обновления
    pendingUpdateNotifier.addListener(_onUpdateAvailable);
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _controller.dispose();
    pendingUpdateNotifier.removeListener(_onUpdateAvailable);
    super.dispose();
  }

  // ─── Входящее сообщение ─────────────────────────────────

  void _onIncoming(IncomingMessage msg) {
    setState(() {
      _messages.add(ChatMessage(
        text: msg.text,
        fromId: msg.fromId,
        timestamp: msg.timestamp,
        isOutgoing: false,
      ));
    });
    _scrollToBottom();
  }

  // ─── Отправка ───────────────────────────────────────────

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;
    if (_targetPeerId == null) {
      _showNoPeerSnack();
      return;
    }

    setState(() => _isSending = true);
    _controller.clear();

    try {
      final encrypted = await CryptoService.instance.encryptMessage(
        plaintext: text,
        recipientPublicKeyHex: _targetPeerId!,
      );

      await GossipRouter.instance.sendMessage(
        encrypted: encrypted,
        recipientId: _targetPeerId!,
      );

      setState(() {
        _messages.add(ChatMessage(
          text: text,
          fromId: CryptoService.instance.publicKeyHex,
          timestamp: DateTime.now(),
          isOutgoing: true,
        ));
      });
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

  // ─── Обновление ─────────────────────────────────────────

  void _onUpdateAvailable() {
    final update = pendingUpdateNotifier.value;
    if (update == null || !mounted) return;

    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        content: Text('Доступно обновление ${update.version}'),
        leading: const Icon(Icons.system_update, color: Colors.green),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
            },
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              _doUpdate(update);
            },
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
  }

  Future<void> _doUpdate(UpdateInfo update) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(update: update),
    );
  }

  // ─── UI ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshChat'),
        actions: [
          _PeerIndicator(),
          IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'Мой ID',
            onPressed: _showMyId,
          ),
        ],
      ),
      body: Column(
        children: [
          // Peer selector
          _PeerSelector(
            selected: _targetPeerId,
            onSelected: (id) => setState(() => _targetPeerId = id),
          ),
          const Divider(height: 1),
          // Messages
          Expanded(
            child: _messages.isEmpty
                ? _EmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _MessageBubble(msg: _messages[i]),
                  ),
          ),
          // Input
          _MessageInput(
            controller: _controller,
            isSending: _isSending,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // scroll logic
    });
  }

  void _showNoPeerSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Выбери собеседника из списка пиров')),
    );
  }

  void _showMyId() {
    final id = CryptoService.instance.publicKeyHex;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Твой публичный ключ (ID)'),
        content: SelectableText(
          id,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: id));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Скопировано!')),
              );
            },
            child: const Text('Копировать'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
        ],
      ),
    );
  }
}

// ─── Вспомогательные виджеты ────────────────────────────────

class _PeerIndicator extends StatefulWidget {
  @override
  State<_PeerIndicator> createState() => _PeerIndicatorState();
}

class _PeerIndicatorState extends State<_PeerIndicator> {
  StreamSubscription<BluetoothAdapterState>? _sub;
  int _peers = 0;
  bool _bleOn = false;

  @override
  void initState() {
    super.initState();
    _sub = BleService.instance.adapterState.listen((s) {
      setState(() => _bleOn = s == BluetoothAdapterState.on);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _bleOn ? Colors.green : Colors.red;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Icon(Icons.bluetooth, size: 16, color: color),
        const SizedBox(width: 4),
        Text('${BleService.instance.connectedPeersCount}',
            style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

class _PeerSelector extends StatelessWidget {
  final String? selected;
  final void Function(String id) onSelected;
  const _PeerSelector({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    // В реальном приложении — список из BleService.connectedPeers
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: selected == null
          ? Text('Пиры не найдены',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13))
          : Chip(
              label: Text(
                '${selected!.substring(0, 12)}...',
                style: const TextStyle(fontSize: 12),
              ),
              avatar: const Icon(Icons.person, size: 16),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.bluetooth_searching, size: 64, color: Colors.green),
        SizedBox(height: 16),
        Text('Ищем устройства поблизости...', style: TextStyle(fontSize: 16)),
        SizedBox(height: 8),
        Text('Bluetooth, без интернета', style: TextStyle(color: Colors.grey)),
      ]),
    );
  }
}

class _MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  const _MessageInput({required this.controller, required this.isSending, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Сообщение...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: isSending ? null : onSend,
            child: isSending
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
          ),
        ]),
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo update;
  const _UpdateDialog({required this.update});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  @override
  void initState() {
    super.initState();
    UpdateService.instance.downloadProgress.addListener(_rebuild);
    UpdateService.instance.downloadAndInstall(widget.update);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    UpdateService.instance.downloadProgress.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = UpdateService.instance.downloadProgress.value;
    return AlertDialog(
      title: Text('Обновление ${widget.update.version}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (progress == null)
          const CircularProgressIndicator()
        else ...[
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text('${(progress * 100).toStringAsFixed(0)}%'),
        ],
        const SizedBox(height: 8),
        const Text('Пожалуйста, не закрывай приложение...'),
      ]),
    );
  }
}

// ─── Модель сообщения ───────────────────────────────────────

class ChatMessage {
  final String text;
  final String fromId;
  final DateTime timestamp;
  final bool isOutgoing;
  const ChatMessage({
    required this.text,
    required this.fromId,
    required this.timestamp,
    required this.isOutgoing,
  });
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  const _MessageBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: msg.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: msg.isOutgoing ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomRight: msg.isOutgoing ? const Radius.circular(4) : null,
            bottomLeft: msg.isOutgoing ? null : const Radius.circular(4),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!msg.isOutgoing)
            Text(
              '${msg.fromId.substring(0, 8)}...',
              style: TextStyle(fontSize: 10, color: cs.primary, fontWeight: FontWeight.bold),
            ),
          Text(
            msg.text,
            style: TextStyle(color: msg.isOutgoing ? cs.onPrimary : cs.onSurface),
          ),
          const SizedBox(height: 2),
          Text(
            _fmt(msg.timestamp),
            style: TextStyle(
              fontSize: 10,
              color: (msg.isOutgoing ? cs.onPrimary : cs.onSurface).withOpacity(0.5),
            ),
          ),
        ]),
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
