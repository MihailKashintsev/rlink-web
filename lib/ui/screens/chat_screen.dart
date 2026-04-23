import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../main.dart' show IncomingMessage, incomingMessageController;
import '../../models/channel.dart';
import '../../models/chat_message.dart';
import '../../models/group.dart';
import '../../models/shared_collab.dart';
import '../../models/contact.dart';
import '../../services/ai_bot_constants.dart';
import '../../services/app_settings.dart';
import '../../services/gigachat_service.dart';
import '../../services/ble_service.dart';
import '../../services/block_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/channel_service.dart';
import '../../services/group_service.dart';
import '../../services/outbound_dm_text.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/sticker_collection_service.dart';
import '../../services/profile_service.dart';
import '../../services/voice_service.dart';
import '../../services/embedded_video_pause_bus.dart';
import '../../services/story_service.dart';
import '../../services/typing_service.dart';
import '../../services/relay_service.dart';
import '../../services/media_upload_queue.dart';
import '../../utils/channel_mentions.dart';
import '../../utils/invite_dm_codec.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';
import 'image_editor_screen.dart';
import 'profile_screen.dart';
import 'square_video_recorder_screen.dart';
import 'story_viewer_screen.dart';
import 'collab_compose_dialogs.dart';
import 'channels_screen.dart';
import 'groups_screen.dart';
import '../widgets/shared_todo_message_card.dart';
import '../widgets/shared_calendar_message_card.dart';
import '../widgets/missing_local_media.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/swipe_to_reply.dart';
import 'peer_stickers_screen.dart';
import '../widgets/media_gallery_send_sheet.dart';
import '../widgets/dm_video_fullscreen_page.dart';
import '../widgets/telegram_media_record_button.dart';
import '../widgets/hold_square_video_review_screen.dart';
import '../widgets/square_video_recording_widgets.dart';
import '../widgets/forward_target_sheet.dart';
import '../mention_nav.dart';

bool _dmVideoPathIsSquare(String path) =>
    p.basename(path).toLowerCase().endsWith('_sq.mp4');

bool _dmPlaybackFileNameIsAudio(String fileName) {
  const exts = {
    '.mp3', '.ogg', '.wav', '.m4a', '.aac', '.flac', '.opus', '.wma', '.mp4a',
  };
  final n = fileName.toLowerCase();
  for (final e in exts) {
    if (n.endsWith(e)) return true;
  }
  return false;
}

String? _dmResolveMsgPath(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final r = ImageService.instance.resolveStoredPath(raw) ?? raw;
  return File(r).existsSync() ? r : null;
}

/// Очередь «с этого сообщения до конца»: голосовые, аудио-файлы, квадратики.
List<PlaybackQueueItem> _dmPlaybackQueueFrom(
  List<ChatMessage> messages,
  int startIndex,
) {
  final out = <PlaybackQueueItem>[];
  for (var i = startIndex; i < messages.length; i++) {
    final m = messages[i];
    if (dmMessageMissingLocalMedia(m)) continue;

    final voice = _dmResolveMsgPath(m.voicePath);
    if (voice != null) {
      out.add(PlaybackQueueItem(
        path: voice,
        title: 'Голосовое',
        kind: PlaybackMediaKind.voice,
      ));
      continue;
    }

    if (m.filePath != null && m.fileName != null) {
      final fp = _dmResolveMsgPath(m.filePath);
      if (fp != null && _dmPlaybackFileNameIsAudio(m.fileName!)) {
        out.add(PlaybackQueueItem(
          path: fp,
          title: m.fileName!,
          kind: PlaybackMediaKind.audioFile,
        ));
        continue;
      }
    }

    if (m.videoPath != null && _dmVideoPathIsSquare(m.videoPath!)) {
      final vp = _dmResolveMsgPath(m.videoPath);
      if (vp != null) {
        out.add(PlaybackQueueItem(
          path: vp,
          title: 'Видеосообщение',
          kind: PlaybackMediaKind.squareVideo,
        ));
      }
    }
  }
  return out;
}

/// Пересылка в этот чат: оригинальное сообщение и контекст автора.
class DmForwardDraft {
  final ChatMessage message;
  /// Собеседник чата, из которого пересылаем (личный чат).
  final String sourcePeerId;
  final String originalAuthorNick;
  /// Публичный ключ автора оригинала (Ed25519 hex).
  final String forwardAuthorId;
  /// Переслано из канала (для открытия ленты по тапу).
  final String? forwardChannelId;

  const DmForwardDraft({
    required this.message,
    required this.sourcePeerId,
    required this.originalAuthorNick,
    required this.forwardAuthorId,
    this.forwardChannelId,
  });
}

class ChatScreen extends StatefulWidget {
  final String peerId; // Ed25519 public key получателя
  final String peerNickname;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;
  final DmForwardDraft? forwardDraft;

  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerNickname,
    required this.peerAvatarColor,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
    this.forwardDraft,
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
  /// MsgIds currently uploading in background (for the "Загружается файл..." bar)
  final Set<String> _uploadingMsgIds = {};
  StreamSubscription<IncomingMessage>? _msgSub;
  // Резолвленный публичный ключ пира (может отличаться от widget.peerId если тот BLE UUID)
  late String _resolvedPeerId;
  String? _replyToMessageId;
  String? _replyPreviewText;
  String? _editingMessageId;
  String? _editingPreviewText;
  bool _isRecording = false;
  /// Подготовка камеры для удержания «видеоквадратика».
  bool _dmHoldVideoStarting = false;
  CameraController? _dmHoldVideoCam;
  /// Инвалидация асинхронного старта камеры при отмене.
  int _dmHoldSession = 0;
  /// Видео в режиме «зажим» (свайп вверх).
  bool _dmHoldLockedWhileVideo = false;
  final _dmHoldVideoPausedNotifier = ValueNotifier<bool>(false);
  List<CameraDescription> _dmHoldCameraList = [];
  int _dmHoldCameraIndex = 0;
  final List<String> _dmHoldVideoSegments = [];
  bool _dmHoldSwitchingCam = false;
  final _recordingSecondsNotifier = ValueNotifier<double>(0);
  Timer? _recordingTimer;
  double? _pendingLat;
  double? _pendingLng;
  Timer? _typingDebounce;
  bool _strangerBannerDismissed = false;
  bool _isContact = false;
  VoidCallback? _contactListener;
  List<String> _pinnedIdsChrono = [];
  final Set<String> _pinnedMsgIds = {};
  String? _pinBarHighlightId;
  bool _forwardStarted = false;
  VoidCallback? _pinsListener;
  bool _showScrollToBottomFab = false;
  String? _lastQuickPointerMsgId;
  DateTime? _lastQuickPointerAt;
  int _lastPinSyncMessageCount = -1;
  bool _pendingMessageCountPinSync = false;
  bool _aiThinking = false;
  StreamSubscription<List<ConnectivityResult>>? _vpnConnSub;
  /// Только для GigaChat: на iOS/Android [ConnectivityResult.vpn] из connectivity_plus.
  bool _vpnProbablyActive = false;

  bool get _isAiBot => widget.peerId == kAiBotPeerId;

  /// Диалог «Избранное» (peer_id = наш ключ): только локальная БД, без mesh/relay.
  bool get _savedMessagesLocalOnly {
    final my = CryptoService.instance.publicKeyHex;
    if (my.isEmpty) return false;
    final peer =
        _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId;
    return peer == my;
  }

  /// Max blob size for single relay message (~800KB compressed).
  /// Larger data is split into relay-friendly gossip chunks (50KB each).
  static const _kMaxBlobBytes = 800 * 1024;

  /// Relay chunk size for large media — 30 KB raw → ~53 KB after double-base64 wrap.
  static const _kRelayChunkBytes = 30 * 1024;

  /// Send media: relay blob over internet, BLE chunks for mesh.
  /// Returns true if the file was queued for background upload (status = sending).
  Future<bool> _sendMedia({
    required Uint8List bytes,
    required String msgId,
    required String myId,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    bool isSticker = false,
    String? fileName,
    String? filePath, // local file path for upload queue (large file resume)
  }) async {
    if (_isAiBot) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('В чате с ИИ доступен только текст')),
        );
      }
      return false;
    }
    if (_savedMessagesLocalOnly) return false;

    bool blobSent = false;
    bool wasQueued = false;

    // 1. Relay — fast delivery over internet.
    // Always prefer relay for media when it is available, regardless of the
    // connection-mode setting (that only controls text routing preference).
    // Upload queue gives progress tracking, resume on disconnect, and keeps
    // large files out of RAM.  In-memory fallback only when no filePath given.
    if (RelayService.instance.isConnected) {
      try {
        if (filePath != null && File(filePath).existsSync()) {
          // Queue-based send (all sizes) — progress shown on bubble overlay
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: msgId,
            filePath: filePath,
            recipientKey: _resolvedPeerId,
            fromId: myId,
            isVoice: isVoice,
            isVideo: isVideo,
            isSquare: isSquare,
            isFile: isFile,
            isSticker: isSticker,
            fileName: fileName,
          ));
          blobSent = true;
          wasQueued = true;
          debugPrint('[RLINK][Media] Queued for upload: ${bytes.length} bytes raw');
        } else {
          // No persistent file — in-memory send (voice from RAM, etc.)
          final compressed = ImageService.instance.compress(bytes);
          if (compressed.length <= _kMaxBlobBytes) {
            await RelayService.instance.sendBlob(
              recipientKey: _resolvedPeerId,
              fromId: myId,
              msgId: msgId,
              compressedData: compressed,
              isVoice: isVoice,
              isVideo: isVideo,
              isSquare: isSquare,
              isFile: isFile,
              isSticker: isSticker,
              fileName: fileName,
            );
            debugPrint('[RLINK][Media] In-memory blob sent: ${compressed.length} bytes');
          } else {
            final total = (compressed.length / _kRelayChunkBytes).ceil();
            debugPrint('[RLINK][Media] Fallback in-memory chunks: $total');
            _sendBlobChunksInBackground(
              compressed: compressed,
              msgId: msgId,
              myId: myId,
              total: total,
              isVoice: isVoice,
              isVideo: isVideo,
              isSquare: isSquare,
              isFile: isFile,
              isSticker: isSticker,
              fileName: fileName,
            );
          }
          blobSent = true;
        }
      } catch (e) {
        debugPrint('[RLINK][Media] Relay media failed: $e');
      }
    }

    // 2. BLE gossip chunks — only when relay is unavailable.
    if (!blobSent) {
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      debugPrint('[RLINK][Media] Relay unavailable — sending ${chunks.length} BLE gossip chunks');
      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myId,
        recipientId: _resolvedPeerId,
        isVoice: isVoice,
        isVideo: isVideo,
        isSquare: isSquare,
        isFile: isFile,
        isSticker: isSticker,
        fileName: fileName,
      );
      _sendChunksInBackground(chunks, msgId, myId);
    }
    return wasQueued;
  }

  /// Send gossip chunks in background — does NOT block the UI or other sends.
  void _sendChunksInBackground(List<String> chunks, String msgId, String myId) {
    () async {
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId, index: i, base64Data: chunks[i],
          fromId: myId, recipientId: _resolvedPeerId,
        );
      }
      debugPrint('[RLINK][Media] All ${chunks.length} gossip chunks sent for $msgId');
    }();
  }

  /// Send large blob as relay-native chunks in background. Each chunk is a
  /// standalone 'packet' envelope so relay routes them reliably (no 500-byte
  /// gossip size cap).
  void _sendBlobChunksInBackground({
    required Uint8List compressed,
    required String msgId,
    required String myId,
    required int total,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    bool isSticker = false,
    String? fileName,
  }) {
    () async {
      for (var i = 0; i < total; i++) {
        final offset = i * _kRelayChunkBytes;
        final end = (offset + _kRelayChunkBytes) > compressed.length
            ? compressed.length
            : offset + _kRelayChunkBytes;
        final chunk = Uint8List.sublistView(compressed, offset, end);
        await RelayService.instance.sendBlobChunk(
          recipientKey: _resolvedPeerId,
          fromId: myId,
          msgId: msgId,
          chunkIdx: i,
          chunkTotal: total,
          chunkData: chunk,
          isVoice: isVoice,
          isVideo: isVideo,
          isSquare: isSquare,
          isFile: isFile,
          isSticker: isSticker,
          fileName: fileName,
        );
        // Gentle pacing — relay allows ~30 msgs/sec, we stay at 20/sec.
        await Future.delayed(const Duration(milliseconds: 50));
      }
      debugPrint('[RLINK][Media] All $total blob chunks sent for $msgId');
    }();
  }

  // BLE ATT MTU ≈ 288 байт. Фиксированный overhead пакета ≈ 186 байт
  // (id36 + t + ttl + ts + from64 + r8 + структура JSON).
  // Оставляем 90 символов для текста — гарантированно уместится в MTU.
  static const _kMaxMessageLength = 90;
  static final _publicKeyRegExp = RegExp(r'^[0-9a-fA-F]{64}$');

  bool _looksLikePublicKey(String id) => _publicKeyRegExp.hasMatch(id.trim());

  /// Квадратное видеосообщение (камера): только суффикс имени файла `_sq.mp4`.
  static bool _videoPathIsSquare(String path) => _dmVideoPathIsSquare(path);

  /// Checks DB and updates [_isContact]. Called on init and whenever contacts change.
  Future<void> _checkContactStatus() async {
    final key = _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId;
    final contact = await ChatStorageService.instance.getContact(key);
    if (mounted) setState(() => _isContact = contact != null);
  }

  Future<bool> _waitForPeerPublicKey(
      {Duration timeout = const Duration(seconds: 6)}) async {
    final deadline = DateTime.now().add(timeout);
    while (mounted && DateTime.now().isBefore(deadline)) {
      final resolved = BleService.instance.resolvePublicKey(widget.peerId);
      if (_looksLikePublicKey(resolved)) {
        if (!mounted) return false;
        setState(() => _resolvedPeerId = resolved);
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<bool> _ensureReadyForMediaSend() async {
    if (_isSending) return false;
    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Подождите — идёт обмен профилями')),
          );
        }
        return false;
      }
    }
    if (CryptoService.instance.publicKeyHex.isEmpty) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    _resolvedPeerId = widget.peerId == kAiBotPeerId
        ? kAiBotPeerId
        : BleService.instance.resolvePublicKey(widget.peerId);
    unawaited(_loadAndMarkRead());
    unawaited(_checkContactStatus());
    _pinsListener = () {
      if (mounted) unawaited(_reloadPins());
    };
    ChatStorageService.instance.pinsVersion.addListener(_pinsListener!);
    _scrollController.addListener(_onScrollForPins);
    unawaited(_reloadPins());
    if (widget.forwardDraft != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_forwardStarted || !mounted) return;
        _forwardStarted = true;
        unawaited(_runPendingForward());
      });
    }
    _controller.addListener(_onTyping);
    // Следим за изменением маппингов BLE UUID → public key
    BleService.instance.peersCount.addListener(_onPeersChanged);
    BleService.instance.peerMappingsVersion.addListener(_onPeersChanged);
    // Следим за изменением списка контактов
    _contactListener = () => _checkContactStatus();
    ChatStorageService.instance.contactsNotifier.addListener(_contactListener!);
    // Update message status + clear uploading indicator when background upload finishes
    MediaUploadQueue.instance.onTaskCompleted = (msgId) async {
      if (!mounted) return;
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId, MessageStatus.sent);
      if (mounted) setState(() => _uploadingMsgIds.remove(msgId));
    };

    if (_isAiBot) {
      unawaited(_refreshGigachatVpnFlag());
      _vpnConnSub = Connectivity().onConnectivityChanged.listen((results) {
        if (!mounted) return;
        final on = results.contains(ConnectivityResult.vpn);
        if (on != _vpnProbablyActive) {
          setState(() => _vpnProbablyActive = on);
        }
      });
    }

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
      if (mounted) {
        _recomputePinHighlight(
            ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value);
        _scrollToBottom();
        unawaited(ChatStorageService.instance.markDmRead(_resolvedPeerId));
      }
    });
  }

  void _onPeersChanged() {
    if (!mounted) return;
    if (widget.peerId == kAiBotPeerId) return;
    final resolved = BleService.instance.resolvePublicKey(widget.peerId);
    if (resolved != _resolvedPeerId && resolved != widget.peerId) {
      if (!mounted) return;
      setState(() => _resolvedPeerId = resolved);
      // Перезагружаем сообщения под правильным публичным ключом
      ChatStorageService.instance.loadMessages(_resolvedPeerId);
    }
    // Key may have just resolved — re-check contact status
    unawaited(_checkContactStatus());
  }

  void _onTyping() {
    _typingDebounce?.cancel();
    if (_controller.text.isNotEmpty) {
      _sendActivity(Activity.typing);
      // Auto-stop after 4s of no typing
      _typingDebounce = Timer(const Duration(seconds: 4), () {
        _sendActivity(Activity.stopped);
      });
    } else {
      _sendActivity(Activity.stopped);
    }
  }

  void _sendActivity(int activity) {
    if (_isAiBot) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty || _savedMessagesLocalOnly) return;
    GossipRouter.instance.sendTypingIndicator(
      fromId: myId,
      recipientId: _resolvedPeerId,
      activity: activity,
    );
  }

  @override
  void dispose() {
    final peerForRead = _resolvedPeerId;
    _vpnConnSub?.cancel();
    _vpnConnSub = null;
    _typingDebounce?.cancel();
    _sendActivity(Activity.stopped);
    // Сначала отменяем поток — иначе async-обработчик может дернуть scroll/setState
    // после dispose контроллера и сломать дерево виджетов.
    _msgSub?.cancel();
    _msgSub = null;
    if (_pinsListener != null) {
      ChatStorageService.instance.pinsVersion.removeListener(_pinsListener!);
    }
    _scrollController.removeListener(_onScrollForPins);
    _controller.removeListener(_onTyping);
    BleService.instance.peersCount.removeListener(_onPeersChanged);
    BleService.instance.peerMappingsVersion.removeListener(_onPeersChanged);
    if (_contactListener != null) {
      ChatStorageService.instance.contactsNotifier.removeListener(_contactListener!);
    }
    MediaUploadQueue.instance.onTaskCompleted = null;
    _recordingTimer?.cancel();
    final vCam = _dmHoldVideoCam;
    _dmHoldVideoCam = null;
    for (final path in _dmHoldVideoSegments) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    _dmHoldVideoSegments.clear();
    _dmHoldCameraList = [];
    if (vCam != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          vCam.dispose();
        } catch (_) {}
      });
    }
    _dmHoldVideoPausedNotifier.dispose();
    _recordingSecondsNotifier.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
    scheduleMicrotask(() {
      unawaited(ChatStorageService.instance.markDmRead(peerForRead));
    });
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
    _sendActivity(Activity.recordingVoice);
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
    _sendActivity(Activity.stopped);

    if (path == null || duration < 0.5) return;
    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) return;
    }

    try {
      final bytes = await File(path).readAsBytes();
      final msgId = _uuid.v4();
      final myId = CryptoService.instance.publicKeyHex;
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      final wasQueued = await _sendMedia(
          bytes: bytes, msgId: msgId, myId: myId, isVoice: true, filePath: path);

      await _saveAndTrack(ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '🎤 Голосовое',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        voicePath: path,
      ), wasQueued: wasQueued);
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

  /// Отмена записи (свайп / корзина в закреплённом режиме).
  Future<void> _cancelActiveMediaRecording() async {
    _dmHoldSession++;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingSecondsNotifier.value = 0;

    if (_dmHoldVideoCam != null) {
      final ctrl = _dmHoldVideoCam;
      _dmHoldVideoCam = null;
      _dmHoldLockedWhileVideo = false;
      _dmHoldVideoPausedNotifier.value = false;
      for (final path in _dmHoldVideoSegments) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      _dmHoldVideoSegments.clear();
      _dmHoldCameraList = [];
      try {
        if (ctrl!.value.isRecordingVideo) {
          final x = await ctrl.stopVideoRecording();
          try {
            await File(x.path).delete();
          } catch (_) {}
        }
      } catch (_) {}
      try {
        await ctrl?.dispose();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isRecording = false;
          _dmHoldVideoStarting = false;
        });
      }
      _sendActivity(Activity.stopped);
      return;
    }

    if (_isRecording) {
      await VoiceService.instance.cancelRecording();
      if (mounted) setState(() => _isRecording = false);
    }
    if (mounted) setState(() => _dmHoldVideoStarting = false);
    _sendActivity(Activity.stopped);
  }

  Future<void> _startDmHoldSquareVideo() async {
    if (_isSending) return;
    if (!mounted) return;
    final session = ++_dmHoldSession;
    _dmHoldLockedWhileVideo = false;
    _dmHoldVideoPausedNotifier.value = false;
    setState(() => _dmHoldVideoStarting = true);

    CameraController? ctrl;
    try {
      final raw = await availableCameras();
      if (!mounted || session != _dmHoldSession) return;
      for (final path in _dmHoldVideoSegments) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      _dmHoldVideoSegments.clear();
      _dmHoldCameraList = logicalCamerasForSquareVideo(raw);
      if (_dmHoldCameraList.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Камера недоступна')),
          );
        }
        return;
      }
      var idx = _dmHoldCameraList
          .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      if (idx < 0) idx = 0;
      _dmHoldCameraIndex = idx;
      ctrl = CameraController(
        _dmHoldCameraList[idx],
        ResolutionPreset.low,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      if (!mounted || session != _dmHoldSession) {
        await ctrl.dispose();
        return;
      }
      await ctrl.startVideoRecording();
      if (!mounted || session != _dmHoldSession) {
        try {
          final x = await ctrl.stopVideoRecording();
          try {
            await File(x.path).delete();
          } catch (_) {}
        } catch (_) {}
        await ctrl.dispose();
        return;
      }
      _dmHoldVideoCam = ctrl;
      ctrl = null;

      _recordingSecondsNotifier.value = 0;
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || _dmHoldVideoCam == null) return;
        if (_dmHoldVideoPausedNotifier.value) return;
        _recordingSecondsNotifier.value += 0.25;
        if (_recordingSecondsNotifier.value >= 15) {
          unawaited(_finishDmHoldSquareVideo(send: true));
        }
      });
      if (mounted) {
        setState(() {
          _isRecording = true;
          _dmHoldVideoStarting = false;
        });
      }
      EmbeddedVideoPauseBus.instance.bump();
      unawaited(VoiceService.instance.stopPlayback());
      _sendActivity(Activity.recordingVideo);
    } catch (e) {
      debugPrint('[DmHoldVideo] $e');
      if (ctrl != null) {
        try {
          await ctrl.dispose();
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Камера: $e')),
        );
      }
    } finally {
      if (mounted && _dmHoldVideoCam == null && session == _dmHoldSession) {
        setState(() => _dmHoldVideoStarting = false);
      }
    }
  }

  Future<void> _finishDmHoldSquareVideo({required bool send}) async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _dmHoldLockedWhileVideo = false;
    _dmHoldVideoPausedNotifier.value = false;

    final ctrl = _dmHoldVideoCam;
    _dmHoldVideoCam = null;
    XFile? file;
    if (ctrl != null) {
      try {
        if (ctrl.value.isRecordingVideo) {
          file = await ctrl.stopVideoRecording();
        }
      } catch (e) {
        debugPrint('[DmHoldVideo] stop: $e');
      }
      try {
        await ctrl.dispose();
      } catch (_) {}
    }
    _dmHoldCameraList = [];
    _recordingSecondsNotifier.value = 0;
    if (mounted) setState(() => _isRecording = false);
    _sendActivity(Activity.stopped);

    if (!send) {
      for (final path in _dmHoldVideoSegments) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      _dmHoldVideoSegments.clear();
      if (file != null) {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
      return;
    }

    final segments = List<String>.from(_dmHoldVideoSegments);
    _dmHoldVideoSegments.clear();
    if (file != null && file.path.isNotEmpty) {
      segments.add(file.path);
    }
    if (segments.isEmpty) return;

    String rawPath;
    if (segments.length == 1) {
      rawPath = segments.single;
    } else {
      final merged = await ImageService.instance.mergeVideoSegments(segments);
      if (merged != null) {
        rawPath = merged;
        for (final p in segments) {
          try {
            await File(p).delete();
          } catch (_) {}
        }
      } else {
        rawPath = segments.last;
        for (var i = 0; i < segments.length - 1; i++) {
          try {
            await File(segments[i]).delete();
          } catch (_) {}
        }
      }
    }

    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Подождите — идёт обмен профилями')),
          );
        }
        try {
          await File(rawPath).delete();
        } catch (_) {}
        return;
      }
    }
    if (!mounted) return;
    final chosen = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => HoldSquareVideoReviewScreen(
          videoPath: rawPath,
          allowTrim: true,
        ),
      ),
    );
    if (!mounted) return;
    if (chosen == null || chosen.isEmpty) {
      try {
        await File(rawPath).delete();
      } catch (_) {}
      return;
    }
    if (chosen != rawPath) {
      try {
        await File(rawPath).delete();
      } catch (_) {}
    }
    await _publishSquareVideoFromDisk(chosen);
    if (chosen != rawPath) {
      try {
        await File(chosen).delete();
      } catch (_) {}
    }
  }

  void _onHoldRecordingLockChanged(bool locked) {
    if (!locked) return;
    if (_dmHoldVideoCam != null) {
      setState(() => _dmHoldLockedWhileVideo = true);
    }
  }

  Future<void> _toggleDmHoldVideoPause() async {
    final cam = _dmHoldVideoCam;
    if (cam == null || !cam.value.isInitialized) return;
    try {
      if (_dmHoldVideoPausedNotifier.value) {
        await cam.resumeVideoRecording();
        if (mounted) _dmHoldVideoPausedNotifier.value = false;
      } else {
        await cam.pauseVideoRecording();
        if (mounted) _dmHoldVideoPausedNotifier.value = true;
      }
    } catch (e) {
      debugPrint('[DmHoldVideo] pause toggle: $e');
    }
  }

  Future<void> _switchDmHoldCamera() async {
    final session = _dmHoldSession;
    final ctrl = _dmHoldVideoCam;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        !ctrl.value.isRecordingVideo ||
        _dmHoldSwitchingCam ||
        _dmHoldCameraList.length < 2) {
      return;
    }
    setState(() => _dmHoldSwitchingCam = true);
    CameraController? newCam;
    try {
      final stopped = await ctrl.stopVideoRecording();
      _dmHoldVideoSegments.add(stopped.path);
      final next = (_dmHoldCameraIndex + 1) % _dmHoldCameraList.length;
      await ctrl.dispose();
      _dmHoldVideoCam = null;
      if (!mounted || session != _dmHoldSession) {
        for (final p in _dmHoldVideoSegments) {
          try {
            await File(p).delete();
          } catch (_) {}
        }
        _dmHoldVideoSegments.clear();
        return;
      }
      _dmHoldCameraIndex = next;
      newCam = CameraController(
        _dmHoldCameraList[next],
        ResolutionPreset.low,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await newCam.initialize();
      if (!mounted || session != _dmHoldSession) {
        await newCam.dispose();
        for (final p in _dmHoldVideoSegments) {
          try {
            await File(p).delete();
          } catch (_) {}
        }
        _dmHoldVideoSegments.clear();
        return;
      }
      await newCam.startVideoRecording();
      if (_dmHoldVideoPausedNotifier.value) {
        try {
          await newCam.pauseVideoRecording();
        } catch (_) {
          if (mounted) _dmHoldVideoPausedNotifier.value = false;
        }
      }
      if (!mounted || session != _dmHoldSession) {
        try {
          if (newCam.value.isRecordingVideo) {
            final x = await newCam.stopVideoRecording();
            try {
              await File(x.path).delete();
            } catch (_) {}
          }
        } catch (_) {}
        await newCam.dispose();
        for (final p in _dmHoldVideoSegments) {
          try {
            await File(p).delete();
          } catch (_) {}
        }
        _dmHoldVideoSegments.clear();
        return;
      }
      setState(() => _dmHoldVideoCam = newCam);
    } catch (e) {
      debugPrint('[DmHoldVideo] switch cam: $e');
      await newCam?.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Смена камеры: $e')),
        );
      }
      _recordingTimer?.cancel();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _dmHoldVideoCam = null;
        });
      } else {
        _dmHoldVideoCam = null;
      }
      for (final p in _dmHoldVideoSegments) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
      _dmHoldVideoSegments.clear();
      _sendActivity(Activity.stopped);
    } finally {
      if (mounted && session == _dmHoldSession) {
        setState(() => _dmHoldSwitchingCam = false);
      }
    }
  }

  /// Общая отправка квадратного видео (полноэкранный рекордер или удержание).
  Future<void> _publishSquareVideoFromDisk(String rawVideoPath) async {
    if (_isSending) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ошибка: приложение еще не готово'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(() => _isSending = true);
    try {
      final path =
          await ImageService.instance.saveVideo(rawVideoPath, isSquare: true);
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      var wasQueued = false;
      if (!_savedMessagesLocalOnly) {
        if (RelayService.instance.isConnected) {
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: msgId,
            filePath: path,
            recipientKey: _resolvedPeerId,
            fromId: myId,
            isVideo: true,
            isSquare: true,
          ));
          wasQueued = true;
        } else {
          final bytes = await File(path).readAsBytes();
          await _sendMedia(
            bytes: bytes,
            msgId: msgId,
            myId: myId,
            isVideo: true,
            isSquare: true,
            filePath: path,
          );
        }
      }

      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: '⬛ Видео',
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          videoPath: path,
        ),
        wasQueued: wasQueued,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка видео: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
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
      // Check if location services are enabled (required on Android)
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Включите геолокацию в настройках телефона')),
          );
        }
        return;
      }
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
      // Use AndroidSettings on Android to ensure LocationManager is used
      // and avoid issues with Google Play Services location API.
      final LocationSettings locationSettings;
      if (Platform.isAndroid) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 15),
          forceLocationManager: true,
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.lowest,
          timeLimit: Duration(seconds: 10),
        );
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
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

  Future<void> _loadAndMarkRead() async {
    await _load();
    if (mounted) {
      await ChatStorageService.instance.markDmRead(_resolvedPeerId);
    }
  }

  Future<void> _reloadPins() async {
    final ids = await ChatStorageService.instance
        .getPinnedMessageIdsChrono(_resolvedPeerId);
    if (!mounted) return;
    setState(() {
      _pinnedIdsChrono = ids;
      _pinnedMsgIds
        ..clear()
        ..addAll(ids);
      _recomputePinHighlight(
          ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value);
    });
  }

  void _onScrollForPins() {
    if (!mounted) return;
    ScrollPosition? pos;
    try {
      pos = _scrollController.hasClients ? _scrollController.position : null;
    } catch (_) {
      return;
    }
    if (pos != null) {
      final awayFromBottom = pos.maxScrollExtent - pos.pixels;
      final showFab = awayFromBottom > 120;
      if (showFab != _showScrollToBottomFab) {
        if (mounted) setState(() => _showScrollToBottomFab = showFab);
      }
    }
    final msgs =
        ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value;
    _recomputePinHighlight(msgs);
  }

  void _recomputePinHighlight(List<ChatMessage> messages) {
    if (!mounted) return;
    if (_pinnedIdsChrono.isEmpty) {
      if (_pinBarHighlightId != null) {
        if (mounted) setState(() => _pinBarHighlightId = null);
      }
      return;
    }
    const estH = 72.0;
    double scroll = 0;
    try {
      final pos =
          _scrollController.hasClients ? _scrollController.position : null;
      scroll = pos?.pixels ?? 0;
    } catch (_) {
      scroll = 0;
    }
    final firstIdx =
        (scroll / estH).floor().clamp(0, messages.isEmpty ? 0 : messages.length - 1);
    String? bestId;
    var bestIdx = -1;
    for (final pid in _pinnedIdsChrono) {
      final idx = messages.indexWhere((m) => m.id == pid);
      if (idx < 0) continue;
      if (idx < firstIdx && idx > bestIdx) {
        bestIdx = idx;
        bestId = pid;
      }
    }
    bestId ??= _pinnedIdsChrono.isNotEmpty ? _pinnedIdsChrono.last : null;
    if (bestId != _pinBarHighlightId) {
      if (mounted) setState(() => _pinBarHighlightId = bestId);
    }
  }

  Widget _buildPinnedBar(List<ChatMessage> messages) {
    final cs = Theme.of(context).colorScheme;
    final hid = _pinBarHighlightId;
    ChatMessage? mFor(String? id) {
      if (id == null) return null;
      for (final m in messages) {
        if (m.id == id) return m;
      }
      return null;
    }

    final hi = mFor(hid);
    String preview(ChatMessage? m) {
      if (m == null) return 'Закреплённое сообщение';
      if (m.text.trim().isNotEmpty) {
        final t = m.text.trim();
        return t.length > 72 ? '${t.substring(0, 72)}…' : t;
      }
      if (m.imagePath != null) return '📷 Фото';
      if (m.videoPath != null) return '📹 Видео';
      if (m.voicePath != null) return '🎤 Голосовое';
      if (m.filePath != null) return '📎 ${m.fileName ?? 'Файл'}';
      return 'Сообщение';
    }

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
      child: InkWell(
        onTap: () async {
          await showModalBottomSheet<void>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Закреплённые',
                        style: Theme.of(ctx)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _pinnedIdsChrono.length,
                      itemBuilder: (_, i) {
                        final id = _pinnedIdsChrono[_pinnedIdsChrono.length -
                            1 -
                            i];
                        final m = mFor(id);
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.push_pin, size: 18),
                          title: Text(
                            preview(m),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            final idx = messages.indexWhere((e) => e.id == id);
                            if (idx < 0 || !_scrollController.hasClients) return;
                            const estH = 72.0;
                            _scrollController.jumpTo(
                                (idx * estH).clamp(
                              0.0,
                              _scrollController.position.maxScrollExtent,
                            ));
                          },
                        );
                      },
                    ),
                ],
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Icon(Icons.push_pin, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Закреплено · ${_pinnedIdsChrono.length}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.primary),
                  ),
                  Text(
                    preview(hi),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurface.withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ),
            Icon(Icons.keyboard_arrow_up, color: cs.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  Future<void> _onForwardContextTap(ChatMessage msg) async {
    final chId = msg.forwardFromChannelId;
    if (chId != null && chId.isNotEmpty) {
      final ch = await ChannelService.instance.getChannel(chId);
      if (!mounted) return;
      if (ch != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChannelViewScreen(channel: ch),
          ),
        );
        return;
      }
    }
    final fk = msg.forwardFromId;
    if (fk != null) {
      await _openForwardedAuthorProfile(fk, msg.forwardFromNick);
    }
  }

  Future<void> _openForwardedAuthorProfile(
      String authorKey, String? hintNick) async {
    final c = await ChatStorageService.instance.getContact(authorKey);
    if (!mounted) return;
    final nick = c?.nickname ??
        (hintNick?.isNotEmpty == true ? hintNick! : '${authorKey.substring(0, 8)}…');
    final color = c?.avatarColor ?? widget.peerAvatarColor;
    final emoji = c?.avatarEmoji ?? widget.peerAvatarEmoji;
    final img = c?.avatarImagePath ?? widget.peerAvatarImagePath;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PeerProfileScreen(
          peerId: authorKey,
          nickname: nick,
          avatarColor: color,
          avatarEmoji: emoji,
          avatarImagePath: img,
        ),
      ),
    );
  }

  Future<void> _togglePinMessage(ChatMessage msg) async {
    final pinned = _pinnedMsgIds.contains(msg.id);
    if (pinned) {
      await ChatStorageService.instance.unpinDmMessage(_resolvedPeerId, msg.id);
      if (!_savedMessagesLocalOnly) {
        await GossipRouter.instance.sendDmPin(
          recipientId: _resolvedPeerId,
          messageId: msg.id,
          add: false,
          fromId: CryptoService.instance.publicKeyHex,
        );
      }
    } else {
      final ok = await ChatStorageService.instance
          .pinDmMessage(_resolvedPeerId, msg.id);
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не больше 20 закреплений в чате')),
          );
        }
        return;
      }
      if (!_savedMessagesLocalOnly) {
        await GossipRouter.instance.sendDmPin(
          recipientId: _resolvedPeerId,
          messageId: msg.id,
          add: true,
          fromId: CryptoService.instance.publicKeyHex,
        );
      }
    }
    await _reloadPins();
  }

  Future<void> _pickForwardTargetAndNavigate(ChatMessage msg) async {
    final picked = await showForwardDmTargetSheet(
      context,
      excludePeerId: _resolvedPeerId,
    );
    if (picked == null || !mounted) return;
    final authorNick = msg.isOutgoing
        ? (ProfileService.instance.profile?.nickname ?? 'Вы')
        : widget.peerNickname;
    final draft = DmForwardDraft(
      message: msg,
      sourcePeerId: _resolvedPeerId,
      originalAuthorNick: authorNick,
      forwardAuthorId:
          msg.isOutgoing ? CryptoService.instance.publicKeyHex : _resolvedPeerId,
    );
    final c = await ChatStorageService.instance.getContact(picked.peerId);
    if (!mounted) return;
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

  Future<void> _runPendingForward() async {
    final d = widget.forwardDraft;
    if (d == null) return;
    final m = d.message;
    final myId = CryptoService.instance.publicKeyHex;
    final fid = d.forwardAuthorId;
    final fnk = d.originalAuthorNick;
    final fch = d.forwardChannelId;
    final target = _resolvedPeerId;
    if (!_looksLikePublicKey(target)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok || !mounted) return;
    }
    var x25519Key = BleService.instance.getPeerX25519Key(target);
    x25519Key ??= RelayService.instance.getPeerX25519Key(target);
    final skipNet = myId == target;

    Future<void> sendText(String text, String msgId) async {
      final msg = ChatMessage(
        id: msgId,
        peerId: target,
        text: text,
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
        forwardFromId: fid,
        forwardFromNick: fnk,
        forwardFromChannelId: fch,
      );
      await ChatStorageService.instance.saveMessage(msg);
      if (!skipNet) {
        if (x25519Key != null && x25519Key.isNotEmpty) {
          final enc = await CryptoService.instance.encryptMessage(
            plaintext: text,
            recipientX25519KeyBase64: x25519Key,
          );
          await GossipRouter.instance.sendEncryptedMessage(
            encrypted: enc,
            senderId: myId,
            recipientId: target,
            messageId: msgId,
            forwardFromId: fid,
            forwardFromNick: fnk,
            forwardFromChannelId: fch,
          );
        } else {
          await GossipRouter.instance.sendRawMessage(
            text: text,
            senderId: myId,
            recipientId: target,
            messageId: msgId,
            forwardFromId: fid,
            forwardFromNick: fnk,
            forwardFromChannelId: fch,
          );
        }
      }
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
    }

    try {
      if (m.imagePath != null && File(m.imagePath!).existsSync()) {
        final msgId = _uuid.v4();
        final docs = await getApplicationDocumentsDirectory();
        final ext = p.extension(m.imagePath!);
        final dest =
            '${docs.path}/fwd_${msgId}${ext.isNotEmpty ? ext : '.jpg'}';
        await File(m.imagePath!).copy(dest);
        if (!skipNet) {
          final bytes = await File(dest).readAsBytes();
          final chunks = ImageService.instance.splitToBase64Chunks(bytes);
          await GossipRouter.instance.sendImgMeta(
            msgId: msgId,
            totalChunks: chunks.length,
            fromId: myId,
            recipientId: target,
            forwardFromId: fid,
            forwardFromNick: fnk,
            forwardFromChannelId: fch,
          );
          for (var i = 0; i < chunks.length; i++) {
            await GossipRouter.instance.sendImgChunk(
              msgId: msgId,
              index: i,
              base64Data: chunks[i],
              fromId: myId,
              recipientId: target,
            );
          }
        }
        final msg = ChatMessage(
          id: msgId,
          peerId: target,
          text: m.text.isNotEmpty ? m.text : ' ',
          imagePath: dest,
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
          forwardFromId: fid,
          forwardFromNick: fnk,
          forwardFromChannelId: fch,
        );
        await ChatStorageService.instance.saveMessage(msg);
      } else if (m.videoPath != null && File(m.videoPath!).existsSync()) {
        final msgId = _uuid.v4();
        final docs = await getApplicationDocumentsDirectory();
        final ext = p.extension(m.videoPath!);
        final dest =
            '${docs.path}/fwd_${msgId}${ext.isNotEmpty ? ext : '.mp4'}';
        await File(m.videoPath!).copy(dest);
        if (!skipNet) {
          final bytes = await File(dest).readAsBytes();
          final chunks = ImageService.instance.splitToBase64Chunks(bytes);
          final isSq = _videoPathIsSquare(m.videoPath!);
          await GossipRouter.instance.sendImgMeta(
            msgId: msgId,
            totalChunks: chunks.length,
            fromId: myId,
            recipientId: target,
            isVideo: true,
            isSquare: isSq,
            forwardFromId: fid,
            forwardFromNick: fnk,
            forwardFromChannelId: fch,
          );
          for (var i = 0; i < chunks.length; i++) {
            await GossipRouter.instance.sendImgChunk(
              msgId: msgId,
              index: i,
              base64Data: chunks[i],
              fromId: myId,
              recipientId: target,
            );
          }
        }
        await ChatStorageService.instance.saveMessage(ChatMessage(
          id: msgId,
          peerId: target,
          text: m.text.isNotEmpty ? m.text : ' ',
          videoPath: dest,
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
          forwardFromId: fid,
          forwardFromNick: fnk,
          forwardFromChannelId: fch,
        ));
      } else if (m.voicePath != null && File(m.voicePath!).existsSync()) {
        final msgId = _uuid.v4();
        final docs = await getApplicationDocumentsDirectory();
        final dest = '${docs.path}/fwd_voice_$msgId.m4a';
        await File(m.voicePath!).copy(dest);
        final bytes = await File(dest).readAsBytes();
        final wasQueued = await _sendMedia(
          bytes: bytes,
          msgId: msgId,
          myId: myId,
          isVoice: true,
          filePath: dest,
        );
        await ChatStorageService.instance.saveMessage(ChatMessage(
          id: msgId,
          peerId: target,
          text: m.text.isNotEmpty ? m.text : '🎤',
          voicePath: dest,
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          forwardFromId: fid,
          forwardFromNick: fnk,
          forwardFromChannelId: fch,
        ));
      } else if (m.filePath != null && File(m.filePath!).existsSync()) {
        final msgId = _uuid.v4();
        final docs = await getApplicationDocumentsDirectory();
        final filesDir = Directory('${docs.path}/files');
        if (!filesDir.existsSync()) filesDir.createSync(recursive: true);
        final baseName = m.fileName ?? p.basename(m.filePath!);
        final dest = '${filesDir.path}/fwd_${msgId}_$baseName';
        await File(m.filePath!).copy(dest);
        final bytes = await File(dest).readAsBytes();
        final wasQueued = await _sendMedia(
          bytes: bytes,
          msgId: msgId,
          myId: myId,
          isFile: true,
          fileName: m.fileName ?? baseName,
          filePath: dest,
        );
        await ChatStorageService.instance.saveMessage(ChatMessage(
          id: msgId,
          peerId: target,
          text: m.text.isNotEmpty ? m.text : (m.fileName ?? '📎'),
          filePath: dest,
          fileName: m.fileName ?? baseName,
          fileSize: m.fileSize ?? bytes.length,
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          forwardFromId: fid,
          forwardFromNick: fnk,
          forwardFromChannelId: fch,
        ));
      } else {
        await sendText(m.text.isNotEmpty ? m.text : ' ', _uuid.v4());
      }
      if (mounted) {
        await ChatStorageService.instance.loadMessages(target);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Пересылка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    final maxLen = _isAiBot ? 12000 : _kMaxMessageLength;
    if (text.length > maxLen) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Сообщение слишком длинное (макс. $maxLen симв.)')),
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
      if (!_isAiBot && !_looksLikePublicKey(_resolvedPeerId)) {
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
        if (!_savedMessagesLocalOnly && !_isAiBot) {
          await GossipRouter.instance.sendEditMessage(
            messageId: targetId,
            newText: text,
            senderId: myId,
            recipientId: _resolvedPeerId,
          );
        }
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

      // Check X25519 key: BLE service first, then relay service
      var x25519Key = BleService.instance.getPeerX25519Key(targetPeerId);
      if (x25519Key == null || x25519Key.isEmpty) {
        x25519Key = RelayService.instance.getPeerX25519Key(targetPeerId);
      }

      debugPrint('[RLINK][Chat] Sending to ${targetPeerId.substring(0, 8)}, '
          'x25519=${x25519Key != null && x25519Key.isNotEmpty ? "YES" : "NO"}, '
          'relay=${RelayService.instance.isConnected}, '
          'mode=${AppSettings.instance.connectionMode}');

      if (!_savedMessagesLocalOnly && !_isAiBot) {
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
            latitude: lat,
            longitude: lng,
            replyToMessageId: _replyToMessageId,
          );
          debugPrint('[RLINK][Chat] Sent ENCRYPTED msg $msgId');
        } else {
          // Fallback — plaintext если X25519 ключ ещё не получен
          await GossipRouter.instance.sendRawMessage(
            text: text,
            senderId: myId,
            recipientId: targetPeerId,
            messageId: msgId,
            replyToMessageId: _replyToMessageId,
            latitude: lat,
            longitude: lng,
          );
          debugPrint('[RLINK][Chat] Sent RAW msg $msgId');
        }
      } else {
        debugPrint('[RLINK][Chat] Saved messages / ИИ — сеть не используется');
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

      if (_isAiBot) {
        unawaited(_completeGigachatReply());
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

  Future<void> _completeGigachatReply() async {
    if (!mounted) return;
    setState(() => _aiThinking = true);
    try {
      final reply = await GigachatService.instance.completeAfterUserMessage();
      if (!mounted) return;
      final botMsg = ChatMessage(
        id: _uuid.v4(),
        peerId: kAiBotPeerId,
        text: reply,
        isOutgoing: false,
        timestamp: DateTime.now(),
        status: MessageStatus.delivered,
      );
      await ChatStorageService.instance.saveMessage(botMsg);
      await ChatStorageService.instance.loadMessages(kAiBotPeerId);
      if (mounted) _scrollToBottom();
    } on GigachatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GigaChat: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _aiThinking = false);
    }
  }

  Future<void> _composeAndSendTodo() async {
    if (_isSending || _editingMessageId != null) return;
    final enc = await showSharedTodoComposeDialog(context);
    if (enc == null || !mounted) return;
    await _sendCollabEncoded(enc);
  }

  Future<void> _composeAndSendCalendar() async {
    if (_isSending || _editingMessageId != null) return;
    final enc = await showSharedCalendarComposeDialog(context);
    if (enc == null || !mounted) return;
    await _sendCollabEncoded(enc);
  }

  Future<void> _sendCollabEncoded(String encoded) async {
    if (_isAiBot) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('В чате с ИИ доступен только обычный текст')),
        );
      }
      return;
    }
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
    setState(() => _isSending = true);
    try {
      await OutboundDmText.send(
        peerId: _resolvedPeerId,
        fullText: encoded,
        replyToMessageId: _replyToMessageId,
      );
      if (mounted) {
        setState(() {
          _replyToMessageId = null;
          _replyPreviewText = null;
        });
      }
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

  Future<void> _patchSharedCollab(ChatMessage msg, String newEncoded) async {
    await ChatStorageService.instance.editMessage(msg.id, newEncoded);
    if (!_savedMessagesLocalOnly && !_isAiBot) {
      await GossipRouter.instance.sendEditMessage(
        messageId: msg.id,
        newText: newEncoded,
        senderId: CryptoService.instance.publicKeyHex,
        recipientId: _resolvedPeerId,
      );
    }
  }

  Future<void> _openChatCalendar() async {
    if (!mounted) return;
    final List<ChatMessage> msgs;
    try {
      msgs = await ChatStorageService.instance.getMessages(_resolvedPeerId);
    } catch (e, st) {
      debugPrint('_openChatCalendar getMessages failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить события: $e')),
      );
      return;
    }
    if (!mounted) return;
    final events = SharedCalendarPayload.collectFromChatMessages(msgs);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('События в чате'),
        content: SizedBox(
          width: double.maxFinite,
          child: events.isEmpty
              ? const Text('Пока нет отмеченных событий.')
              : ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
                  ),
                  child: ListView.builder(
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
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  Future<void> _scheduleSendDialog() async {
    if (_editingMessageId != null) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 1))),
    );
    if (t == null || !mounted) return;
    final when = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    if (!when.isAfter(now)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Выберите время в будущем')),
        );
      }
      return;
    }
    final peerStore =
        _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId;
    await ChatStorageService.instance.insertScheduledDm(
      id: _uuid.v4(),
      peerId: peerStore,
      text: text,
      replyToMessageId: _replyToMessageId,
      sendAtMs: when.millisecondsSinceEpoch,
    );
    _controller.clear();
    setState(() {
      _replyToMessageId = null;
      _replyPreviewText = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Сообщение запланировано: ${when.day}.${when.month}.${when.year} '
                '${when.hour.toString().padLeft(2, '0')}:'
                '${when.minute.toString().padLeft(2, '0')}')),
      );
    }
  }

  Future<void> _openMediaGallery() async {
    if (_isSending) return;
    if (!await _ensureReadyForMediaSend()) return;
    if (!mounted) return;
    final myId = CryptoService.instance.publicKeyHex;
    await showMediaGallerySendSheet(
      context,
      onPhotoPath: (path) => _handlePickedChatImage(XFile(path)),
      onGifPath: (path) => _sendGifFromPath(path, myId),
      onVideoPath: (path) => _sendVideoFile(XFile(path), myId),
      onStickerCropped: _sendStickerFromCroppedBytes,
      onStickerFromLibrary: _sendStickerFromLibraryPath,
      onFilePath: _sendFileFromMediaGalleryPath,
    );
  }

  Future<void> _sendFileFromMediaGalleryPath(String srcPath) async {
    if (_isSending) return;
    if (!await _ensureReadyForMediaSend()) return;
    if (!File(srcPath).existsSync()) return;
    final originalName = p.basename(srcPath);
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    setState(() => _isSending = true);
    _sendActivity(Activity.sendingFile);
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files')
        ..createSync(recursive: true);
      final destPath =
          '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_$originalName';
      await File(srcPath).copy(destPath);

      final fileSize = File(destPath).lengthSync();
      final msgId = _uuid.v4();
      final targetPeerId =
          _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId;
      bool wasQueued = false;

      if (!_savedMessagesLocalOnly) {
        if (fileSize > _kMaxBlobBytes) {
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: msgId,
            filePath: destPath,
            recipientKey: _resolvedPeerId,
            fromId: myId,
            isFile: true,
            fileName: originalName,
          ));
          wasQueued = true;
        } else {
          final fileBytes = await File(destPath).readAsBytes();
          wasQueued = await _sendMedia(
            bytes: fileBytes,
            msgId: msgId,
            myId: myId,
            isFile: true,
            fileName: originalName,
            filePath: destPath,
          );
        }
      }

      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: '📎 $originalName',
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          filePath: destPath,
          fileName: originalName,
          fileSize: fileSize,
        ),
        wasQueued: wasQueued,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка отправки файла: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _sendActivity(Activity.stopped);
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendStickerFromLibraryPath(String absPath) async {
    if (_isSending) return;
    if (!await _ensureReadyForMediaSend()) return;
    if (!File(absPath).existsSync()) return;
    if (!mounted) return;
    final myId = CryptoService.instance.publicKeyHex;

    setState(() => _isSending = true);
    try {
      final fileBytes = await File(absPath).readAsBytes();
      if (!mounted) return;
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      final wasQueued = await _sendMedia(
        bytes: fileBytes,
        msgId: msgId,
        myId: myId,
        filePath: absPath,
        isSticker: true,
      );
      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: '',
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          imagePath: absPath,
        ),
        wasQueued: wasQueued,
      );
      if (!mounted) return;
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Стикер: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _handlePickedChatImage(XFile picked) async {
    if (_isSending) return;
    if (!await _ensureReadyForMediaSend()) return;
    if (!mounted) return;
    final myId = CryptoService.instance.publicKeyHex;

    if (picked.path.toLowerCase().endsWith('.gif')) {
      await _sendGifFromPath(picked.path, myId);
      return;
    }

    // ── Photo path ─────────────────────────────────────────────────
    final choice = await showModalBottomSheet<_ImageSendMode>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_size_select_actual_outlined),
                title: const Text('Отправить со сжатием'),
                subtitle: const Text('Редактирование, просмотр в чате'),
                onTap: () => Navigator.pop(ctx, _ImageSendMode.compressed),
              ),
              ListTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('Отправить как файл'),
                subtitle: const Text('Оригинальное качество'),
                onTap: () => Navigator.pop(ctx, _ImageSendMode.asFile),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == _ImageSendMode.compressed) {
      await _sendImageCompressed(picked, myId);
    } else {
      await _sendImageAsFile(picked, myId);
    }
  }

  /// GIF из галереи — без редактора, с сохранением анимации.
  Future<void> _sendGifFromPath(String path, String myId) async {
    setState(() => _isSending = true);
    try {
      final saved = await ImageService.instance.saveChatImageFromPicker(path);
      final bytes = await File(saved).readAsBytes();
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      final wasQueued = await _sendMedia(
        bytes: bytes,
        msgId: msgId,
        myId: myId,
        filePath: saved,
      );
      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: '🎞 GIF',
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          imagePath: saved,
        ),
        wasQueued: wasQueued,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('GIF: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendStickerFromCroppedBytes(Uint8List bytes) async {
    if (_isSending) return;
    if (!await _ensureReadyForMediaSend()) return;
    if (!mounted) return;
    final myId = CryptoService.instance.publicKeyHex;

    setState(() => _isSending = true);
    try {
      final path = await ImageService.instance.saveStickerFromBytes(bytes);
      if (!mounted) return;
      unawaited(StickerCollectionService.instance.registerAbsoluteStickerPath(path));
      final fileBytes = await File(path).readAsBytes();
      if (!mounted) return;
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      final wasQueued = await _sendMedia(
        bytes: fileBytes,
        msgId: msgId,
        myId: myId,
        filePath: path,
        isSticker: true,
      );
      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: '',
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          imagePath: path,
        ),
        wasQueued: wasQueued,
      );
      if (!mounted) return;
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Стикер: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Send a video file (picked from gallery) as a chat message.
  /// Never reads the whole file into RAM — uses the upload queue directly
  /// when relay is available, and only loads bytes for BLE fallback.
  Future<void> _sendVideoFile(XFile picked, String myId) async {
    setState(() => _isSending = true);
    try {
      final path = await ImageService.instance.saveVideo(picked.path, isSquare: false);
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      bool wasQueued = false;

      if (!_savedMessagesLocalOnly) {
        if (RelayService.instance.isConnected) {
          // Queue-based send: file never read into RAM
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: msgId,
            filePath: path,
            recipientKey: _resolvedPeerId,
            fromId: myId,
            isVideo: true,
            isSquare: false,
          ));
          wasQueued = true;
        } else {
          // BLE-only fallback: must load bytes
          final bytes = await File(path).readAsBytes();
          await _sendMedia(
            bytes: bytes, msgId: msgId, myId: myId,
            isVideo: true, isSquare: false, filePath: path,
          );
        }
      }

      await _saveAndTrack(ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '📹 Видео',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        videoPath: path,
      ), wasQueued: wasQueued);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Send photo with compression + editing (opens fullscreen on tap in chat).
  Future<void> _sendImageCompressed(XFile picked, String myId) async {
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
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId : widget.peerId;

      final wasQueued = await _sendMedia(bytes: bytes, msgId: msgId, myId: myId, filePath: path);
      await _saveAndTrack(ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        imagePath: path,
      ), wasQueued: wasQueued);
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

  /// Send photo as original-quality file (no compression, no image editor).
  Future<void> _sendImageAsFile(XFile picked, String myId) async {
    setState(() => _isSending = true);
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files')
        ..createSync(recursive: true);
      final destPath = '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      await File(picked.path).copy(destPath);

      final fileSize = File(destPath).lengthSync();
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId : widget.peerId;
      bool wasQueued = false;

      if (!_savedMessagesLocalOnly) {
        if (fileSize > _kMaxBlobBytes) {
          // Large original — use upload queue directly (avoid loading into RAM)
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: msgId,
            filePath: destPath,
            recipientKey: _resolvedPeerId,
            fromId: myId,
            isFile: true,
            fileName: picked.name,
          ));
          wasQueued = true;
        } else {
          final bytes = await File(destPath).readAsBytes();
          wasQueued = await _sendMedia(
            bytes: bytes, msgId: msgId, myId: myId,
            isFile: true, fileName: picked.name, filePath: destPath,
          );
        }
      }

      await _saveAndTrack(ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '📎 ${picked.name}',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        filePath: destPath,
        fileName: picked.name,
        fileSize: fileSize,
      ), wasQueued: wasQueued);
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

  /// Квадратное видеосообщение с камеры (пункт «Видеосообщение» в меню +).
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ошибка: приложение еще не готово'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!mounted) return;
    _sendActivity(Activity.recordingVideo);
    final videoPath = await showSquareVideoRecorder(context);
    _sendActivity(Activity.stopped);
    if (videoPath == null || !mounted) return;

    await _publishSquareVideoFromDisk(videoPath);
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

    // withData: false — get path without loading entire file into RAM.
    // On Android, file_picker copies to cache so picked.path is always usable.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final picked = result.files.first;
    final originalName = picked.name;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    setState(() => _isSending = true);
    _sendActivity(Activity.sendingFile);
    try {
      // Copy to app's files dir for persistent local storage
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files')
        ..createSync(recursive: true);
      final destPath = '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_$originalName';

      if (picked.path != null) {
        await File(picked.path!).copy(destPath);
      } else {
        // path unavailable — try re-pick with bytes (rare edge case)
        final r2 = await FilePicker.platform.pickFiles(
          type: FileType.any, allowMultiple: false, withData: true);
        final b = r2?.files.firstOrNull?.bytes;
        if (b == null || !mounted) { setState(() => _isSending = false); return; }
        await File(destPath).writeAsBytes(b);
      }

      final fileSize = File(destPath).lengthSync();
      final msgId = _uuid.v4();
      final targetPeerId =
          _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId;
      bool wasQueued = false;

      if (!_savedMessagesLocalOnly) {
        if (fileSize > _kMaxBlobBytes) {
          // Large file — enqueue directly, never load full content into RAM
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: msgId,
            filePath: destPath,
            recipientKey: _resolvedPeerId,
            fromId: myId,
            isFile: true,
            fileName: originalName,
          ));
          wasQueued = true;
        } else {
          final fileBytes = await File(destPath).readAsBytes();
          wasQueued = await _sendMedia(
            bytes: fileBytes,
            msgId: msgId,
            myId: myId,
            isFile: true,
            fileName: originalName,
            filePath: destPath,
          );
        }
      }

      await _saveAndTrack(ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '📎 $originalName',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        filePath: destPath,
        fileName: originalName,
        fileSize: fileSize,
      ), wasQueued: wasQueued);
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
      _sendActivity(Activity.stopped);
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Save a message and, if it was queued for background upload,
  /// register its id so the "Загружается..." bar appears.
  Future<void> _saveAndTrack(ChatMessage msg, {required bool wasQueued}) async {
    await ChatStorageService.instance.saveMessage(msg);
    if (wasQueued && mounted) {
      setState(() => _uploadingMsgIds.add(msg.id));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } catch (_) {
        // Контроллер уже dispose — игнорируем.
      }
    });
  }

  double? _scrollDistanceFromBottom() {
    if (!_scrollController.hasClients) return null;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels;
  }

  void _preserveScrollAfterComposerResize(double? distFromBottom) {
    if (distFromBottom == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (!_scrollController.hasClients) return;
        final pos = _scrollController.position;
        final target = (pos.maxScrollExtent - distFromBottom)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _scrollController.jumpTo(target);
      } catch (_) {}
    });
  }

  Future<void> _refreshGigachatVpnFlag() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (!mounted) return;
      final on = results.contains(ConnectivityResult.vpn);
      if (on != _vpnProbablyActive) {
        setState(() => _vpnProbablyActive = on);
      }
    } catch (_) {
      // Desktop / неподдерживаемая платформа — плашку не показываем.
    }
  }

  void _startReply(ChatMessage msg) {
    final dist = _scrollDistanceFromBottom();
    setState(() {
      _editingMessageId = null;
      _editingPreviewText = null;
      _replyToMessageId = msg.id;
      _replyPreviewText = msg.text;
    });
    _preserveScrollAfterComposerResize(dist);
  }

  void _cancelReply() {
    final dist = _scrollDistanceFromBottom();
    setState(() {
      _replyToMessageId = null;
      _replyPreviewText = null;
    });
    _preserveScrollAfterComposerResize(dist);
  }

  void _startEdit(ChatMessage msg) {
    final dist = _scrollDistanceFromBottom();
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
    _preserveScrollAfterComposerResize(dist);
  }

  void _cancelEdit() {
    final dist = _scrollDistanceFromBottom();
    setState(() {
      _editingMessageId = null;
      _editingPreviewText = null;
      _controller.clear();
    });
    _preserveScrollAfterComposerResize(dist);
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
      if (!_savedMessagesLocalOnly) {
        await GossipRouter.instance.sendDeleteMessage(
          messageId: msg.id,
          senderId: CryptoService.instance.publicKeyHex,
          recipientId: _resolvedPeerId,
        );
      }
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
    final stickerSourcePath = msg.imagePath == null
        ? null
        : (ImageService.instance.resolveStoredPath(msg.imagePath) ??
            msg.imagePath);
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
            ListTile(
              leading: Icon(
                  _pinnedMsgIds.contains(msg.id)
                      ? Icons.push_pin_outlined
                      : Icons.push_pin),
              title: Text(_pinnedMsgIds.contains(msg.id)
                  ? 'Открепить'
                  : 'Закрепить'),
              onTap: () async {
                Navigator.pop(ctx);
                await _togglePinMessage(msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Переслать…'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickForwardTargetAndNavigate(msg));
              },
            ),
            if (stickerSourcePath != null &&
                File(stickerSourcePath).existsSync())
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: const Text('В коллекцию стикеров'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await StickerCollectionService.instance
                        .importChatImageToCollection(stickerSourcePath);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Добавлено в стикеры')),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Не удалось: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
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
    final emoji = await showReactionPickerSheet(context);
    if (emoji == null) return;
    await _toggleReaction(msg, emoji);
  }

  Future<void> _toggleReaction(ChatMessage msg, String emoji) async {
    await ChatStorageService.instance
        .toggleReaction(msg.id, emoji, CryptoService.instance.publicKeyHex);
    if (!_savedMessagesLocalOnly) {
      await GossipRouter.instance.sendReaction(
        messageId: msg.id,
        emoji: emoji,
        fromId: CryptoService.instance.publicKeyHex,
        recipientId: _resolvedPeerId,
      );
    }
  }

  Future<void> _quickReaction(ChatMessage msg) async {
    final emoji = AppSettings.instance.quickReactionEmoji.trim();
    if (emoji.isEmpty) return;
    await _toggleReaction(msg, emoji);
  }

  void _onMessagePointerDownQuickReact(PointerDownEvent e, ChatMessage msg) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    final now = DateTime.now();
    if (_lastQuickPointerMsgId == msg.id &&
        _lastQuickPointerAt != null &&
        now.difference(_lastQuickPointerAt!) < const Duration(milliseconds: 450)) {
      _lastQuickPointerMsgId = null;
      _lastQuickPointerAt = null;
      unawaited(_quickReaction(msg));
      return;
    }
    _lastQuickPointerMsgId = msg.id;
    _lastQuickPointerAt = now;
  }

  Future<void> _pickChatBackground() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    await AppSettings.instance.setChatBgForPeer(_resolvedPeerId, picked.path);
  }

  Future<void> _removeChatBackground() async {
    await AppSettings.instance.setChatBgForPeer(_resolvedPeerId, null);
  }

  Future<void> _exportChatToFile() async {
    try {
      final f = await ChatStorageService.instance
          .exportDirectChatToJsonFile(_resolvedPeerId);
      await Share.shareXFiles([XFile(f.path)], subject: 'Rlink — экспорт чата');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось экспортировать: $e')),
        );
      }
    }
  }

  void _openPeerProfile() {
    if (_isAiBot) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => const ProfileScreen(),
        ),
      );
      return;
    }
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

  void _onRequestMissingDmMedia(ChatMessage msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg.isOutgoing
              ? 'Когда собеседник будет в сети, попросите переслать файл '
                  'или дождитесь подтяжки истории.'
              : 'Когда собеседник будет в сети, вложение может подтянуться '
                  'с историей; иначе попросите переслать.',
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
            isOnline: !_isAiBot &&
                (BleService.instance.isPeerConnected(_resolvedPeerId) ||
                    (RelayService.instance.isConnected &&
                        RelayService.instance
                            .isPeerOnline(_resolvedPeerId))),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.peerNickname,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (_isAiBot)
              Text(
                'ИИ · GigaChat (Сбер)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            else
              ValueListenableBuilder<int>(
                valueListenable: TypingService.instance.version,
                builder: (_, __, ___) {
                  final activity =
                      TypingService.instance.activityFor(_resolvedPeerId);
                  if (activity != Activity.stopped) {
                    final label = TypingService.instance.label(activity);
                    return Text(label,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF1DB954)),
                    );
                  }
                  return ValueListenableBuilder<int>(
                    valueListenable: BleService.instance.peersCount,
                    builder: (_, __, ___) {
                      return ValueListenableBuilder<int>(
                        valueListenable: RelayService.instance.presenceVersion,
                        builder: (_, __, ___) {
                          final online = BleService.instance
                              .isPeerConnected(_resolvedPeerId);
                          final relayOnline =
                              RelayService.instance.isConnected &&
                                  RelayService.instance
                                      .isPeerOnline(_resolvedPeerId);
                          final isOnline = online || relayOnline;
                          return Text(
                            isOnline ? 'в сети' : 'не в сети',
                            style: TextStyle(
                              fontSize: 12,
                              color: isOnline
                                  ? Colors.green
                                  : Colors.grey.shade500,
                            ),
                          );
                        },
                      );
                    },
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
                if (!_isAiBot)
                  const PopupMenuItem(
                    value: 'peer_stickers',
                    child: Text('Стикеры из чата'),
                  ),
                const PopupMenuItem(
                    value: 'chat_cal',
                    child: Text('Календарь чата')),
                const PopupMenuItem(value: 'background', child: Text('Фон чата')),
                if (hasBg)
                  const PopupMenuItem(value: 'remove_bg', child: Text('Убрать фон')),
                const PopupMenuItem(
                    value: 'export', child: Text('Экспорт в файл')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить чат')),
              ];
            },
            onSelected: (v) async {
              switch (v) {
                case 'profile':
                  _openPeerProfile();
                  break;
                case 'peer_stickers':
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PeerStickersScreen(
                        peerId: _resolvedPeerId,
                        peerName: widget.peerNickname,
                      ),
                    ),
                  );
                  break;
                case 'chat_cal':
                  unawaited(_openChatCalendar());
                  break;
                case 'background':
                  _pickChatBackground();
                  break;
                case 'remove_bg':
                  _removeChatBackground();
                  break;
                case 'export':
                  await _exportChatToFile();
                  break;
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
                    if (context.mounted) Navigator.pop(context);
                  }
                  break;
              }
            },
          ),
        ],
      ),
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(children: [
        // Sending / uploading status bar
        if (_aiThinking)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Row(children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'GigaChat формирует ответ…',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ]),
          ),
        if (_isAiBot && _vpnProbablyActive)
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Включён VPN: GigaChat может не ответить или ругаться на сертификат. '
                      'При ошибках попробуйте отключить VPN.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: Theme.of(context).colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_isSending || _uploadingMsgIds.isNotEmpty)
          ValueListenableBuilder<Map<String, double>>(
            valueListenable: MediaUploadQueue.instance.progressMap,
            builder: (_, progressMap, __) {
              final uploadProgress = _uploadingMsgIds.isEmpty
                  ? null
                  : progressMap.entries
                      .where((e) => _uploadingMsgIds.contains(e.key))
                      .map((e) => e.value)
                      .fold<double?>(null, (acc, v) => acc == null ? v : (acc + v) / 2);
              final label = uploadProgress != null
                  ? 'Загружается файл... ${(uploadProgress * 100).round()}%'
                  : 'Отправка...';
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Row(children: [
                  SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: uploadProgress,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(label,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ]),
              );
            },
          ),
        // ── Add-contact banner — shown for any non-contact peer ──────
        if (!_isContact &&
            !_strangerBannerDismissed &&
            !_savedMessagesLocalOnly &&
            !_isAiBot)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(children: [
              Icon(Icons.person_add_outlined, size: 18,
                color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Не в контактах',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              _StrangerAction(
                icon: Icons.block,
                label: 'Блок',
                color: Colors.red.shade400,
                onTap: () async {
                  await BlockService.instance.block(_resolvedPeerId);
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Пользователь заблокирован')),
                    );
                  }
                },
              ),
              const SizedBox(width: 4),
              _StrangerAction(
                icon: Icons.person_add_outlined,
                label: 'Добавить',
                color: const Color(0xFF1DB954),
                onTap: () async {
                  if (!mounted) return;
                  final myProfile = ProfileService.instance.profile;
                  if (myProfile == null) return;
                  // Always send a targeted pair_req when we have a valid key.
                  // If the peer was found via relay or BLE (key known), the request
                  // arrives immediately. Fall back to broadcast for unresolved keys.
                  if (_looksLikePublicKey(_resolvedPeerId)) {
                    await GossipRouter.instance.sendPairRequest(
                      publicKey: myProfile.publicKeyHex,
                      nick: myProfile.nickname,
                      username: myProfile.username,
                      color: myProfile.avatarColor,
                      emoji: myProfile.avatarEmoji,
                      recipientId: _resolvedPeerId,
                      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
                      tags: myProfile.tags,
                    );
                  } else {
                    // Key not yet resolved — broadcast so the peer learns who we are
                    await GossipRouter.instance.broadcastProfile(
                      id: myProfile.publicKeyHex,
                      nick: myProfile.nickname,
                      username: myProfile.username,
                      color: myProfile.avatarColor,
                      emoji: myProfile.avatarEmoji,
                      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
                      tags: myProfile.tags,
                      statusEmoji: myProfile.statusEmoji,
                    );
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Запрос на обмен отправлен — ожидаем ответ'),
                        duration: Duration(seconds: 3),
                      ),
                    );
                    setState(() => _strangerBannerDismissed = true);
                  }
                },
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => setState(() => _strangerBannerDismissed = true),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                ),
              ),
            ]),
          ),
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
                  final pinBar = _pinnedIdsChrono.isEmpty
                      ? null
                      : _buildPinnedBar(messages);
                  final n = messages.length;
                  if (n != _lastPinSyncMessageCount &&
                      !_pendingMessageCountPinSync) {
                    _pendingMessageCountPinSync = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _pendingMessageCountPinSync = false;
                      if (!mounted) return;
                      final live = ChatStorageService.instance
                          .messagesNotifier(_resolvedPeerId)
                          .value
                          .length;
                      if (live == _lastPinSyncMessageCount) return;
                      _lastPinSyncMessageCount = live;
                      _onScrollForPins();
                    });
                  }
                  return Column(
                    children: [
                      if (pinBar != null) pinBar,
                      Expanded(
                        child: ListView.builder(
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
                        SwipeToReply(
                          isOutgoing: msg.isOutgoing,
                          onReply: () => _startReply(msg),
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (e) =>
                                _onMessagePointerDownQuickReact(e, msg),
                            child: GestureDetector(
                              onLongPress: () => _onLongPressMessage(msg),
                              onDoubleTap: () => unawaited(_quickReaction(msg)),
                              child: _MessageBubble(
                                msg: msg,
                                replyPreviewText: msg.replyToMessageId == null
                                    ? null
                                    : messageTextById[msg.replyToMessageId],
                                onDownloadImage: _saveImageToGallery,
                                onCollabPersist: _patchSharedCollab,
                                onForwardContextTap: _onForwardContextTap,
                                onRequestMissingMedia: _onRequestMissingDmMedia,
                                playbackThread: messages,
                                playbackIndex: i,
                              ),
                            ),
                          ),
                        ),
                      ]);
                    },
                  ),
                      ),
                    ],
                  );
                },
               ),
              ),
              if (_showScrollToBottomFab)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Material(
                    elevation: 3,
                    shape: const CircleBorder(),
                    color: Theme.of(context).colorScheme.primary,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _scrollToBottom,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Theme.of(context).colorScheme.onPrimary,
                          size: 26,
                        ),
                      ),
                    ),
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
          isHoldVideoStarting: _dmHoldVideoStarting,
          recordingSecondsNotifier: _recordingSecondsNotifier,
          maxLength: _isAiBot ? 12000 : _kMaxMessageLength,
          hintText: _isAiBot ? 'Сообщение для GigaChat…' : null,
          aiTextOnlyComposer: _isAiBot,
          locationActive: _pendingLat != null,
          onSend: _send,
          onLongPressSend: _scheduleSendDialog,
          onPickTodo: _isAiBot ? null : _composeAndSendTodo,
          onPickCalendar: _isAiBot ? null : _composeAndSendCalendar,
          onOpenMediaGallery: _openMediaGallery,
          onPickSquareVideo: _sendVideo,
          onPickFile: _sendFile,
          onVoiceHoldStart: _startVoiceRecording,
          onVideoHoldStart: _startDmHoldSquareVideo,
          onHoldReleaseSend: () async {
            if (_dmHoldVideoCam != null) {
              await _finishDmHoldSquareVideo(send: true);
            } else {
              await _stopAndSendVoice();
            }
          },
          onHoldCancelDiscard: _cancelActiveMediaRecording,
          onLocation: _toggleLocation,
          holdVideoPausedListenable: _dmHoldVideoPausedNotifier,
          onHoldRecordingLockChanged: _onHoldRecordingLockChanged,
          onHoldVideoLockedPauseToggle: _toggleDmHoldVideoPause,
        ),
          ]),
          if (_dmHoldVideoCam != null)
            ValueListenableBuilder<bool>(
              valueListenable: _dmHoldVideoPausedNotifier,
              builder: (ctx, paused, __) {
                return ListenableBuilder(
                  listenable: _dmHoldVideoCam!,
                  builder: (ctx2, _) {
                    final cam = _dmHoldVideoCam;
                    if (cam == null || !cam.value.isInitialized) {
                      return const SizedBox.shrink();
                    }
                    final w = MediaQuery.sizeOf(ctx2).width;
                    final squareSize = w * 0.82;
                    return Positioned.fill(
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.72),
                        child: SafeArea(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SquareVideoFramedCameraView(
                                controller: cam,
                                squareSize: squareSize,
                                isRecording: true,
                                recordingSeconds: _recordingSecondsNotifier,
                                maxDuration: 15,
                                showFlipButton: _dmHoldCameraList.length > 1,
                                onFlipCamera: () =>
                                    unawaited(_switchDmHoldCamera()),
                                isSwitchingCamera: _dmHoldSwitchingCam,
                                pulseController: null,
                                recordingPaused: paused,
                                isPaused: paused,
                                onToggleRecordingPause: () =>
                                    unawaited(_toggleDmHoldVideoPause()),
                              ),
                              const SizedBox(height: 20),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 24),
                                child: Text(
                                  _dmHoldLockedWhileVideo
                                      ? 'Закреплено: сверху отправка, пауза или удаление'
                                      : 'Отпустите палец — отправить · вверх — закрепить',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.grey.shade400,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ),
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

// ── Приглашения в канал / группу в ЛС ───────────────────────────

Map<String, dynamic>? _dmInviteMap(ChatMessage msg) {
  final raw = msg.invitePayloadJson;
  if (raw != null && raw.isNotEmpty) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final k = m['kind'] as String?;
      if (k == 'channel' || k == 'group') return m;
    } catch (_) {}
  }
  if (msg.voicePath != null ||
      msg.imagePath != null ||
      msg.videoPath != null ||
      msg.filePath != null) {
    return null;
  }
  final chName = InviteDmCodec.channelNameFromInvitePreview(msg.text);
  if (chName != null) {
    final matches = ChannelService.instance.pendingChannelInvites.value
        .where((i) => i.channelName == chName)
        .toList();
    if (matches.length == 1) {
      final i = matches.first;
      return {
        'kind': 'channel',
        'channelId': i.channelId,
        'channelName': i.channelName,
        'adminId': i.adminId,
        'inviterId': i.inviterId,
        'inviterNick': i.inviterNick,
        'avatarColor': i.avatarColor,
        'avatarEmoji': i.avatarEmoji,
        'description': i.description,
        'createdAt': i.createdAt,
      };
    }
  }
  final gName = InviteDmCodec.groupNameFromInvitePreview(msg.text);
  if (gName != null) {
    final matches = GroupService.instance.pendingInvites.value
        .where((i) => i.groupName == gName)
        .toList();
    if (matches.length == 1) {
      final i = matches.first;
      return {
        'kind': 'group',
        'groupId': i.groupId,
        'groupName': i.groupName,
        'inviterId': i.inviterId,
        'inviterNick': i.inviterNick,
        'creatorId': i.creatorId,
        'memberIds': i.memberIds,
        'avatarColor': i.avatarColor,
        'avatarEmoji': i.avatarEmoji,
        'createdAt': i.createdAt,
      };
    }
  }
  return null;
}

class _DmInviteBubbleActions extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isOut;
  final ColorScheme cs;

  const _DmInviteBubbleActions({
    required this.data,
    required this.isOut,
    required this.cs,
  });

  Future<void> _openChannel(BuildContext context) async {
    final adminId = data['adminId'] as String?;
    final channelId = data['channelId'] as String?;
    final name = data['channelName'] as String? ?? '';
    if (adminId == null || channelId == null) return;
    final ch = Channel(
      id: channelId,
      name: name,
      adminId: adminId,
      subscriberIds: [adminId],
      avatarColor: data['avatarColor'] as int? ?? 0xFF42A5F5,
      avatarEmoji: data['avatarEmoji'] as String? ?? '📢',
      description: data['description'] as String?,
      createdAt: data['createdAt'] as int? ??
          DateTime.now().millisecondsSinceEpoch,
    );
    await ChannelService.instance.saveChannelFromBroadcast(ch);
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ChannelViewScreen(channel: ch),
      ),
    );
  }

  Future<void> _subscribeChannel(BuildContext context) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    final channelId = data['channelId'] as String?;
    final name = data['channelName'] as String? ?? '';
    final adminId = data['adminId'] as String?;
    if (channelId == null || adminId == null) return;
    final existing = await ChannelService.instance.getChannel(channelId);
    if (existing != null &&
        (existing.subscriberIds.contains(myId) || existing.adminId == myId)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Вы уже подписаны на этот канал')),
        );
      }
      return;
    }
    final channel = Channel(
      id: channelId,
      name: name,
      adminId: adminId,
      subscriberIds: [adminId, myId],
      avatarColor: data['avatarColor'] as int? ?? 0xFF42A5F5,
      avatarEmoji: data['avatarEmoji'] as String? ?? '📢',
      description: data['description'] as String?,
      createdAt: data['createdAt'] as int? ??
          DateTime.now().millisecondsSinceEpoch,
    );
    await ChannelService.instance.saveChannelFromBroadcast(channel);
    await ChannelService.instance.subscribe(channelId, myId);
    ChannelService.instance.removeChannelInvite(channelId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вы подписались на канал')),
      );
    }
  }

  Future<void> _joinGroup(BuildContext context) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    final groupId = data['groupId'] as String?;
    final name = data['groupName'] as String? ?? '';
    final creatorId = data['creatorId'] as String?;
    final rawMembers = data['memberIds'];
    if (groupId == null || creatorId == null || rawMembers is! List) return;
    final memberIds = rawMembers.cast<String>();
    final myProfile = ProfileService.instance.profile;
    final group = Group(
      id: groupId,
      name: name,
      creatorId: creatorId,
      memberIds: [...memberIds, myId],
      avatarColor: data['avatarColor'] as int? ?? 0xFF5C6BC0,
      avatarEmoji: data['avatarEmoji'] as String? ?? '👥',
      createdAt: data['createdAt'] as int? ??
          DateTime.now().millisecondsSinceEpoch,
    );
    await GroupService.instance.saveGroupFromInvite(group);
    GroupService.instance.removeInvite(groupId);
    await GossipRouter.instance.sendGroupAccept(
      groupId: groupId,
      accepterId: myId,
      accepterNick: myProfile?.nickname ?? '',
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Вы в группе')),
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => GroupChatScreen(group: group),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kind = data['kind'] as String?;
    if (kind == 'channel') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(
            onPressed: () => unawaited(_openChannel(context)),
            style: OutlinedButton.styleFrom(
              foregroundColor: isOut ? cs.onPrimary : cs.primary,
              side: BorderSide(
                color: isOut
                    ? cs.onPrimary.withValues(alpha: 0.5)
                    : cs.primary.withValues(alpha: 0.5),
              ),
            ),
            child: const Text('Открыть канал'),
          ),
          const SizedBox(height: 6),
          ListenableBuilder(
            listenable: ChannelService.instance.version,
            builder: (context, _) {
              final myId = CryptoService.instance.publicKeyHex;
              final channelId = data['channelId'] as String? ?? '';
              return FutureBuilder<Channel?>(
                key: ValueKey(
                    '${ChannelService.instance.version.value}_$channelId'),
                future: ChannelService.instance.getChannel(channelId),
                builder: (context, snap) {
                  final ch = snap.data;
                  final subscribed = myId.isNotEmpty &&
                      ch != null &&
                      (ch.subscriberIds.contains(myId) || ch.adminId == myId);
                  return FilledButton(
                    onPressed: subscribed || myId.isEmpty
                        ? null
                        : () => unawaited(_subscribeChannel(context)),
                    child: Text(subscribed ? 'Вы подписаны' : 'Подписаться'),
                  );
                },
              );
            },
          ),
        ],
      );
    }
    if (kind == 'group') {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => unawaited(_joinGroup(context)),
          child: const Text('Стать участником'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

// ── Пузырь сообщения ─────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final String? replyPreviewText;
  final Function(String)? onDownloadImage;
  final Future<void> Function(ChatMessage msg, String newEncoded)?
      onCollabPersist;
  final void Function(ChatMessage msg)? onForwardContextTap;
  final void Function(ChatMessage msg)? onRequestMissingMedia;
  final List<ChatMessage>? playbackThread;
  final int? playbackIndex;

  const _MessageBubble({
    required this.msg,
    this.replyPreviewText,
    this.onDownloadImage,
    this.onCollabPersist,
    this.onForwardContextTap,
    this.onRequestMissingMedia,
    this.playbackThread,
    this.playbackIndex,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isOut = msg.isOutgoing;
    final missing = dmMessageMissingLocalMedia(msg);
    final inviteMap = _dmInviteMap(msg);

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
            borderRadius: AppSettings.instance.bubbleRadius(isMe: isOut),
          ),
          child: Column(
          crossAxisAlignment:
              isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if ((msg.forwardFromId != null ||
                    msg.forwardFromChannelId != null) &&
                onForwardContextTap != null) ...[
              Align(
                alignment:
                    isOut ? Alignment.centerRight : Alignment.centerLeft,
                child: InkWell(
                  onTap: () => onForwardContextTap!(msg),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.forward,
                            size: 14,
                            color: isOut
                                ? cs.onPrimary.withValues(alpha: 0.85)
                                : cs.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            msg.forwardFromNick?.isNotEmpty == true
                                ? msg.forwardFromNick!
                                : (msg.forwardFromChannelId != null
                                    ? 'Канал'
                                    : '${msg.forwardFromId!.substring(0, 8)}…'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isOut
                                  ? cs.onPrimary.withValues(alpha: 0.9)
                                  : cs.primary,
                            ),
                          ),
                        ),
                        Icon(Icons.open_in_new,
                            size: 12,
                            color: isOut
                                ? cs.onPrimary.withValues(alpha: 0.6)
                                : cs.primary.withValues(alpha: 0.6)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (missing) ...[
              ClearedMediaPlaceholder(
                isOutgoing: isOut,
                isDirectChat: true,
                colorScheme: cs,
                onPressed: () => onRequestMissingMedia?.call(msg),
              ),
            ],
            if (msg.voicePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _VoiceMessageBubble(
                  voicePath: msg.voicePath!,
                  isOut: isOut,
                  onPlayWithQueue: playbackThread != null &&
                          playbackIndex != null
                      ? () => unawaited(VoiceService.instance.playQueue(
                            _dmPlaybackQueueFrom(
                                playbackThread!, playbackIndex!),
                          ))
                      : null,
                ),
              ),
            if (msg.videoPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _VideoMessageBubble(
                  videoPath: msg.videoPath!,
                  isOut: isOut,
                  onPlaySquareWithQueue:
                      playbackThread != null &&
                              playbackIndex != null &&
                              _dmVideoPathIsSquare(msg.videoPath!)
                          ? () => unawaited(VoiceService.instance.playQueue(
                                _dmPlaybackQueueFrom(
                                    playbackThread!, playbackIndex!),
                              ))
                          : null,
                ),
              ),
            if (msg.imagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Builder(
                  builder: (context) {
                    final isSticker =
                        p.basename(msg.imagePath!).startsWith('stk_');
                    return _UploadProgressOverlay(
                      msgId: msg.id,
                      child: GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _FullScreenImageViewer(
                                imagePath: msg.imagePath!),
                          ),
                        ),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                  isSticker ? 10 : 12),
                              child: Image.file(
                                File(msg.imagePath!),
                                width: isSticker ? 132 : 220,
                                height: isSticker ? 132 : null,
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
                    );
                  },
                ),
              ),
            if (msg.filePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _UploadProgressOverlay(
                  msgId: msg.id,
                  child: _FileMessageBubble(
                    msgId: msg.id,
                    filePath: msg.filePath!,
                    fileName: msg.fileName ?? 'Файл',
                    fileSize: msg.fileSize,
                    isOut: isOut,
                    onAudioQueueFromHere: playbackThread != null &&
                            playbackIndex != null
                        ? () => unawaited(VoiceService.instance.playQueue(
                              _dmPlaybackQueueFrom(
                                  playbackThread!, playbackIndex!),
                            ))
                        : null,
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
            if (SharedTodoPayload.tryDecode(msg.text) != null &&
                onCollabPersist != null)
              SharedTodoMessageCard(
                encoded: msg.text,
                cs: cs,
                isOutgoing: isOut,
                onPersist: (enc) => onCollabPersist!(msg, enc),
              )
            else if (SharedCalendarPayload.tryDecode(msg.text) != null)
              SharedCalendarMessageCard(
                encoded: msg.text,
                cs: cs,
                isOutgoing: isOut,
              )
            else if (inviteMap != null)
              Column(
                crossAxisAlignment: isOut
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    msg.text,
                    style: TextStyle(
                      color: isOut ? cs.onPrimary : cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _DmInviteBubbleActions(
                    data: inviteMap,
                    isOut: isOut,
                    cs: cs,
                  ),
                ],
              )
            else if (msg.text.isNotEmpty &&
                msg.voicePath == null &&
                !(missing && isSyntheticMediaCaption(msg.text)))
              ValueListenableBuilder<List<Contact>>(
                valueListenable: ChatStorageService.instance.contactsNotifier,
                builder: (_, contacts, __) {
                  return RichMessageText(
                    text: msg.text,
                    textColor: isOut ? cs.onPrimary : cs.onSurface,
                    isOut: isOut,
                    mentionLabelFor: (hex) => resolveChannelMentionDisplay(
                      hex,
                      contacts,
                      ProfileService.instance.profile,
                    ),
                    onMentionTap: (hex) => openDmFromMentionKey(context, hex),
                  );
                },
              ),
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
                  AppSettings.instance.formatTime(msg.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isOut
                        ? cs.onPrimary.withValues(alpha: 0.7)
                        : cs.onSurfaceVariant,
                  ),
                ),
                if (isOut && AppSettings.instance.showReadReceipts) ...[
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
  final bool isHoldVideoStarting;
  final ValueNotifier<double> recordingSecondsNotifier;
  final int maxLength;
  final String? hintText;
  /// Чат с ИИ: только текст (без медиа и вложений).
  final bool aiTextOnlyComposer;
  final bool locationActive;
  final VoidCallback onSend;
  final VoidCallback? onLongPressSend;
  final VoidCallback? onPickTodo;
  final VoidCallback? onPickCalendar;
  final VoidCallback onOpenMediaGallery;
  final VoidCallback onPickSquareVideo;
  final VoidCallback onPickFile;
  final VoidCallback onVoiceHoldStart;
  final Future<void> Function() onVideoHoldStart;
  final Future<void> Function() onHoldReleaseSend;
  final Future<void> Function() onHoldCancelDiscard;
  final VoidCallback onLocation;
  final ValueListenable<bool> holdVideoPausedListenable;
  final void Function(bool locked) onHoldRecordingLockChanged;
  final Future<void> Function() onHoldVideoLockedPauseToggle;

  const _InputBar({
    required this.controller,
    required this.isSending,
    required this.isRecording,
    required this.isHoldVideoStarting,
    required this.recordingSecondsNotifier,
    required this.maxLength,
    this.hintText,
    this.aiTextOnlyComposer = false,
    required this.locationActive,
    required this.onSend,
    this.onLongPressSend,
    this.onPickTodo,
    this.onPickCalendar,
    required this.onOpenMediaGallery,
    required this.onPickSquareVideo,
    required this.onPickFile,
    required this.onVoiceHoldStart,
    required this.onVideoHoldStart,
    required this.onHoldReleaseSend,
    required this.onHoldCancelDiscard,
    required this.onLocation,
    required this.holdVideoPausedListenable,
    required this.onHoldRecordingLockChanged,
    required this.onHoldVideoLockedPauseToggle,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  int _length = 0;
  final _focusNode = FocusNode();
  /// Панель B/I/S… не перекрывает поле — открывается кнопкой при выделении.
  bool _showFormatStrip = false;

  void _onAppSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onAppSettingsChanged);
    widget.controller.addListener(() {
      if (mounted) {
        setState(() {
          _length = widget.controller.text.length;
          final sel = widget.controller.selection;
          if (!sel.isValid || sel.isCollapsed) {
            _showFormatStrip = false;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAppSettingsChanged);
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
            if (hasSelection && _showFormatStrip)
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
          if (hasSelection)
            IconButton(
              onPressed: () =>
                  setState(() => _showFormatStrip = !_showFormatStrip),
              icon: Icon(
                Icons.text_fields_rounded,
                color: _showFormatStrip ? cs.primary : cs.onSurfaceVariant,
                size: 22,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: _showFormatStrip
                  ? 'Скрыть формат'
                  : 'Формат выделенного текста',
            ),
          if (!widget.aiTextOnlyComposer) ...[
            PopupMenuButton<String>(
              onSelected: (value) {
                if (widget.isSending) return;
                switch (value) {
                  case 'square_video':
                    widget.onPickSquareVideo();
                    break;
                  case 'file': widget.onPickFile(); break;
                  case 'location': widget.onLocation(); break;
                  case 'todo': widget.onPickTodo?.call(); break;
                  case 'cal': widget.onPickCalendar?.call(); break;
                }
              },
              icon: AnimatedRotation(
                turns: widget.locationActive ? 0.125 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.add_rounded,
                  color: widget.locationActive ? cs.primary : cs.onSurfaceVariant,
                  size: 26,
                ),
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              position: PopupMenuPosition.over,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'square_video',
                  child: Row(children: [
                    Icon(Icons.videocam_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Видеосообщение'),
                  ]),
                ),
                const PopupMenuItem(value: 'file',
                  child: Row(children: [
                    Icon(Icons.attach_file_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Файл'),
                  ]),
                ),
                PopupMenuItem(value: 'location',
                  child: Row(children: [
                    Icon(widget.locationActive ? Icons.location_on : Icons.location_on_outlined,
                      size: 20,
                      color: widget.locationActive ? cs.primary : null,
                    ),
                    const SizedBox(width: 12),
                    Text(widget.locationActive ? 'Убрать геометку' : 'Геометка'),
                  ]),
                ),
                if (widget.onPickTodo != null)
                  const PopupMenuItem(
                    value: 'todo',
                    child: Row(children: [
                      Icon(Icons.checklist_rtl, size: 20),
                      SizedBox(width: 12),
                      Text('Список дел'),
                    ]),
                  ),
                if (widget.onPickCalendar != null)
                  const PopupMenuItem(
                    value: 'cal',
                    child: Row(children: [
                      Icon(Icons.event_available_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Событие'),
                    ]),
                  ),
              ],
            ),
            IconButton(
              onPressed: widget.isSending ? null : widget.onOpenMediaGallery,
              icon: Icon(Icons.photo_library_outlined,
                  color: widget.isSending
                      ? cs.onSurface.withValues(alpha: 0.3)
                      : cs.onSurfaceVariant,
                  size: 24),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Отправить из галереи',
            ),
            const SizedBox(width: 2),
          ],
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
                  final sendOnEnter = AppSettings.instance.sendOnEnter;
                  return TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    onTapOutside: (_) => _focusNode.unfocus(),
                    enabled: !widget.isRecording,
                    maxLines: sendOnEnter ? 1 : 4,
                    minLines: 1,
                    textInputAction: sendOnEnter
                        ? TextInputAction.send
                        : TextInputAction.newline,
                    onSubmitted: sendOnEnter
                        ? (_) {
                            if (!widget.isSending && !over && !widget.isRecording) {
                              widget.onSend();
                            }
                          }
                        : null,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: widget.isRecording
                          ? 'Запись... ${s}s.$t'
                          : (widget.hintText ?? 'Сообщение...'),
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
          if (!widget.aiTextOnlyComposer) ...[
            TelegramMediaRecordButton(
              isSending: widget.isSending,
              isRecording: widget.isRecording,
              isHoldVideoStarting: widget.isHoldVideoStarting,
              colorScheme: cs,
              onVoiceHoldStart: widget.onVoiceHoldStart,
              onVideoHoldStart: widget.onVideoHoldStart,
              onHoldReleaseSend: widget.onHoldReleaseSend,
              onHoldCancelDiscard: widget.onHoldCancelDiscard,
              onHoldLockChanged: widget.onHoldRecordingLockChanged,
              onLockedVideoPauseToggle: widget.onHoldVideoLockedPauseToggle,
              lockedVideoPausedListenable: widget.holdVideoPausedListenable,
            ),
            const SizedBox(width: 8),
          ],
          if (hasText || widget.isSending)
            GestureDetector(
              onTap: widget.isSending || over || widget.isRecording
                  ? null
                  : widget.onSend,
              onLongPress: (widget.onLongPressSend == null ||
                      !hasText ||
                      widget.isSending ||
                      over ||
                      widget.isRecording)
                  ? null
                  : widget.onLongPressSend,
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
            ),
          ]),
        ],
        ),
      ),
    );
  }
}

// ── Файл/документ ────────────────────────────────────────────────

class _FileMessageBubble extends StatelessWidget {
  final String msgId;
  final String filePath;
  final String fileName;
  final int? fileSize;
  final bool isOut;
  final VoidCallback? onAudioQueueFromHere;

  const _FileMessageBubble({
    required this.msgId,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.isOut,
    this.onAudioQueueFromHere,
  });

  static const _audioExts = {
    '.mp3', '.ogg', '.wav', '.m4a', '.aac', '.flac', '.opus', '.wma', '.mp4a',
  };

  bool get _isAudio {
    final name = fileName.toLowerCase();
    for (final ext in _audioExts) {
      if (name.endsWith(ext)) return true;
    }
    return false;
  }

  String _fmtSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes Б';
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
    if (_isAudio && File(filePath).existsSync()) {
      return _AudioFileBubble(
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        isOut: isOut,
        onPlayWithQueue: onAudioQueueFromHere,
      );
    }
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
        constraints: const BoxConstraints(maxWidth: 260),
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

// ── Аудио-файл (mp3/ogg/wav/etc.) в сообщении ───────────────────

class _AudioFileBubble extends StatelessWidget {
  final String filePath;
  final String fileName;
  final int? fileSize;
  final bool isOut;
  final VoidCallback? onPlayWithQueue;

  const _AudioFileBubble({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.isOut,
    this.onPlayWithQueue,
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
    final iconColor = isOut ? cs.onPrimary : cs.onSurface;
    final activeColor = isOut ? cs.onPrimary : cs.primary;
    final inactiveColor =
        (isOut ? cs.onPrimary : cs.onSurface).withValues(alpha: 0.35);
    final subColor = isOut
        ? cs.onPrimary.withValues(alpha: 0.65)
        : cs.onSurfaceVariant;

    return ValueListenableBuilder<String?>(
      valueListenable: VoiceService.instance.currentlyPlaying,
      builder: (_, playing, __) {
        final isPlaying = playing == filePath;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () async {
                    try {
                      if (isPlaying) {
                        await VoiceService.instance.stopPlayback();
                      } else if (onPlayWithQueue != null) {
                        onPlayWithQueue!();
                      } else {
                        await VoiceService.instance.play(
                          filePath,
                          title: fileName,
                          kind: PlaybackMediaKind.audioFile,
                        );
                      }
                    } catch (e) {
                      debugPrint('[Audio] Playback error: $e');
                    }
                  },
                  icon: Icon(
                    isPlaying
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    color: iconColor,
                    size: 28,
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
                        seed: filePath.hashCode,
                        progress: isPlaying
                            ? (progress.isFinite
                                ? progress.clamp(0.0, 1.0)
                                : 0.0)
                            : 0,
                        activeColor: activeColor,
                        inactiveColor: inactiveColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: subColor),
              ),
            ),
            if (fileSize != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  _fmtSize(fileSize),
                  style: TextStyle(fontSize: 10, color: subColor),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _VoiceMessageBubble extends StatelessWidget {
  final String voicePath;
  final bool isOut;
  final VoidCallback? onPlayWithQueue;

  const _VoiceMessageBubble({
    required this.voicePath,
    required this.isOut,
    this.onPlayWithQueue,
  });

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
                    await VoiceService.instance.stopPlayback();
                  } else if (onPlayWithQueue != null) {
                    onPlayWithQueue!();
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
                    progress: isPlaying
                        ? (progress.isFinite
                            ? progress.clamp(0.0, 1.0)
                            : 0.0)
                        : 0,
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
    final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    final activeBar = (p * barCount).floor().clamp(0, barCount);
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
  final VoidCallback? onPlaySquareWithQueue;

  const _VideoMessageBubble({
    required this.videoPath,
    required this.isOut,
    this.onPlaySquareWithQueue,
  });

  @override
  State<_VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends State<_VideoMessageBubble> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _playing = false;
  int _embedPauseGen = 0;

  bool get _isSquare =>
      _ChatScreenState._videoPathIsSquare(widget.videoPath);

  void _onEmbedPauseBus() {
    if (!mounted) return;
    final g = EmbeddedVideoPauseBus.instance.generation.value;
    if (g != _embedPauseGen) {
      _embedPauseGen = g;
      _pauseFromGlobalBus();
    }
  }

  void _pauseFromGlobalBus() {
    if (_ctrl == null) return;
    try {
      _ctrl!.pause();
    } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    if (File(widget.videoPath).existsSync()) {
      _initPlayer();
    }
  }

  Future<void> _initPlayer() async {
    final ctrl = VideoPlayerController.file(File(widget.videoPath));
    try {
      await ctrl.initialize();
      if (_isSquare) {
        ctrl.setLooping(true);
      } else {
        // Seek to first frame so it shows as a thumbnail; don't auto-play.
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
      debugPrint('[VideoMessage] init error: $e');
      ctrl.dispose();
    }
  }

  @override
  void dispose() {
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    _ctrl?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_ctrl == null || !_initialized) return;
    if (_playing) {
      _ctrl!.pause();
      setState(() => _playing = false);
      return;
    }
    if (widget.onPlaySquareWithQueue != null) {
      widget.onPlaySquareWithQueue!();
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
    return _isSquare ? _buildCircle() : _buildRegular(context);
  }

  Widget _buildCircle() {
    final exists = File(widget.videoPath).existsSync();
    return GestureDetector(
      onTap: exists ? _togglePlay : null,
      child: SizedBox(
        width: 160,
        height: 160,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
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
    // Aspect ratio from the video itself; fall back to 16:9.
    final ar = (_initialized && _ctrl != null && _ctrl!.value.aspectRatio > 0)
        ? _ctrl!.value.aspectRatio
        : 16 / 9;
    const w = 220.0;
    final h = (w / ar).clamp(80.0, 320.0);

    return GestureDetector(
      onTap: exists
          ? () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) =>
                      DmVideoFullscreenPage(path: widget.videoPath),
                ),
              )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: w,
          height: h,
          child: !exists
              ? Container(
                  color: Colors.black87,
                  child: const Center(
                    child: Text('Файл не найден',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                        textAlign: TextAlign.center),
                  ),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    // Dark backdrop
                    Container(color: const Color(0xFF111111)),
                    // Превью без обрезки до квадрата — сохраняем пропорции ролика.
                    if (_initialized && _ctrl != null)
                      FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: _ctrl!.value.size.width,
                          height: _ctrl!.value.size.height,
                          child: VideoPlayer(_ctrl!),
                        ),
                      ),
                    // Semi-transparent overlay so play icon pops
                    Container(color: Colors.black.withValues(alpha: 0.28)),
                    // Play button
                    const Center(
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 54),
                    ),
                    // Videocam badge
                    const Positioned(
                      bottom: 6,
                      right: 8,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.videocam, color: Colors.white70, size: 14),
                        SizedBox(width: 4),
                        Text('Видео',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 11)),
                      ]),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ── Профиль пира (из меню чата) ──────────────────────────────────

class _PeerProfileScreen extends StatefulWidget {
  final String peerId;
  // Initial values from widget params (used while DB loads)
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

  // Loaded from DB
  String? _nick;
  String? _username;
  int? _color;
  String? _emoji;
  String? _avatarPath;
  String? _bannerPath;
  List<String> _tags = const [];
  String? _musicPath;
  AudioPlayer? _musicPlayer;
  bool _musicPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
    // Реактивно подхватываем обновления контакта (аватар, баннер, ник, теги),
    // которые прилетают по BLE/relay пока экран открыт.
    ChatStorageService.instance.contactsNotifier.addListener(_onContactsChanged);
  }

  @override
  void dispose() {
    ChatStorageService.instance.contactsNotifier.removeListener(_onContactsChanged);
    _musicPlayer?.dispose();
    super.dispose();
  }

  void _onContactsChanged() {
    if (!mounted) return;
    final contacts = ChatStorageService.instance.contactsNotifier.value;
    Contact? c;
    for (final x in contacts) {
      if (x.publicKeyHex == widget.peerId) { c = x; break; }
    }
    if (c == null) return;
    final newAvatar = ImageService.instance.resolveStoredPath(c.avatarImagePath);
    final newBanner = ImageService.instance.resolveStoredPath(c.bannerImagePath);
    // Обновляем только если реально изменилось (иначе setState впустую).
    final newMusic =
        ImageService.instance.resolveStoredPath(c.profileMusicPath);
    if (c.nickname == _nick &&
        c.username == (_username ?? '') &&
        c.avatarColor == _color &&
        c.avatarEmoji == _emoji &&
        newAvatar == _avatarPath &&
        newBanner == _bannerPath &&
        newMusic == _musicPath &&
        _listEq(c.tags, _tags)) {
      return;
    }
    setState(() {
      _nick = c!.nickname;
      _username = c.username.isEmpty ? null : c.username;
      _color = c.avatarColor;
      _emoji = c.avatarEmoji;
      _avatarPath = newAvatar;
      _bannerPath = newBanner;
      _musicPath = newMusic;
      _tags = c.tags;
    });
  }

  bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _loadAll() async {
    final contact = await ChatStorageService.instance.getContact(widget.peerId);
    final msgs = await ChatStorageService.instance.getMessages(widget.peerId, limit: 1000);
    if (!mounted) return;
    setState(() {
      if (contact != null) {
        _nick        = contact.nickname;
        _username    = contact.username.isEmpty ? null : contact.username;
        _color       = contact.avatarColor;
        _emoji       = contact.avatarEmoji;
        _avatarPath  = ImageService.instance.resolveStoredPath(contact.avatarImagePath);
        _bannerPath  = ImageService.instance.resolveStoredPath(contact.bannerImagePath);
        _musicPath   = ImageService.instance.resolveStoredPath(contact.profileMusicPath);
        _tags        = contact.tags;
      } else {
        _musicPath = null;
      }
      _images = msgs.where((m) => m.imagePath != null).toList();
      _voices = msgs.where((m) => m.voicePath != null).toList();
      _files  = msgs.where((m) => m.filePath != null).toList();
      _links  = msgs.where((m) => _hasLink(m.text)).toList();
    });
  }

  bool _hasLink(String text) => RegExp(r'https?://\S+').hasMatch(text);

  Future<void> _toggleProfileMusic() async {
    final path = _musicPath;
    if (path == null || !File(path).existsSync()) return;
    _musicPlayer ??= AudioPlayer();
    if (_musicPlaying) {
      await _musicPlayer!.stop();
      if (mounted) setState(() => _musicPlaying = false);
      return;
    }
    await _musicPlayer!.play(DeviceFileSource(path));
    if (!mounted) return;
    setState(() => _musicPlaying = true);
    unawaited(_musicPlayer!.onPlayerComplete.first.then((_) {
      if (mounted) setState(() => _musicPlaying = false);
    }));
  }

  Future<void> _onProfileAction(String action) async {
    if (action == 'unblock') {
      await BlockService.instance.unblock(widget.peerId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Контакт разблокирован')),
      );
      return;
    }
    if (action == 'block') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Заблокировать контакт?'),
          content: const Text(
            'Вы больше не будете получать от него сообщения, истории и вызовы.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Заблокировать'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await BlockService.instance.block(widget.peerId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Контакт заблокирован')),
      );
      Navigator.of(context).pop();
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Удалить контакт?'),
          content: const Text(
            'Контакт и вся переписка будут удалены без возможности восстановления.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await ChatStorageService.instance.deleteChat(widget.peerId);
      await ChatStorageService.instance.deleteContact(widget.peerId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Контакт удалён')),
      );
      // Pop profile screen AND chat screen underneath.
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stories = StoryService.instance.storiesFor(widget.peerId);

    final nick       = _nick       ?? widget.nickname;
    final color      = _color      ?? widget.avatarColor;
    final emoji      = _emoji      ?? widget.avatarEmoji;
    final avatarPath = _avatarPath ?? widget.avatarImagePath;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Collapsible header with banner + avatar ──
          SliverAppBar(
            expandedHeight: _bannerPath != null && File(_bannerPath!).existsSync() ? 200 : 120,
            pinned: true,
            actions: [
              ValueListenableBuilder<Set<String>>(
                valueListenable: BlockService.instance.blockedNotifier,
                builder: (_, blocked, __) {
                  final isBlocked = blocked.contains(widget.peerId);
                  return PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (value) => _onProfileAction(value),
                    itemBuilder: (_) => [
                      if (isBlocked)
                        const PopupMenuItem(
                          value: 'unblock',
                          child: Row(children: [
                            Icon(Icons.lock_open, size: 20, color: Colors.green),
                            SizedBox(width: 12),
                            Text('Разблокировать'),
                          ]),
                        )
                      else
                        const PopupMenuItem(
                          value: 'block',
                          child: Row(children: [
                            Icon(Icons.block, size: 20, color: Colors.orange),
                            SizedBox(width: 12),
                            Text('Заблокировать'),
                          ]),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete_outline, size: 20, color: Colors.red),
                          SizedBox(width: 12),
                          Text('Удалить контакт'),
                        ]),
                      ),
                    ],
                  );
                },
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 16, bottom: 16),
              title: Text(
                nick,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
              background: _bannerPath != null && File(_bannerPath!).existsSync()
                  ? Image.file(File(_bannerPath!), fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _bannerFallback(color))
                  : _bannerFallback(color),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar circle centred
                  Center(
                    child: AvatarWidget(
                      initials: nick.isNotEmpty ? nick[0].toUpperCase() : '?',
                      color: color,
                      emoji: emoji,
                      imagePath: avatarPath,
                      size: 80,
                      hasStory: stories.isNotEmpty,
                      hasUnviewedStory: StoryService.instance.hasUnviewedStory(widget.peerId),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      nick,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (_username != null && _username!.isNotEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '@${_username!}',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: Text(
                      '${widget.peerId.substring(0, 16)}...',
                      style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.4), fontFamily: 'monospace'),
                    ),
                  ),

                  // ── Tags ──
                  if (_tags.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _tags.map((tag) => Chip(
                        label: Text(tag, style: const TextStyle(fontSize: 12)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        backgroundColor: cs.primaryContainer,
                      )).toList(),
                    ),
                  ],

                  const SizedBox(height: 12),
                  ValueListenableBuilder<int>(
                    valueListenable: RelayService.instance.presenceVersion,
                    builder: (_, __, ___) {
                      final hasMusic = _musicPath != null &&
                          File(_musicPath!).existsSync();
                      final online = RelayService.instance.isConnected &&
                          RelayService.instance.isPeerOnline(widget.peerId);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.music_note,
                                  size: 20, color: cs.primary),
                              const SizedBox(width: 8),
                              const Text('Музыка в профиле',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (hasMusic)
                            FilledButton.tonalIcon(
                              onPressed: _toggleProfileMusic,
                              icon: Icon(
                                  _musicPlaying ? Icons.stop : Icons.play_arrow),
                              label: Text(
                                  _musicPlaying ? 'Стоп' : 'Слушать'),
                            )
                          else if (online)
                            OutlinedButton.icon(
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Ожидайте: трек придёт с профилем, когда '
                                      'контакт обновит приложение или откроет чат.',
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.download_outlined),
                              label: const Text('Загрузить трек'),
                            )
                          else
                            Text(
                              'Когда контакт будет в сети ретранслятора, '
                              'трек сможет подтянуться с профилем.',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      );
                    },
                  ),

                  // ── Stories ──
                  if (stories.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.amp_stories),
                      title: const Text('Сегодняшняя история'),
                      subtitle: Text('${stories.length} историй'),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => StoryViewerScreen(
                            authorId: widget.peerId,
                            authorName: nick,
                            stories: stories,
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),
                  const Divider(),

                  // ── Media library ──
                  _MediaSection(
                    title: 'Фото',
                    icon: Icons.photo_outlined,
                    count: _images.length,
                    child: _images.isEmpty ? null : SizedBox(
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
                  _MediaSection(title: 'Голосовые', icon: Icons.mic_outlined,    count: _voices.length),
                  _MediaSection(title: 'Файлы',     icon: Icons.attach_file_outlined, count: _files.length),
                  _MediaSection(
                    title: 'Ссылки',
                    icon: Icons.link,
                    count: _links.length,
                    child: _links.isEmpty ? null : Column(
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _bannerFallback(int color) => Container(
    color: Color(color).withValues(alpha: 0.3),
  );
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

// ── Stranger Banner Action Button ─────────────────────────────

class _StrangerAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _StrangerAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 2),
            Text(label,
              style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ── Режим отправки изображения ────────────────────────────────────
enum _ImageSendMode { compressed, asFile }

// ── Оверлей прогресса загрузки ────────────────────────────────────

/// Wraps any message widget with an upload-progress overlay while the
/// message is being uploaded via [MediaUploadQueue].
class _UploadProgressOverlay extends StatelessWidget {
  final String msgId;
  final Widget child;

  const _UploadProgressOverlay({required this.msgId, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: MediaUploadQueue.instance.progressMap,
      builder: (_, map, __) {
        final progress = map[msgId];
        if (progress == null) return child;
        return Stack(
          children: [
            child,
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            value: progress > 0.02 ? progress : null,
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${(progress * 100).round()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
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

// ── Полноэкранный просмотр изображения ───────────────────────────

class _FullScreenImageViewer extends StatelessWidget {
  final String imagePath;
  const _FullScreenImageViewer({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

