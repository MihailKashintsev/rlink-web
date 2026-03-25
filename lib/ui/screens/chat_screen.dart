import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:geolocator/geolocator.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../main.dart';
import '../../models/chat_message.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/voice_service.dart';
import '../../services/story_service.dart';
import '../widgets/avatar_widget.dart';
import 'image_editor_screen.dart';
import 'square_video_recorder_screen.dart';
import 'story_viewer_screen.dart';

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
  final _recordingSecondsNotifier = ValueNotifier<double>(0);
  Timer? _recordingTimer;
  double? _pendingLat;
  double? _pendingLng;

  // BLE ATT MTU ≈ 288 байт. Фиксированный overhead пакета ≈ 186 байт
  // (id36 + t + ttl + ts + from64 + r8 + структура JSON).
  // Оставляем 90 символов для текста — гарантированно уместится в MTU.
  static const _kMaxMessageLength = 90;
  static final _publicKeyRegExp = RegExp(r'^[0-9a-fA-F]{64}$');

  bool _looksLikePublicKey(String id) => _publicKeyRegExp.hasMatch(id.trim());

  Future<bool> _waitForPeerPublicKey(
      {Duration timeout = const Duration(seconds: 6)}) async {
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
    BleService.instance.peerMappingsVersion.addListener(_onPeersChanged);
    _msgSub = incomingMessageController.stream.listen((msg) async {
      // fromId — Ed25519 public key. Сообщение уже сохранено в main.dart.
      final resolved = BleService.instance.resolvePublicKey(widget.peerId);
      debugPrint(
          '[Chat] msg from ${msg.fromId.substring(0, 16)}, resolved=${resolved.substring(0, 16)}');
      final isOurPeer = msg.fromId == _resolvedPeerId ||
          msg.fromId == widget.peerId ||
          msg.fromId == resolved;
      if (!isOurPeer) return;

      // Use msg.fromId (the actual sender public key) as the canonical peer key.
      // Messages are stored in DB with peerId = fromId, so we must load from that key.
      final senderKey = _looksLikePublicKey(msg.fromId) ? msg.fromId
          : _looksLikePublicKey(resolved) ? resolved
          : _resolvedPeerId;

      if (senderKey != _resolvedPeerId) {
        _resolvedPeerId = senderKey;
        if (mounted) setState(() {});
      }

      await ChatStorageService.instance.loadMessages(_resolvedPeerId);
      if (mounted) _scrollToBottom();
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
    _recordingSecondsNotifier.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _msgSub?.cancel();
    super.dispose();
  }

  // ── Voice recording ───────────────────────────────────────────

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
        SnackBar(
            content: Text('Ошибка голосового: $e'),
            backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _toggleLocation() async {
    if (_pendingLat != null) {
      // Already attached — clear it
      setState(() {
        _pendingLat = null;
        _pendingLng = null;
      });
      return;
    }
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нет доступа к геолокации')),
          );
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.lowest, // WiFi/cell towers instead of GPS
          timeLimit: Duration(seconds: 10),
        ),
      );
      setState(() {
        _pendingLat = pos.latitude;
        _pendingLng = pos.longitude;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📍 Геолокация будет прикреплена к следующему сообщению'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка геолокации: $e')),
        );
      }
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

    // Проверяем что сервисы инициализированы
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ошибка: приложение еще не готово'),
          backgroundColor: Colors.red,
        ),
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
          senderId: myId,
          recipientId: _resolvedPeerId,
        );
        await ChatStorageService.instance.editMessage(targetId, text);
        if (!mounted) return;
        _controller.clear();
        _cancelEdit();
        return;
      }

      // 2) Normal mode: send message (encrypted if X25519 key known, else raw).
      _controller.clear();
      msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      final lat = _pendingLat;
      final lng = _pendingLng;
      setState(() { _pendingLat = null; _pendingLng = null; });
      final msg = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: text,
        replyToMessageId: _replyToMessageId,
        latitude: lat,
        longitude: lng,
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );
      await ChatStorageService.instance.saveMessage(msg);
      _scrollToBottom();

      final x25519Key = BleService.instance.getPeerX25519Key(targetPeerId);
      if (x25519Key != null && x25519Key.isNotEmpty) {
        // Зашифрованная отправка — ChaCha20-Poly1305 + X25519 ECDH
        final encrypted = await CryptoService.instance.encryptMessage(
          plaintext: text,
          recipientX25519KeyBase64: x25519Key,
        );
        await GossipRouter.instance.sendEncryptedMessage(
          encrypted: encrypted,
          senderId: myId,
          recipientId: targetPeerId,
          messageId: msgId,
        );
      } else {
        // Fallback — plaintext если X25519 ключ ещё не получен (обмен профилями в процессе)
        await GossipRouter.instance.sendRawMessage(
          text: text,
          senderId: myId,
          recipientId: targetPeerId,
          messageId: msgId,
          replyToMessageId: _replyToMessageId,
        );
      }

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

    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ошибка: приложение еще не готово'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final editedBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => ImageEditorScreen(imagePath: picked.path)),
    );
    if (editedBytes == null || !mounted) return;

    setState(() => _isSending = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File('${tmpDir.path}/edit_${DateTime.now().millisecondsSinceEpoch}.png');
      await tmpFile.writeAsBytes(editedBytes);
      final path = await ImageService.instance.compressAndSave(tmpFile.path);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        recipientId: targetPeerId,
        isAvatar: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myId,
          recipientId: targetPeerId,
        );
      }
      final msg = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
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

  Future<void> _sendVideo() async {
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

    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ошибка: приложение еще не готово'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Open square video recorder as overlay with blur
    if (!mounted) return;
    final videoPath = await showSquareVideoRecorder(context);
    if (videoPath == null || !mounted) return;

    setState(() => _isSending = true);
    try {
      final path = await ImageService.instance.saveVideo(videoPath, isSquare: true);
      final bytes = await File(path).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        recipientId: targetPeerId,
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
          recipientId: targetPeerId,
        );
      }

      final msg = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '⬛ Видео',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        videoPath: path,
      );
      await ChatStorageService.instance.saveMessage(msg);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendFile() async {
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

    // Warn if file is too large (> 500 KB — slow over BLE)
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

    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    setState(() => _isSending = true);
    try {
      // Save a local copy to the files directory
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files');
      if (!filesDir.existsSync()) filesDir.createSync(recursive: true);
      final destPath = '${filesDir.path}/$originalName';
      await File(srcPath).copy(destPath);

      final chunks = ImageService.instance.splitToBase64Chunks(fileBytes);
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        recipientId: targetPeerId,
        isFile: true,
        fileName: originalName,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myId,
          recipientId: targetPeerId,
        );
      }

      await ChatStorageService.instance.saveMessage(ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '📎 $originalName',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        filePath: destPath,
        fileName: originalName,
        fileSize: fileBytes.length,
      ));
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка отправки файла: $e'),
              backgroundColor: Colors.red),
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
        SnackBar(
            content: Text('Ошибка удаления: $e'), backgroundColor: Colors.red),
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
              leading: const Icon(Icons.emoji_emotions),
              title: const Text('Реакция'),
              onTap: () {
                Navigator.pop(ctx);
                _showReactionPicker(msg);
              },
            ),
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

  Future<void> _showReactionPicker(ChatMessage msg) async {
    const emojis = [
      '👍',
      '❤️',
      '😂',
      '😮',
      '😢',
      '😡',
      '🎉',
      '🔥',
      '👎',
      '🤔',
      '😴',
      '🤗'
    ];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Выберите реакцию',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: emojis
                    .map((emoji) => GestureDetector(
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _toggleReaction(msg, emoji);
                          },
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade600),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                                child: Text(emoji,
                                    style: const TextStyle(fontSize: 24))),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleReaction(ChatMessage msg, String emoji) async {
    await ChatStorageService.instance
        .toggleReaction(msg.id, emoji, CryptoService.instance.publicKeyHex);
    await GossipRouter.instance.sendReaction(
      messageId: msg.id,
      emoji: emoji,
      fromId: CryptoService.instance.publicKeyHex,
    );
  }

  Future<void> _pickChatBackground() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    await AppSettings.instance.setChatBgForPeer(_resolvedPeerId, picked.path);
  }

  Future<void> _removeChatBackground() async {
    await AppSettings.instance.setChatBgForPeer(_resolvedPeerId, null);
  }

  void _openPeerProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PeerProfileScreen(
          peerId: _resolvedPeerId,
          nickname: widget.peerNickname,
          avatarColor: widget.peerAvatarColor,
          avatarEmoji: widget.peerAvatarEmoji,
          avatarImagePath: widget.peerAvatarImagePath,
        ),
      ),
    );
  }

  Future<void> _saveImageToGallery(String imagePath) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Gal.putImage(imagePath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Фото сохранено в галерею')));
        }
      } else {
        // Desktop: copy to Downloads folder
        final downloads = Directory('${Platform.environment['HOME'] ?? '.'}/Downloads');
        final dst = File('${downloads.path}/rlink_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await File(imagePath).copy(dst.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Сохранено: ${dst.path}')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red));
      }
    }
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
          PopupMenuButton<String>(
            itemBuilder: (_) {
              final hasBg = (AppSettings.instance.chatBgForPeer(_resolvedPeerId) ?? AppSettings.instance.chatBgForPeer('__global__')) != null;
              return [
                const PopupMenuItem(value: 'profile', child: Text('Профиль')),
                const PopupMenuItem(value: 'background', child: Text('Фон чата')),
                if (hasBg)
                  const PopupMenuItem(value: 'remove_bg', child: Text('Убрать фон')),
                const PopupMenuItem(value: 'clear', child: Text('Очистить чат')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить чат')),
              ];
            },
            onSelected: (v) async {
              switch (v) {
                case 'profile':
                  _openPeerProfile();
                case 'background':
                  _pickChatBackground();
                case 'remove_bg':
                  _removeChatBackground();
                case 'clear':
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Очистить чат?'),
                      content: const Text('Все сообщения будут удалены.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await ChatStorageService.instance.deleteChat(_resolvedPeerId);
                    if (mounted) {
                      await ChatStorageService.instance.loadMessages(_resolvedPeerId);
                      setState(() {});
                    }
                  }
                case 'delete':
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Удалить чат?'),
                      content: const Text('Чат будет удалён окончательно.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Удалить', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await ChatStorageService.instance.deleteChat(_resolvedPeerId);
                    if (mounted) Navigator.pop(context);
                  }
              }
            },
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Chat background image (if set)
              ListenableBuilder(
                listenable: AppSettings.instance,
                builder: (_, __) {
                  final path = AppSettings.instance.chatBgForPeer(_resolvedPeerId)
                      ?? AppSettings.instance.chatBgForPeer('__global__');
                  if (path == null) return const SizedBox.shrink();
                  return Image.file(File(path), fit: BoxFit.cover);
                },
              ),
              RepaintBoundary(
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
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
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
                            onDownloadImage: _saveImageToGallery,
                          ),
                        ),
                      ]);
                    },
                  );
                },
               ),
              ),
            ],
          ),
        ),
        if (_editingMessageId != null || _replyToMessageId != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _editingMessageId != null ? 'Редактирование' : 'Ответ',
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
          recordingSecondsNotifier: _recordingSecondsNotifier,
          maxLength: _kMaxMessageLength,
          locationActive: _pendingLat != null,
          onSend: _send,
          onPickImage: _sendImage,
          onPickVideo: _sendVideo,
          onPickFile: _sendFile,
          onMicDown: _startVoiceRecording,
          onMicUp: _stopAndSendVoice,
          onLocation: _toggleLocation,
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
        Expanded(child: Divider(color: Theme.of(context).dividerColor)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label,
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
        ),
        Expanded(child: Divider(color: Theme.of(context).dividerColor)),
      ]),
    );
  }
}

// ── Пузырь сообщения ─────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final String? replyPreviewText;
  final Function(String)? onDownloadImage;

  const _MessageBubble({
    required this.msg,
    this.replyPreviewText,
    this.onDownloadImage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isOut = msg.isOutgoing;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (_, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(isOut ? 30 * (1 - value) : -30 * (1 - value), 0),
            child: child,
          ),
        );
      },
      child: Align(
        alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
              left: isOut ? 64 : 12, right: isOut ? 12 : 64, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isOut ? cs.primary : cs.surfaceContainerHigh,
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
            if (msg.voicePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _VoiceMessageBubble(
                    voicePath: msg.voicePath!, isOut: isOut),
              ),
            if (msg.videoPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _VideoMessageBubble(
                    videoPath: msg.videoPath!, isOut: isOut),
              ),
            if (msg.imagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(msg.imagePath!),
                        width: 220,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton(
                        icon: const Icon(Icons.download, color: Colors.white),
                        onPressed: () => onDownloadImage?.call(msg.imagePath!),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                  ],
                ),
              ),
            if (msg.filePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _FileMessageBubble(
                  filePath: msg.filePath!,
                  fileName: msg.fileName ?? 'Файл',
                  fileSize: msg.fileSize,
                  isOut: isOut,
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
                      ? Colors.black.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.06),
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
                        color: isOut
                            ? cs.onPrimary.withValues(alpha: 0.6)
                            : cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    Text(
                      replyPreviewText ?? '...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isOut
                            ? cs.onPrimary
                            : cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
            if (msg.text.isNotEmpty && msg.voicePath == null)
              _RichMessageText(text: msg.text, isOut: isOut),
            if (msg.latitude != null && msg.longitude != null)
              _LocationChip(
                lat: msg.latitude!,
                lng: msg.longitude!,
                isOut: isOut,
              ),
            if (msg.reactions.isNotEmpty)
              _ReactionsWidget(reactions: msg.reactions, isOut: isOut, cs: cs),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmt(msg.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isOut
                        ? cs.onPrimary.withValues(alpha: 0.7)
                        : cs.onSurfaceVariant,
                  ),
                ),
                if (isOut) ...[
                  const SizedBox(width: 4),
                  _statusIcon(msg.status, cs),
                ],
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _statusIcon(MessageStatus status, ColorScheme cs) {
    final dimColor = cs.onPrimary.withValues(alpha: 0.6);
    final brightColor = cs.onPrimary;
    switch (status) {
      case MessageStatus.sending:
        return SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: dimColor));
      case MessageStatus.sent:
        return Icon(Icons.check, size: 12, color: dimColor);
      case MessageStatus.delivered:
        return Icon(Icons.done_all, size: 12, color: brightColor);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.red);
    }
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

// ── Виджет реакций ───────────────────────────────────────────────

class _ReactionsWidget extends StatelessWidget {
  final Map<String, List<String>> reactions;
  final bool isOut;
  final ColorScheme cs;

  const _ReactionsWidget({
    required this.reactions,
    required this.isOut,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = reactions.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: sorted.map((e) {
          final multiple = e.value.length > 1;
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 300),
            curve: Curves.elasticOut,
            builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: isOut
                    ? Colors.white.withValues(alpha: multiple ? 0.2 : 0.1)
                    : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: multiple
                    ? Border.all(
                        color: isOut
                            ? Colors.white.withValues(alpha: 0.3)
                            : cs.primary.withValues(alpha: 0.3),
                        width: 1.5,
                      )
                    : null,
              ),
              child: Text(
                e.key,
                style: const TextStyle(fontSize: 18),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Геолокация ───────────────────────────────────────────────────

class _LocationChip extends StatelessWidget {
  final double lat;
  final double lng;
  final bool isOut;

  const _LocationChip({
    required this.lat,
    required this.lng,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final incomingColor = cs.primary;
    return GestureDetector(
      onTap: () => _showLocationDialog(context),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isOut
              ? Colors.black.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            Icons.location_on,
            size: 14,
            color: isOut ? Colors.white70 : incomingColor,
          ),
          const SizedBox(width: 4),
          Text(
            'Геолокация',
            style: TextStyle(
              fontSize: 12,
              color: isOut ? Colors.white70 : incomingColor,
            ),
          ),
        ]),
      ),
    );
  }

  void _showLocationDialog(BuildContext context) {
    final latStr = lat.toStringAsFixed(6);
    final lngStr = lng.toStringAsFixed(6);

    Future<void> openMap(String url) async {
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '$latStr, $lngStr',
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(ctx).hintColor,
                    fontFamily: 'monospace'),
              ),
            ),
            if (Platform.isIOS)
              ListTile(
                leading: const Icon(Icons.map),
                title: const Text('Apple Maps'),
                onTap: () {
                  Navigator.pop(ctx);
                  openMap('maps://?q=$lat,$lng&ll=$lat,$lng');
                },
              ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Google Maps'),
              onTap: () {
                Navigator.pop(ctx);
                openMap(
                    'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
              },
            ),
            ListTile(
              leading: const Icon(Icons.explore_outlined),
              title: const Text('Яндекс Карты'),
              onTap: () {
                Navigator.pop(ctx);
                final deep =
                    'yandexmaps://maps.yandex.ru/?pt=$lng,$lat&z=14';
                final web =
                    'https://yandex.ru/maps/?pt=$lng,$lat&z=14&l=map';
                launchUrl(Uri.parse(deep),
                        mode: LaunchMode.externalApplication)
                    .catchError((_) async {
                  await launchUrl(Uri.parse(web),
                      mode: LaunchMode.externalApplication);
                  return false;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Скопировать координаты'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(
                    ClipboardData(text: '$latStr, $lngStr'));
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Поле ввода ───────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final bool isRecording;
  final ValueNotifier<double> recordingSecondsNotifier;
  final int maxLength;
  final bool locationActive;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onPickVideo;
  final VoidCallback onPickFile;
  final VoidCallback onMicDown;
  final VoidCallback onMicUp;
  final VoidCallback onLocation;

  const _InputBar({
    required this.controller,
    required this.isSending,
    required this.isRecording,
    required this.recordingSecondsNotifier,
    required this.maxLength,
    required this.locationActive,
    required this.onSend,
    required this.onPickImage,
    required this.onPickVideo,
    required this.onPickFile,
    required this.onMicDown,
    required this.onMicUp,
    required this.onLocation,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  int _length = 0;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      if (mounted) setState(() => _length = widget.controller.text.length);
    });
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final near = _length > widget.maxLength * 0.8;
    final over = _length > widget.maxLength;
    final hasText = widget.controller.text.trim().isNotEmpty;

    final cs = Theme.of(context).colorScheme;
    final keyboardVisible = _focusNode.hasFocus;
    final sel = widget.controller.selection;
    final hasSelection =
        sel.isValid && sel.baseOffset != sel.extentOffset;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outline.withValues(alpha: 0.3))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasSelection)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    _FmtBtn(label: 'B', bold: true, onTap: () => _wrapSelection('**', '**')),
                    _FmtBtn(label: 'I', italic: true, onTap: () => _wrapSelection('_', '_')),
                    _FmtBtn(label: 'S', strikethrough: true, onTap: () => _wrapSelection('~~', '~~')),
                    _FmtBtn(label: 'U', underline: true, onTap: () => _wrapSelection('__', '__')),
                    _FmtBtn(label: '||', onTap: () => _wrapSelection('||', '||')),
                  ],
                ),
              ),
            Row(children: [
          if (keyboardVisible)
            IconButton(
              onPressed: () => _focusNode.unfocus(),
              icon: const Icon(Icons.keyboard_hide_outlined),
              color: cs.onSurfaceVariant,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Скрыть клавиатуру',
            ),
          IconButton(
            onPressed: widget.isSending ? null : widget.onPickImage,
            icon: const Icon(Icons.photo_outlined),
            color: cs.onSurfaceVariant,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            onPressed: widget.isSending ? null : widget.onPickFile,
            icon: const Icon(Icons.attach_file_outlined),
            color: cs.onSurfaceVariant,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: 'Прикрепить файл',
          ),
          IconButton(
            onPressed: widget.isSending ? null : widget.onLocation,
            icon: Icon(
              widget.locationActive ? Icons.location_on : Icons.location_on_outlined,
              color: widget.locationActive ? cs.primary : cs.onSurfaceVariant,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: widget.locationActive ? 'Убрать геолокацию' : 'Прикрепить геолокацию',
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
                    enabled: !widget.isRecording,
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: widget.isRecording
                          ? 'Запись... ${s}s.$t'
                          : 'Сообщение...',
                      hintStyle: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
                      border: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      suffix: near
                          ? Text(
                              '${widget.maxLength - _length}',
                              style: TextStyle(
                                fontSize: 11,
                                color: over ? Colors.red : cs.onSurfaceVariant,
                              ),
                            )
                          : null,
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (hasText || widget.isSending)
            GestureDetector(
              onTap: widget.isSending || over || widget.isRecording
                  ? null
                  : widget.onSend,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (widget.isSending || over || widget.isRecording)
                      ? cs.onSurface.withValues(alpha: 0.3)
                      : cs.primary,
                  shape: BoxShape.circle,
                ),
                child: widget.isSending
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.onPrimary))
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
              // Voice record button (tap to start/stop, or hold)
              GestureDetector(
                onTap: widget.isRecording ? widget.onMicUp : widget.onMicDown,
                onLongPressStart: (_) { if (!widget.isRecording) widget.onMicDown(); },
                onLongPressEnd: (_) { if (widget.isRecording) widget.onMicUp(); },
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
                    widget.isRecording ? Icons.stop_rounded : Icons.mic_rounded,
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

// ── Файл/документ ────────────────────────────────────────────────

class _FileMessageBubble extends StatelessWidget {
  final String filePath;
  final String fileName;
  final int? fileSize;
  final bool isOut;

  const _FileMessageBubble({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.isOut,
  });

  String _fmtSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '${bytes} Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  Future<void> _open() async {
    try {
      await launchUrl(Uri.file(filePath), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textColor = isOut ? cs.onPrimary : cs.onSurface;
    final subColor = isOut
        ? cs.onPrimary.withValues(alpha: 0.65)
        : cs.onSurfaceVariant;
    final bgColor = isOut
        ? Colors.black.withValues(alpha: 0.15)
        : cs.surfaceContainerHigh;

    return GestureDetector(
      onTap: _open,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, color: textColor, size: 32),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                  if (fileSize != null)
                    Text(
                      _fmtSize(fileSize),
                      style: TextStyle(fontSize: 11, color: subColor),
                    ),
                ],
              ),
            ),
          ],
        ),
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
    final cs = Theme.of(context).colorScheme;
    final iconColor = isOut ? cs.onPrimary : cs.onSurface;
    final activeColor = isOut ? cs.onPrimary : cs.primary;
    final inactiveColor =
        (isOut ? cs.onPrimary : cs.onSurface).withValues(alpha: 0.35);

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
                try {
                  if (isPlaying) {
                    await VoiceService.instance.stop();
                  } else {
                    await VoiceService.instance.play(voicePath);
                  }
                } catch (e) {
                  debugPrint('[Voice] Playback error: $e');
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
                  painter: _WaveformPainter(
                    seed: voicePath.hashCode,
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

class _WaveformPainter extends CustomPainter {
  final int seed;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  const _WaveformPainter({
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
    final activeBar = (progress * barCount).floor();
    final activePaint = Paint()..color = activeColor;
    final inactivePaint = Paint()..color = inactiveColor;

    for (int i = 0; i < barCount; i++) {
      final heightFraction = 0.25 + rng.nextDouble() * 0.75;
      final h = heightFraction * size.height;
      final x = i * spacing + (spacing - barWidth) / 2;
      final y = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, h),
          const Radius.circular(2),
        ),
        i < activeBar ? activePaint : inactivePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.seed != seed;
}

class _VideoMessageBubble extends StatefulWidget {
  final String videoPath;
  final bool isOut;

  const _VideoMessageBubble({required this.videoPath, required this.isOut});

  @override
  State<_VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends State<_VideoMessageBubble> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _playing = false;

  bool get _isSquare => widget.videoPath.endsWith('_sq.mp4');

  @override
  void initState() {
    super.initState();
    if (_isSquare && File(widget.videoPath).existsSync()) {
      _initPlayer();
    }
  }

  Future<void> _initPlayer() async {
    final ctrl = VideoPlayerController.file(File(widget.videoPath));
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
      debugPrint('[VideoMessage] init error: $e');
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
    return _isSquare ? _buildCircle() : _buildRegular(context);
  }

  Widget _buildCircle() {
    final exists = File(widget.videoPath).existsSync();
    return GestureDetector(
      onTap: exists ? _togglePlay : null,
      child: SizedBox(
        width: 160,
        height: 160,
        child: ClipOval(
          child: Stack(
            children: [
              Positioned.fill(
                child: _initialized && _ctrl != null
                    ? VideoPlayer(_ctrl!)
                    : Container(
                        color: const Color(0xFF1A1A1A),
                        child: exists
                            ? const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white54),
                                ),
                              )
                            : const Center(
                                child: Text('Файл не найден',
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 11),
                                    textAlign: TextAlign.center),
                              ),
                      ),
              ),
              if (exists && !_playing)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    child: const Center(
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 52),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRegular(BuildContext context) {
    final exists = File(widget.videoPath).existsSync();
    return GestureDetector(
      onTap: exists
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _VideoPlayerScreen(path: widget.videoPath),
                ),
              )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Container(
              width: 180,
              height: 180,
              color: Colors.black87,
              child: exists
                  ? null
                  : const Center(
                      child: Text('Файл не найден',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                          textAlign: TextAlign.center),
                    ),
            ),
            if (exists)
              const Positioned.fill(
                child: Center(
                  child: Icon(Icons.play_circle_outline,
                      color: Colors.white, size: 52),
                ),
              ),
            const Positioned(
              bottom: 6,
              right: 8,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.videocam, color: Colors.white70, size: 14),
                SizedBox(width: 4),
                Text('Видео',
                    style: TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Встроенный видеоплеер ─────────────────────────────────────────

class _VideoPlayerScreen extends StatefulWidget {
  final String path;
  const _VideoPlayerScreen({required this.path});

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  late VideoPlayerController _ctrl;
  bool _initialized = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
        _ctrl.play();
      }).catchError((e) {
        debugPrint('[VideoPlayer] init error: $e');
        if (mounted) setState(() => _error = true);
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_initialized)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _ctrl,
              builder: (_, val, __) => IconButton(
                icon: Icon(
                  val.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () {
                  val.isPlaying ? _ctrl.pause() : _ctrl.play();
                },
              ),
            ),
        ],
      ),
      body: Center(
        child: _error
            ? const Text('Ошибка воспроизведения',
                style: TextStyle(color: Colors.white))
            : _initialized
                ? AspectRatio(
                    aspectRatio: _ctrl.value.aspectRatio,
                    child: VideoPlayer(_ctrl),
                  )
                : const CircularProgressIndicator(color: Color(0xFF1DB954)),
      ),
    );
  }
}

// ── Профиль пира (из меню чата) ──────────────────────────────────

class _PeerProfileScreen extends StatefulWidget {
  final String peerId;
  final String nickname;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;

  const _PeerProfileScreen({
    required this.peerId,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
  });

  @override
  State<_PeerProfileScreen> createState() => _PeerProfileScreenState();
}

class _PeerProfileScreenState extends State<_PeerProfileScreen> {
  List<ChatMessage> _images = [];
  List<ChatMessage> _voices = [];
  List<ChatMessage> _files = [];
  List<ChatMessage> _links = [];

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    final msgs = await ChatStorageService.instance.getMessages(widget.peerId, limit: 1000);
    setState(() {
      _images = msgs.where((m) => m.imagePath != null).toList();
      _voices = msgs.where((m) => m.voicePath != null).toList();
      _files = msgs.where((m) => m.filePath != null).toList();
      _links = msgs.where((m) => _hasLink(m.text)).toList();
    });
  }

  bool _hasLink(String text) {
    return RegExp(r'https?://\S+').hasMatch(text);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stories = StoryService.instance.storiesFor(widget.peerId);

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Avatar + name
          Center(
            child: AvatarWidget(
              initials: widget.nickname.isNotEmpty ? widget.nickname[0].toUpperCase() : '?',
              color: widget.avatarColor,
              emoji: widget.avatarEmoji,
              imagePath: widget.avatarImagePath,
              size: 96,
              hasStory: stories.isNotEmpty,
              hasUnviewedStory: StoryService.instance.hasUnviewedStory(widget.peerId),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              widget.nickname,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          Center(
            child: Text(
              '${widget.peerId.substring(0, 16)}...',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.4), fontFamily: 'monospace'),
            ),
          ),

          // Stories section
          if (stories.isNotEmpty) ...[
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.amp_stories),
              title: const Text('Сегодняшняя история'),
              subtitle: Text('${stories.length} историй'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StoryViewerScreen(
                    authorId: widget.peerId,
                    authorName: widget.nickname,
                    stories: stories,
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),
          const Divider(),

          // Media library
          _MediaSection(
            title: 'Фото',
            icon: Icons.photo_outlined,
            count: _images.length,
            child: _images.isEmpty
                ? null
                : SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _images.length,
                      itemBuilder: (_, i) {
                        final path = ImageService.instance.resolveStoredPath(_images[i].imagePath);
                        if (path == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(File(path), width: 80, height: 80, fit: BoxFit.cover),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          _MediaSection(
            title: 'Голосовые',
            icon: Icons.mic_outlined,
            count: _voices.length,
          ),
          _MediaSection(
            title: 'Файлы',
            icon: Icons.attach_file_outlined,
            count: _files.length,
          ),
          _MediaSection(
            title: 'Ссылки',
            icon: Icons.link,
            count: _links.length,
            child: _links.isEmpty
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _links.take(5).map((m) {
                      final match = RegExp(r'https?://\S+').firstMatch(m.text);
                      final url = match?.group(0) ?? '';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: GestureDetector(
                          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                          child: Text(url, style: TextStyle(color: cs.primary, fontSize: 13, decoration: TextDecoration.underline)),
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MediaSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final int count;
  final Widget? child;

  const _MediaSection({
    required this.title,
    required this.icon,
    required this.count,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('$count', style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
          ]),
          if (child != null) ...[
            const SizedBox(height: 8),
            child!,
          ],
        ],
      ),
    );
  }
}

class _RichMessageText extends StatelessWidget {
  final String text;
  final bool isOut;

  const _RichMessageText({required this.text, required this.isOut});

  static final _urlRegex = RegExp(r'https?://\S+');

  // Combined regex — order matters: longer/more specific markers first
  // group 1: **bold**, group 2: __underline__, group 3: ~~strike~~,
  // group 4: _italic_, group 5: ||spoiler||, otherwise URL
  static final _fmtRegex = RegExp(
    r'\*\*([\s\S]*?)\*\*|__([\s\S]*?)__|~~([\s\S]*?)~~|_([\s\S]*?)_|\|\|([\s\S]*?)\|\||https?://\S+',
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textColor = isOut ? cs.onPrimary : cs.onSurface;
    final urlMatches = _urlRegex.allMatches(text).toList();

    return Column(
      crossAxisAlignment:
          isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _buildRichText(context, textColor),
        ...urlMatches
            .map((m) => _LinkPreviewCard(url: m.group(0)!, isOut: isOut)),
      ],
    );
  }

  Widget _buildRichText(BuildContext context, Color textColor) {
    final cs = Theme.of(context).colorScheme;
    final matches = _fmtRegex.allMatches(text).toList();

    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: textColor, fontSize: 15));
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;
    final baseStyle = TextStyle(color: textColor, fontSize: 15);

    void addPlain(String s) {
      if (s.isEmpty) return;
      spans.add(TextSpan(text: s, style: baseStyle));
    }

    for (final match in matches) {
      if (match.start > lastEnd) {
        addPlain(text.substring(lastEnd, match.start));
      }

      final full = match.group(0)!;

      if (match.group(1) != null) {
        // **bold**
        spans.add(TextSpan(
          text: match.group(1)!,
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(2) != null) {
        // __underline__
        spans.add(TextSpan(
          text: match.group(2)!,
          style: baseStyle.copyWith(decoration: TextDecoration.underline),
        ));
      } else if (match.group(3) != null) {
        // ~~strikethrough~~
        spans.add(TextSpan(
          text: match.group(3)!,
          style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
        ));
      } else if (match.group(4) != null) {
        // _italic_
        spans.add(TextSpan(
          text: match.group(4)!,
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(5) != null) {
        // ||spoiler||
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _SpoilerText(text: match.group(5)!, style: baseStyle),
        ));
      } else {
        // URL
        final url = full;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () => launchUrl(Uri.parse(url),
                mode: LaunchMode.externalApplication),
            child: Text(
              url,
              style: baseStyle.copyWith(
                color: isOut
                    ? Colors.white.withValues(alpha: 0.9)
                    : cs.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ));
      }

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      addPlain(text.substring(lastEnd));
    }

    return RichText(text: TextSpan(children: spans));
  }
}

// ── Кнопка форматирования ──────────────────────────────────────────

class _FmtBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool underline;

  const _FmtBtn({
    required this.label,
    required this.onTap,
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.underline = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            decoration: strikethrough
                ? TextDecoration.lineThrough
                : underline
                    ? TextDecoration.underline
                    : null,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

// ── Спойлер ───────────────────────────────────────────────────────

class _SpoilerText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _SpoilerText({required this.text, required this.style});

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: _revealed
          ? Text(widget.text, style: widget.style)
          : Text(
              '▓' * widget.text.length.clamp(1, 20),
              style: widget.style.copyWith(
                color: widget.style.color?.withValues(alpha: 0.5),
                letterSpacing: 1,
              ),
            ),
    );
  }
}

// ── Карточка предпросмотра ссылки ─────────────────────────────────

class _LinkPreviewCard extends StatelessWidget {
  final String url;
  final bool isOut;

  const _LinkPreviewCard({required this.url, required this.isOut});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uri = Uri.tryParse(url);
    final domain = uri?.host ?? url;

    return GestureDetector(
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isOut
              ? Colors.black.withValues(alpha: 0.15)
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              color:
                  isOut ? Colors.white.withValues(alpha: 0.4) : cs.primary,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.language,
                  size: 14,
                  color: isOut ? Colors.white70 : cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  domain,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isOut ? Colors.white : cs.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              url,
              style: TextStyle(
                fontSize: 11,
                color: isOut
                    ? Colors.white60
                    : cs.onSurface.withValues(alpha: 0.5),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
