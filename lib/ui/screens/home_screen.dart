import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../main.dart';
import '../../services/ble_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/update_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _messages = <ChatMessage>[];
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  StreamSubscription<IncomingMessage>? _msgSub;
  String? _targetPeerId;
  bool _isSending = false;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _msgSub = incomingMessageController.stream.listen(_onIncoming);
    pendingUpdateNotifier.addListener(_onUpdateAvailable);
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    pendingUpdateNotifier.removeListener(_onUpdateAvailable);
    super.dispose();
  }

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

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;
    if (_targetPeerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выбери пира из списка')),
      );
      return;
    }

    setState(() => _isSending = true);
    _controller.clear();

    try {
      await GossipRouter.instance.sendRawMessage(
        text: text,
        recipientId: _targetPeerId!,
        senderId: CryptoService.instance.publicKeyHex,
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

  Future<void> _rescan() async {
    setState(() => _isScanning = true);
    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        withServices: [Guid('12345678-1234-5678-1234-56789abcdef0')],
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 30),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Поиск устройств...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Scan] Error: $e');
    } finally {
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) setState(() => _isScanning = false);
    }
  }

  void _onUpdateAvailable() {
    final update = pendingUpdateNotifier.value;
    if (update == null || !mounted) return;
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        content: Text('Доступно обновление ${update.version}'),
        leading: const Icon(Icons.system_update, color: Colors.green),
        actions: [
          TextButton(
            onPressed: () =>
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rlink'),
        actions: [
          // Кнопка поиска
          _isScanning
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Найти устройства',
                  onPressed: _rescan,
                ),
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
          _PeerSelector(
            selected: _targetPeerId,
            onSelected: (id) => setState(() => _targetPeerId = id),
          ),
          const Divider(height: 1),
          Expanded(
            child: _messages.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _MessageBubble(msg: _messages[i]),
                  ),
          ),
          _MessageInput(
            controller: _controller,
            isSending: _isSending,
            onSend: _sendMessage,
          ),
        ],
      ),
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}

// ── Индикатор пиров ──────────────────────────────────────────────

class _PeerIndicator extends StatefulWidget {
  @override
  State<_PeerIndicator> createState() => _PeerIndicatorState();
}

class _PeerIndicatorState extends State<_PeerIndicator> {
  StreamSubscription<BluetoothAdapterState>? _sub;
  bool _bleOn = false;

  @override
  void initState() {
    super.initState();
    _sub = BleService.instance.adapterState.listen((s) {
      if (mounted) setState(() => _bleOn = s == BluetoothAdapterState.on);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Icon(Icons.bluetooth_disabled, size: 16, color: Colors.grey),
          SizedBox(width: 4),
          Text('—', style: TextStyle(color: Colors.grey)),
        ]),
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: BleService.instance.peersCount,
      builder: (_, count, __) {
        final color = !_bleOn
            ? Colors.red
            : count > 0
                ? Colors.green
                : Colors.orange;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            Icon(Icons.bluetooth, size: 16, color: color),
            const SizedBox(width: 4),
            Text('$count',
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ]),
        );
      },
    );
  }
}

// ── Выбор пира ───────────────────────────────────────────────────

class _PeerSelector extends StatelessWidget {
  final String? selected;
  final void Function(String id) onSelected;
  const _PeerSelector({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: BleService.instance.peersCount,
      builder: (_, count, __) {
        if (count == 0) {
          return Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: Text(
              'Ищем устройства поблизости...',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
            ),
          );
        }

        final peers = BleService.instance.connectedPeerIds;
        return SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: peers.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final id = peers[i];
              final isSelected = id == selected;
              return FilterChip(
                label: Text(
                  id.length > 8 ? '${id.substring(0, 8)}...' : id,
                  style: const TextStyle(fontSize: 12),
                ),
                selected: isSelected,
                onSelected: (_) => onSelected(id),
                avatar: const Icon(Icons.phone_android, size: 14),
              );
            },
          ),
        );
      },
    );
  }
}

// ── Пустое состояние ─────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

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

// ── Ввод сообщения ───────────────────────────────────────────────

class _MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  const _MessageInput({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

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
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: isSending ? null : onSend,
            child: isSending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
          ),
        ]),
      ),
    );
  }
}

// ── Диалог обновления ────────────────────────────────────────────

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

// ── Модель сообщения ─────────────────────────────────────────────

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
              Text(
                msg.fromId.length > 8
                    ? '${msg.fromId.substring(0, 8)}...'
                    : msg.fromId,
                style: TextStyle(
                  fontSize: 10,
                  color: cs.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            Text(
              msg.text,
              style: TextStyle(
                color: msg.isOutgoing ? cs.onPrimary : cs.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _fmt(msg.timestamp),
              style: TextStyle(
                fontSize: 10,
                color: (msg.isOutgoing ? cs.onPrimary : cs.onSurface)
                    .withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
