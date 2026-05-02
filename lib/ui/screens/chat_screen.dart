import 'dart:async';
import 'dart:collection' show LinkedHashSet;
import 'dart:convert' show jsonDecode, jsonEncode, latin1, utf8;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
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
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../main.dart'
    show IncomingMessage, incomingMessageController, navigatorKey;
import '../../models/channel.dart';
import '../../models/chat_message.dart';
import '../../models/group.dart';
import '../../models/shared_collab.dart';
import '../../models/contact.dart';
import '../../services/ai_bot_constants.dart';
import '../../services/app_settings.dart';
import '../../services/gigachat_service.dart';
import '../../services/lib_bot_service.dart';
import '../../services/local_transcription_service.dart';
import '../../services/emoji_bot_service.dart';
import '../../services/emoji_pack_service.dart';
import '../../services/emoji_pack_dm_service.dart';
import '../../services/ble_service.dart';
import '../../services/block_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/channel_service.dart';
import '../../services/call_service.dart';
import '../../services/connection_transport.dart';
import '../../services/device_link_sync_service.dart';
import '../../services/dm_bot_flags.dart';
import '../../services/dm_compose_draft_service.dart';
import '../../services/ether_service.dart';
import '../../services/group_service.dart';
import '../../services/outbound_dm_text.dart';
import '../../services/outbox_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/sticker_collection_service.dart';
import '../../services/sticker_pack_dm_service.dart';
import '../../services/profile_service.dart';
import '../../services/voice_service.dart';
import '../../services/audio_queue_mini_player_layout.dart';
import '../../services/voice_transcript_cache_service.dart';
import '../../services/embedded_video_pause_bus.dart';
import '../../services/story_service.dart';
import '../../services/typing_service.dart';
import '../../services/relay_service.dart';
import '../../services/media_upload_queue.dart';
import '../../services/sound_effects_service.dart';
import '../../services/pending_media_service.dart';
import '../../utils/channel_mentions.dart';
import '../../utils/custom_emoji_text.dart';
import '../../utils/reaction_emoji_key.dart';
import '../../utils/external_message_share.dart';
import '../../utils/invite_dm_codec.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';
import '../widgets/status_emoji_view.dart';
import 'image_editor_screen.dart';
import 'profile_screen.dart';
import 'bot_profile_screen.dart';
import 'square_video_recorder_screen.dart';
import 'story_viewer_screen.dart';
import 'collab_compose_dialogs.dart';
import 'channels_screen.dart';
import 'call_screen.dart';
import 'groups_screen.dart';
import 'location_map_screen.dart';
import 'contact_edit_screen.dart';
import '../widgets/shared_todo_message_card.dart';
import '../widgets/shared_calendar_message_card.dart';
import '../widgets/missing_local_media.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/swipe_to_reply.dart';
import 'peer_stickers_screen.dart';
import '../widgets/media_gallery_send_sheet.dart';
import '../widgets/dm_video_fullscreen_page.dart';
import '../widgets/hold_square_video_review_screen.dart';
import '../widgets/square_video_recording_widgets.dart';
import '../widgets/forward_target_sheet.dart';
import '../widgets/sticker_pack_card_bubble.dart';
import '../widgets/emoji_pack_card_bubble.dart';
import '../widgets/chat_emoji_insert_sheet.dart';
import 'emoji_hub_screen.dart';
import 'emoji_pack_detail_screen.dart';
import '../widgets/sticker_picker_sheet.dart';
import '../widgets/telegram_media_record_button.dart';
import '../mention_nav.dart';

bool _dmVideoPathIsSquare(String path) =>
    p.basename(path).toLowerCase().endsWith('_sq.mp4');

bool _dmPlaybackFileNameIsAudio(String fileName) {
  const exts = {
    '.mp3',
    '.ogg',
    '.wav',
    '.m4a',
    '.aac',
    '.flac',
    '.opus',
    '.wma',
    '.mp4a',
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

  /// Локальный путь или https URL (например баннер бота из каталога relay).
  final String? peerBannerImagePath;
  final DmForwardDraft? forwardDraft;

  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerNickname,
    required this.peerAvatarColor,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
    this.peerBannerImagePath,
    this.forwardDraft,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final GlobalKey _audioQueueMiniPlayerAnchor =
      GlobalKey(debugLabel: 'audioQueueMiniPlayerAnchor');
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
  bool _voiceHoldLocked = false;
  bool _isVoiceRecordingPaused = false;
  String? _activeVoiceSegmentPath;
  double _activeVoiceSegmentSeconds = 0;
  final List<String> _voiceSegments = [];
  final List<double> _voiceSegmentDurations = [];
  StreamSubscription<double>? _voiceAmpSub;
  final _recordingWaveformNotifier = ValueNotifier<List<double>>(<double>[]);
  final Map<String, String> _voiceTranscripts = {};
  final Set<String> _voiceTranscribing = <String>{};
  final Map<String, bool> _voiceTranscriptExpanded = {};
  String? _lastVoiceHydratedMsgsHash;

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
  String? _headerAvatarPath;
  String? _headerBannerPath;
  VoidCallback? _relayBotDirectoryListener;
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
  ScaffoldMessengerState? _scaffoldMessenger;

  /// Множественный выбор пузырей: переслать / удалить.
  bool _bulkSelectMode = false;
  final LinkedHashSet<String> _selectedMsgIds = LinkedHashSet<String>();

  Timer? _draftPersistDebounce;

  /// Автодополнение slash-команд для relay-бота (см. [_onComposeBotSlashHints]).
  List<Map<String, String>> _slashBotSuggestions = const [];

  /// true с первой строки [dispose]: до [super.dispose] [mounted] ещё true,
  /// поэтому async (Lib/GigaChat и т.д.) нельзя вызывать [setState] без этой проверки.
  bool _tearingDown = false;

  /// Только для GigaChat: на iOS/Android [ConnectivityResult.vpn] из connectivity_plus.
  bool _vpnProbablyActive = false;

  /// Только Lib / GigaChat (псевдо peer id).
  bool get _isBuiltinAiBot => isAiBotPeerId(widget.peerId);

  /// Любой бот в личке: встроенный или из каталога relay.
  bool get _isDmBot => isDmBotPeerId(widget.peerId);

  bool get _isLibBot => widget.peerId == kLibBotPeerId;
  bool get _isGigachatBot => widget.peerId == kGigachatBotPeerId;
  bool get _isEmojiBot => widget.peerId == kEmojiBotPeerId;

  bool _miniPlayerLayoutCallbackPending = false;

  void _ensureMiniPlayerLayoutSync() {
    if (_miniPlayerLayoutCallbackPending) return;
    _miniPlayerLayoutCallbackPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _miniPlayerLayoutCallbackPending = false;
      if (!mounted || _tearingDown) return;
      AudioQueueMiniPlayerLayout.instance
          .scheduleBarTopFromAnchor(_audioQueueMiniPlayerAnchor);
    });
  }

  void _showErrorSnack(String text) {
    if (_tearingDown) return;
    final rootCtx = navigatorKey.currentContext;
    final messenger =
        rootCtx != null ? ScaffoldMessenger.maybeOf(rootCtx) : null;
    (messenger ?? _scaffoldMessenger)?.showSnackBar(
      SnackBar(content: Text(text), backgroundColor: Colors.red),
    );
  }

  bool get _isRelayCatalogDm =>
      _looksLikePublicKey(_resolvedPeerId) &&
      RelayService.instance.isRelayCatalogBot(_resolvedPeerId);

  /// Диалог «Избранное» (peer_id = наш ключ): только локальная БД, без mesh/relay.
  bool get _savedMessagesLocalOnly {
    final my = ChatStorageService.normalizeDmPeerId(
        CryptoService.instance.publicKeyHex);
    if (my.isEmpty) return false;
    final peer = ChatStorageService.normalizeDmPeerId(
        _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId);
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
    if (_isEmojiBot) {
      return false;
    }
    if (_isDmBot) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isLibBot
                ? 'В чате с Lib доступен только текст'
                : _isGigachatBot
                    ? 'В чате с ИИ доступен только текст'
                    : 'В чате с ботом доступен только текст'),
          ),
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
          debugPrint(
              '[RLINK][Media] Queued for upload: ${bytes.length} bytes raw');
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
            debugPrint(
                '[RLINK][Media] In-memory blob sent: ${compressed.length} bytes');
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
      debugPrint(
          '[RLINK][Media] Relay unavailable — sending ${chunks.length} BLE gossip chunks');
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
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myId,
          recipientId: _resolvedPeerId,
        );
      }
      debugPrint(
          '[RLINK][Media] All ${chunks.length} gossip chunks sent for $msgId');
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

  /// Повтор исходящего после [MessageStatus.failed] (тот же id сообщения).
  Future<void> _retryFailedOutgoing(ChatMessage msg) async {
    if (_tearingDown || !mounted) return;
    if (!msg.isOutgoing || msg.status != MessageStatus.failed) return;
    if (_isDmBot || _savedMessagesLocalOnly) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Здесь повтор не применяется')),
        );
      }
      return;
    }

    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    if (msg.stickerPackPayload != null) {
      await StickerPackDmService.resendStickerPackMessage(
        context: context,
        msg: msg,
      );
      if (mounted) setState(() {});
      return;
    }

    final hasMedia = msg.imagePath != null ||
        msg.videoPath != null ||
        msg.voicePath != null ||
        msg.filePath != null;

    if (!hasMedia) {
      unawaited(OutboxService.instance.resendOutgoing(msg));
      return;
    }

    try {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.sending,
      );
      if (mounted) setState(() {});

      if (await MediaUploadQueue.instance.retryTaskForMsgId(msg.id)) {
        return;
      }

      String? path;
      var isVideo = false;
      var isVoice = false;
      var isFile = false;
      var isSquare = false;
      final fileName = msg.fileName;

      if (msg.imagePath != null) {
        path = ImageService.instance.resolveStoredPath(msg.imagePath!) ??
            msg.imagePath;
      } else if (msg.videoPath != null) {
        path = ImageService.instance.resolveStoredPath(msg.videoPath!) ??
            msg.videoPath;
        isVideo = true;
        if (path != null) {
          isSquare = _videoPathIsSquare(path);
        }
      } else if (msg.voicePath != null) {
        path = ImageService.instance.resolveStoredPath(msg.voicePath!) ??
            msg.voicePath;
        isVoice = true;
      } else if (msg.filePath != null) {
        path = ImageService.instance.resolveStoredPath(msg.filePath!) ??
            msg.filePath;
        isFile = true;
      }

      if (path == null || !File(path).existsSync()) {
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msg.id,
          MessageStatus.failed,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Файл сообщения не найден на устройстве'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final bytes = await File(path).readAsBytes();
      final wasQueued = await _sendMedia(
        bytes: bytes,
        msgId: msg.id,
        myId: myId,
        isVideo: isVideo,
        isVoice: isVoice,
        isFile: isFile,
        isSquare: isSquare,
        fileName: fileName,
        filePath: path,
      );

      if (!wasQueued) {
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msg.id,
          MessageStatus.sent,
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.failed,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Повтор не удался: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  static final _publicKeyRegExp = RegExp(r'^[0-9a-fA-F]{64}$');

  bool _looksLikePublicKey(String id) => _publicKeyRegExp.hasMatch(id.trim());

  String _peerStatusEmoji() {
    final contacts = ChatStorageService.instance.contactsNotifier.value;
    for (final c in contacts) {
      if (c.publicKeyHex == _resolvedPeerId ||
          c.publicKeyHex == widget.peerId) {
        return c.statusEmoji;
      }
    }
    return '';
  }

  /// Квадратное видеосообщение (камера): только суффикс имени файла `_sq.mp4`.
  static bool _videoPathIsSquare(String path) => _dmVideoPathIsSquare(path);

  /// Checks DB and updates [_isContact]. Called on init and whenever contacts change.
  Future<void> _checkContactStatus() async {
    final key =
        _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : widget.peerId;
    final contact = await ChatStorageService.instance.getContact(key);
    final relAvatar = _looksLikePublicKey(key)
        ? RelayService.instance.relayBotAvatarUrl(key)
        : null;
    final relBanner = _looksLikePublicKey(key)
        ? RelayService.instance.relayBotBannerUrl(key)
        : null;
    String? pickVisual(
        String? contactField, String? widgetField, String? relay) {
      if (contactField != null && contactField.isNotEmpty) return contactField;
      if (widgetField != null && widgetField.isNotEmpty) return widgetField;
      if (relay != null && relay.isNotEmpty) return relay;
      return contactField ?? widgetField ?? relay;
    }

    final av = pickVisual(
        contact?.avatarImagePath, widget.peerAvatarImagePath, relAvatar);
    final bn = pickVisual(
        contact?.bannerImagePath, widget.peerBannerImagePath, relBanner);
    if (!mounted) return;
    setState(() {
      _isContact = contact != null;
      _headerAvatarPath = av;
      _headerBannerPath = bn;
    });
  }

  void _syncHeaderPathsFromWidgetAndRelay() {
    final pk = _looksLikePublicKey(_resolvedPeerId) ? _resolvedPeerId : null;
    final wA = widget.peerAvatarImagePath;
    final wB = widget.peerBannerImagePath;
    _headerAvatarPath = (wA != null && wA.isNotEmpty)
        ? wA
        : (pk != null ? RelayService.instance.relayBotAvatarUrl(pk) : null);
    _headerBannerPath = (wB != null && wB.isNotEmpty)
        ? wB
        : (pk != null ? RelayService.instance.relayBotBannerUrl(pk) : null);
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
    _resolvedPeerId = _isBuiltinAiBot
        ? widget.peerId
        : BleService.instance.resolvePublicKey(widget.peerId);
    // If chat was opened by short code, try resolving to full relay key.
    if (!_isBuiltinAiBot && !_looksLikePublicKey(_resolvedPeerId)) {
      final byPrefix =
          RelayService.instance.findPeerByPrefix(_resolvedPeerId.toLowerCase());
      if (byPrefix != null && _looksLikePublicKey(byPrefix)) {
        _resolvedPeerId = byPrefix;
      }
    }
    _syncHeaderPathsFromWidgetAndRelay();
    unawaited(_loadAndMarkRead());
    unawaited((() async {
      await EmojiPackService.instance.ensureInitialized();
      EmojiPackService.instance.refreshIndexSync();
    }()));
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
    _controller.addListener(_schedulePersistComposeDraft);
    _controller.addListener(_onComposeBotSlashHints);
    // Следим за изменением маппингов BLE UUID → public key
    BleService.instance.peersCount.addListener(_onPeersChanged);
    BleService.instance.peerMappingsVersion.addListener(_onPeersChanged);
    // Следим за изменением списка контактов
    _contactListener = () => _checkContactStatus();
    ChatStorageService.instance.contactsNotifier.addListener(_contactListener!);
    _relayBotDirectoryListener = () {
      if (_tearingDown || !mounted) return;
      _syncHeaderPathsFromWidgetAndRelay();
      if (!_tearingDown && mounted) setState(() {});
      unawaited(_checkContactStatus());
      if (RelayService.instance.isRelayCatalogBot(_resolvedPeerId)) {
        _onComposeBotSlashHints();
      }
    };
    RelayService.instance.botDirectoryVersion
        .addListener(_relayBotDirectoryListener!);
    // Update message status + clear uploading indicator when background upload finishes
    MediaUploadQueue.instance.onTaskCompleted = (msgId) async {
      if (_tearingDown || !mounted) return;
      await ChatStorageService.instance
          .updateMessageStatusPreserveDelivered(msgId, MessageStatus.sent);
      if (!_tearingDown && mounted) {
        setState(() => _uploadingMsgIds.remove(msgId));
      }
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_tearingDown || !mounted || widget.forwardDraft != null) return;
      unawaited(_restoreComposeDraft());
      _prefetchRelayBotInfoIfNeeded();
    });

    if (_isGigachatBot) {
      unawaited(_refreshGigachatVpnFlag());
      _vpnConnSub = Connectivity().onConnectivityChanged.listen((results) {
        if (_tearingDown || !mounted) return;
        final on = results.contains(ConnectivityResult.vpn);
        if (on != _vpnProbablyActive) {
          if (!_tearingDown && mounted) {
            setState(() => _vpnProbablyActive = on);
          }
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
      final senderKey = _looksLikePublicKey(msg.fromId)
          ? msg.fromId
          : _looksLikePublicKey(resolved)
              ? resolved
              : _resolvedPeerId;

      if (senderKey != _resolvedPeerId) {
        _resolvedPeerId = senderKey;
        if (!_tearingDown && mounted) setState(() {});
      }

      await ChatStorageService.instance.loadMessages(_resolvedPeerId);
      if (!_tearingDown && mounted) {
        _recomputePinHighlight(ChatStorageService.instance
            .messagesNotifier(_resolvedPeerId)
            .value);
        _scrollToBottom();
        unawaited(ChatStorageService.instance.markDmRead(_resolvedPeerId));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaffoldMessenger = ScaffoldMessenger.maybeOf(context);
  }

  void _onPeersChanged() {
    if (_tearingDown || !mounted) return;
    if (_isBuiltinAiBot) return;
    final resolved = BleService.instance.resolvePublicKey(widget.peerId);
    if (resolved != _resolvedPeerId && resolved != widget.peerId) {
      if (_tearingDown || !mounted) return;
      final prev = _resolvedPeerId;
      setState(() => _resolvedPeerId = resolved);
      unawaited(_migrateComposeDraftPeerKey(prev, resolved));
      // Перезагружаем сообщения под правильным публичным ключом
      ChatStorageService.instance.loadMessages(_resolvedPeerId);
    }
    // Key may have just resolved — re-check contact status
    unawaited(_checkContactStatus());
  }

  String _composeDraftStorageKey() =>
      ChatStorageService.normalizeDmPeerId(_resolvedPeerId);

  void _schedulePersistComposeDraft() {
    if (_editingMessageId != null || _tearingDown) return;
    _draftPersistDebounce?.cancel();
    _draftPersistDebounce = Timer(const Duration(milliseconds: 450), () {
      if (_tearingDown || !mounted) return;
      unawaited(
        DmComposeDraftService.instance
            .setDraft(_composeDraftStorageKey(), _controller.text),
      );
    });
  }

  Future<void> _restoreComposeDraft() async {
    if (_tearingDown || !mounted || widget.forwardDraft != null) return;
    if (_editingMessageId != null) return;
    final raw = await DmComposeDraftService.instance
        .getDraft(_composeDraftStorageKey());
    if (_tearingDown || !mounted || raw == null || raw.isEmpty) return;
    if (_controller.text.isNotEmpty) return;
    _controller.value = TextEditingValue(
      text: raw,
      selection: TextSelection.collapsed(offset: raw.length),
    );
    if (!_tearingDown && mounted) setState(() {});
  }

  Future<void> _migrateComposeDraftPeerKey(
    String previousResolved,
    String newResolved,
  ) async {
    final a = ChatStorageService.normalizeDmPeerId(previousResolved);
    final b = ChatStorageService.normalizeDmPeerId(newResolved);
    if (a == b) return;
    final oldDraft = await DmComposeDraftService.instance.getDraft(a);
    if (oldDraft == null || oldDraft.trim().isEmpty) return;
    await DmComposeDraftService.instance.setDraft(a, '');
    await DmComposeDraftService.instance.setDraft(b, oldDraft);
    if (_tearingDown || !mounted || _editingMessageId != null) return;
    if (_controller.text.trim().isEmpty) {
      _controller.value = TextEditingValue(
        text: oldDraft,
        selection: TextSelection.collapsed(offset: oldDraft.length),
      );
      if (!_tearingDown && mounted) setState(() {});
    }
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
    if (_isDmBot) return;
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
    _tearingDown = true;
    final draftKey = ChatStorageService.normalizeDmPeerId(_resolvedPeerId);
    final draftText = _controller.text;
    _vpnConnSub?.cancel();
    _vpnConnSub = null;
    _typingDebounce?.cancel();
    _draftPersistDebounce?.cancel();
    unawaited(DmComposeDraftService.instance.setDraft(draftKey, draftText));
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
    _controller.removeListener(_schedulePersistComposeDraft);
    _controller.removeListener(_onComposeBotSlashHints);
    BleService.instance.peersCount.removeListener(_onPeersChanged);
    BleService.instance.peerMappingsVersion.removeListener(_onPeersChanged);
    if (_contactListener != null) {
      ChatStorageService.instance.contactsNotifier
          .removeListener(_contactListener!);
    }
    if (_relayBotDirectoryListener != null) {
      RelayService.instance.botDirectoryVersion
          .removeListener(_relayBotDirectoryListener!);
    }
    MediaUploadQueue.instance.onTaskCompleted = null;
    _recordingTimer?.cancel();
    _voiceAmpSub?.cancel();
    _voiceAmpSub = null;
    _recordingWaveformNotifier.dispose();
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
    if (widget.peerId == kLibBotPeerId) {
      LibBotService.instance.resetAwaitingState();
    }
    if (widget.peerId == kEmojiBotPeerId) {
      EmojiBotService.instance.resetState();
    }
    _controller.dispose();
    _scrollController.dispose();
    AudioQueueMiniPlayerLayout.instance.clearBarTop();
    super.dispose();
    scheduleMicrotask(() {
      unawaited(ChatStorageService.instance.markDmRead(peerForRead));
    });
  }

  Future<void> _startCall({required bool video}) async {
    if (_isDmBot || _savedMessagesLocalOnly) return;
    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) return;
    }
    try {
      final session = await CallService.instance.startOutgoing(
        peerId: _resolvedPeerId,
        video: video,
      );
      if (!mounted) return;
      await _openCallScreen(session);
    } on StateError catch (e) {
      final reason = e.message;
      String msg = 'Звонок уже идет. Дождитесь завершения текущего.';
      if (reason == 'peer_offline') {
        msg = 'Собеседник офлайн в relay. Звонок недоступен.';
      } else if (reason == 'invalid_recipient') {
        msg = 'Некорректный peerId. Откройте чат из контактов заново.';
      } else if (reason == 'media_init_failed') {
        msg = 'Не удалось запустить камеру/микрофон. Проверь разрешения iOS.';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    }
  }

  Future<void> _openCallScreen(CallSessionInfo session) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          session: session,
          peerName: widget.peerNickname,
          peerAvatarColor: widget.peerAvatarColor,
          peerAvatarEmoji: widget.peerAvatarEmoji,
          peerAvatarImagePath: _headerAvatarPath ?? widget.peerAvatarImagePath,
        ),
      ),
    );
  }

  // ── Voice recording ───────────────────────────────────────────

  void _resetVoiceRecordingUiState() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingSecondsNotifier.value = 0;
    _activeVoiceSegmentSeconds = 0;
    _isVoiceRecordingPaused = false;
    _activeVoiceSegmentPath = null;
    _voiceAmpSub?.cancel();
    _voiceAmpSub = null;
    _recordingWaveformNotifier.value = <double>[];
    for (final pth in _voiceSegments) {
      try {
        File(pth).deleteSync();
      } catch (_) {}
    }
    _voiceSegments.clear();
    _voiceSegmentDurations.clear();
  }

  void _startVoiceWaveform() {
    _voiceAmpSub?.cancel();
    _voiceAmpSub = VoiceService.instance
        .amplitudeStream(interval: const Duration(milliseconds: 80))
        .listen((db) {
      if (!mounted || !_isRecording || _isVoiceRecordingPaused) return;
      final normalized = ((db + 60) / 60).clamp(0.0, 1.0);
      final bars = List<double>.from(_recordingWaveformNotifier.value);
      bars.add(normalized);
      if (bars.length > 48) {
        bars.removeAt(0);
      }
      _recordingWaveformNotifier.value = bars;
    }, onError: (_) {});
  }

  Future<void> _startVoiceSegment() async {
    final pth = await VoiceService.instance.startRecording();
    if (pth == null) return;
    _activeVoiceSegmentPath = pth;
    _activeVoiceSegmentSeconds = 0;
    _isVoiceRecordingPaused = false;
    _startVoiceWaveform();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_isRecording || _isVoiceRecordingPaused) return;
      _activeVoiceSegmentSeconds += 0.25;
      final done = _voiceSegmentDurations.fold<double>(
        0,
        (a, b) => a + b,
      );
      _recordingSecondsNotifier.value = done + _activeVoiceSegmentSeconds;
      if (_recordingSecondsNotifier.value >= 60) {
        unawaited(_stopAndSendVoice());
      }
    });
  }

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
    _resetVoiceRecordingUiState();
    await _startVoiceSegment();
    if (_activeVoiceSegmentPath == null) return;
    setState(() {
      _isRecording = true;
      _voiceHoldLocked = false;
      _isVoiceRecordingPaused = false;
    });
    _sendActivity(Activity.recordingVoice);
  }

  Future<void> _pauseVoiceRecording() async {
    if (!_isRecording || _isVoiceRecordingPaused || _dmHoldVideoCam != null) {
      return;
    }
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _voiceAmpSub?.cancel();
    _voiceAmpSub = null;
    await VoiceService.instance.pauseRecording();
    final current = _activeVoiceSegmentPath;
    if (current != null &&
        !_voiceSegments.contains(current) &&
        _activeVoiceSegmentSeconds > 0) {
      _voiceSegments.add(current);
      _voiceSegmentDurations.add(_activeVoiceSegmentSeconds);
    }
    final done = _voiceSegmentDurations.fold<double>(0, (a, b) => a + b);
    _recordingSecondsNotifier.value = done;
    if (mounted) {
      setState(() {
        _isVoiceRecordingPaused = true;
        _activeVoiceSegmentSeconds = 0;
      });
    }
  }

  Future<void> _resumeVoiceRecording() async {
    if (!_isRecording || !_isVoiceRecordingPaused || _dmHoldVideoCam != null) {
      return;
    }
    await VoiceService.instance.resumeRecording();
    _isVoiceRecordingPaused = false;
    _activeVoiceSegmentSeconds = 0;
    _startVoiceWaveform();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_isRecording || _isVoiceRecordingPaused) return;
      _activeVoiceSegmentSeconds += 0.25;
      final done = _voiceSegmentDurations.fold<double>(0, (a, b) => a + b);
      _recordingSecondsNotifier.value = done + _activeVoiceSegmentSeconds;
      if (_recordingSecondsNotifier.value >= 60) {
        unawaited(_stopAndSendVoice());
      }
    });
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _trimLastVoiceSegment() async {
    if (!_isRecording || !_isVoiceRecordingPaused || _dmHoldVideoCam != null) {
      return;
    }
    if (_voiceSegments.isEmpty) return;
    final lastPath = _voiceSegments.removeLast();
    _voiceSegmentDurations.removeLast();
    try {
      await File(lastPath).delete();
    } catch (_) {}
    final done = _voiceSegmentDurations.fold<double>(0, (a, b) => a + b);
    _recordingSecondsNotifier.value = done;
    if (mounted) setState(() {});
  }

  Future<void> _hydrateVoiceTranscriptsFromDisk(
      List<ChatMessage> messages) async {
    final updates = <String, String>{};
    for (final m in messages) {
      if (m.voicePath == null) continue;
      if (_voiceTranscripts.containsKey(m.id)) continue;
      final cached = await VoiceTranscriptCacheService.instance.get(m.id);
      if (cached != null && cached.trim().isNotEmpty) {
        updates[m.id] = cached.trim();
      }
    }
    if (updates.isEmpty || !mounted || _tearingDown) return;
    setState(() => _voiceTranscripts.addAll(updates));
  }

  void _scheduleHydrateVoiceTranscripts(List<ChatMessage> messages) {
    final ids = messages
        .where((m) => m.voicePath != null)
        .map((m) => m.id)
        .toList()
      ..sort();
    final hash = '$_resolvedPeerId|${ids.join('|')}';
    if (hash == _lastVoiceHydratedMsgsHash) return;
    _lastVoiceHydratedMsgsHash = hash;
    unawaited(_hydrateVoiceTranscriptsFromDisk(messages));
  }

  Future<void> _transcribeVoiceMessage(ChatMessage msg) async {
    final id = msg.id;
    final rawPath = msg.voicePath;
    if (rawPath == null || rawPath.isEmpty) return;

    final resolved = _dmResolveMsgPath(rawPath);
    final pathForTranscribe = resolved ?? rawPath;
    if (!File(pathForTranscribe).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Файл голосового не найден')),
        );
      }
      return;
    }

    final mem = _voiceTranscripts[id];
    if (mem != null && mem.trim().isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _voiceTranscriptExpanded[id] = !(_voiceTranscriptExpanded[id] ?? false);
      });
      return;
    }

    final fromDisk = await VoiceTranscriptCacheService.instance.get(id);
    if (fromDisk != null && fromDisk.trim().isNotEmpty) {
      if (!mounted || _tearingDown) return;
      setState(() {
        _voiceTranscripts[id] = fromDisk.trim();
        _voiceTranscriptExpanded[id] = true;
      });
      return;
    }

    if (_voiceTranscribing.contains(id)) return;
    if (!LocalTranscriptionService.instance.isSupported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Локальная расшифровка пока доступна только на iOS/macOS'),
          ),
        );
      }
      return;
    }
    setState(() => _voiceTranscribing.add(id));
    try {
      final text = await LocalTranscriptionService.instance
          .transcribeFile(pathForTranscribe, language: 'ru');
      if (!mounted || _tearingDown) return;
      await VoiceTranscriptCacheService.instance.set(id, text);
      setState(() {
        _voiceTranscripts[id] = text;
        _voiceTranscriptExpanded[id] = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось расшифровать: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _voiceTranscribing.remove(id));
    }
  }

  Future<void> _stopAndSendVoice() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _voiceAmpSub?.cancel();
    _voiceAmpSub = null;
    final path = await VoiceService.instance.stopRecording();
    final duration = _recordingSecondsNotifier.value;
    setState(() {
      _isRecording = false;
      _voiceHoldLocked = false;
      _isVoiceRecordingPaused = false;
    });
    _sendActivity(Activity.stopped);

    if (path == null || duration < 0.5) {
      _resetVoiceRecordingUiState();
      return;
    }
    final segments = <String>[..._voiceSegments];
    if (segments.isEmpty || segments.last != path) {
      segments.add(path);
    }
    _voiceSegments.clear();
    _voiceSegmentDurations.clear();
    _recordingWaveformNotifier.value = <double>[];
    _recordingSecondsNotifier.value = 0;
    _activeVoiceSegmentSeconds = 0;
    _activeVoiceSegmentPath = null;
    if (!_looksLikePublicKey(_resolvedPeerId)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok) return;
    }

    try {
      final myId = CryptoService.instance.publicKeyHex;
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      for (final segPath in segments) {
        if (!File(segPath).existsSync()) continue;
        final bytes = await File(segPath).readAsBytes();
        final msgId = _uuid.v4();
        final wasQueued = await _sendMedia(
          bytes: bytes,
          msgId: msgId,
          myId: myId,
          isVoice: true,
          filePath: segPath,
        );
        await _saveAndTrack(
          ChatMessage(
            id: msgId,
            peerId: ChatStorageService.normalizeDmPeerId(targetPeerId),
            text: '🎤 Голосовое',
            isOutgoing: true,
            timestamp: DateTime.now(),
            status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
            voicePath: segPath,
          ),
          wasQueued: wasQueued,
        );
      }
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
    _voiceAmpSub?.cancel();
    _voiceAmpSub = null;
    _recordingWaveformNotifier.value = <double>[];
    _activeVoiceSegmentSeconds = 0;
    _activeVoiceSegmentPath = null;

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
          _voiceHoldLocked = false;
          _dmHoldVideoStarting = false;
        });
      }
      _sendActivity(Activity.stopped);
      return;
    }

    if (_isRecording) {
      await VoiceService.instance.cancelRecording();
      for (final pth in _voiceSegments) {
        try {
          await File(pth).delete();
        } catch (_) {}
      }
      _voiceSegments.clear();
      _voiceSegmentDurations.clear();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _voiceHoldLocked = false;
          _isVoiceRecordingPaused = false;
        });
      }
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
      return;
    }
    setState(() => _voiceHoldLocked = true);
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
    if (!mounted) return;

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
              content: Text('Ошибка видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _toggleLocation() async {
    if (_isDmBot) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('В чате с ботом доступен только текст')),
        );
      }
      return;
    }
    if (_pendingLat != null && _pendingLng != null) {
      // Already attached — clear it
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
          title: 'Выбор геолокации',
          confirmButtonLabel: 'Прикрепить геометку',
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _pendingLat = picked.latitude;
      _pendingLng = picked.longitude;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('📍 Геометка прикреплена к следующему сообщению'),
          duration: Duration(seconds: 2),
        ),
      );
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
    if (_tearingDown || !mounted) return;
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
    if (_tearingDown || !mounted) return;
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
        if (!_tearingDown && mounted) {
          setState(() => _showScrollToBottomFab = showFab);
        }
      }
    }
    final msgs =
        ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value;
    _recomputePinHighlight(msgs);
  }

  void _recomputePinHighlight(List<ChatMessage> messages) {
    if (_tearingDown || !mounted) return;
    if (_pinnedIdsChrono.isEmpty) {
      if (_pinBarHighlightId != null) {
        if (!_tearingDown && mounted) {
          setState(() => _pinBarHighlightId = null);
        }
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
    final firstIdx = (scroll / estH)
        .floor()
        .clamp(0, messages.isEmpty ? 0 : messages.length - 1);
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
      if (!_tearingDown && mounted) {
        setState(() => _pinBarHighlightId = bestId);
      }
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
      if (m.imagePath != null) {
        final base = p.basename(m.imagePath!);
        if (base.startsWith('stk_')) return '🩵 Стикер';
        return '📷 Фото';
      }
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
                      final id =
                          _pinnedIdsChrono[_pinnedIdsChrono.length - 1 - i];
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
                          _scrollController.jumpTo((idx * estH).clamp(
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
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.85)),
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
        (hintNick?.isNotEmpty == true
            ? hintNick!
            : '${authorKey.substring(0, 8)}…');
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
      forwardAuthorId: msg.isOutgoing
          ? CryptoService.instance.publicKeyHex
          : _resolvedPeerId,
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
          peerBannerImagePath: c?.bannerImagePath,
          forwardDraft: draft,
        ),
      ),
    );
  }

  /// Пересылает одно сообщение в личный чат [targetPeerId] (как после выбора в листе).
  /// Возвращает false при ошибке (и опционально показывает SnackBar).
  Future<bool> _forwardMessageToPeer(
    ChatMessage m,
    String targetPeerId,
    String forwardAuthorId,
    String forwardAuthorNick,
    String? forwardChannelId, {
    bool reloadMessagesForTarget = true,
    bool playSentSound = true,
    bool showErrorSnack = true,
  }) async {
    final myId = CryptoService.instance.publicKeyHex;
    final fid = forwardAuthorId;
    final fnk = forwardAuthorNick;
    final fch = forwardChannelId;
    var target = ChatStorageService.normalizeDmPeerId(targetPeerId);
    if (!_looksLikePublicKey(target)) {
      final ok = await _waitForPeerPublicKey();
      if (!ok || !mounted) return false;
      target = ChatStorageService.normalizeDmPeerId(_resolvedPeerId);
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
      if (playSentSound) {
        unawaited(
          SoundEffectsService.instance.playAction(ActionSound.messageSent),
        );
      }
    }

    try {
      if (m.imagePath != null && File(m.imagePath!).existsSync()) {
        final msgId = _uuid.v4();
        final docs = await getApplicationDocumentsDirectory();
        final ext = p.extension(m.imagePath!);
        final dest = '${docs.path}/fwd_$msgId${ext.isNotEmpty ? ext : '.jpg'}';
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
        final dest = '${docs.path}/fwd_$msgId${ext.isNotEmpty ? ext : '.mp4'}';
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
      } else if (m.stickerPackPayload != null &&
          m.stickerPackPayload!['type'] ==
              ChatMessage.kStickerPackPayloadType) {
        await StickerPackDmService.sendPayloadToPeer(
          context: context,
          targetPeerId: target,
          payload: m.stickerPackPayload!,
        );
      } else {
        await sendText(m.text.isNotEmpty ? m.text : ' ', _uuid.v4());
      }
      if (reloadMessagesForTarget && mounted) {
        await ChatStorageService.instance.loadMessages(target);
        if (target == ChatStorageService.normalizeDmPeerId(_resolvedPeerId)) {
          _scrollToBottom();
        }
      }
      return true;
    } catch (e) {
      if (mounted && showErrorSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Пересылка: $e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  Future<void> _runPendingForward() async {
    final d = widget.forwardDraft;
    if (d == null) return;
    await _forwardMessageToPeer(
      d.message,
      _resolvedPeerId,
      d.forwardAuthorId,
      d.originalAuthorNick,
      d.forwardChannelId,
    );
  }

  void _onSlashCommandFromBubble(String command) {
    if (_isSending || !mounted) return;
    _controller.text = command;
    setState(() {});
    unawaited(_send());
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

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

    if (!mounted) return;
    setState(() => _isSending = true);

    String? msgId;
    try {
      // Peer id might be a BLE UUID until profiles exchange completes.
      if (!_isBuiltinAiBot && !_looksLikePublicKey(_resolvedPeerId)) {
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
        if (!_savedMessagesLocalOnly && !_isBuiltinAiBot) {
          await GossipRouter.instance.sendEditMessage(
            messageId: targetId,
            newText: text,
            senderId: myId,
            recipientId: _resolvedPeerId,
          );
        }
        await ChatStorageService.instance.editMessage(targetId, text);
        if (_tearingDown || !mounted) return;
        _controller.clear();
        _cancelEdit();
        return;
      }

      // 2) Normal mode: send message(s). Личные чаты: нарезка по 600 симв. на
      // транспорт (см. OutboundDmText). ИИ — одним сообщением.
      final parts =
          _isBuiltinAiBot ? <String>[text] : OutboundDmText.splitChunks(text);
      if (parts.isEmpty) return;

      _controller.clear();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      final canonicalTargetPeerId =
          ChatStorageService.normalizeDmPeerId(targetPeerId);
      final autoEmojiPayload = (!_savedMessagesLocalOnly &&
              !_isBuiltinAiBot &&
              _looksLikePublicKey(canonicalTargetPeerId))
          ? await EmojiPackDmService.buildPayloadForText(text)
          : null;
      final lat = _isDmBot ? null : _pendingLat;
      final lng = _isDmBot ? null : _pendingLng;
      if (!_tearingDown && mounted) {
        setState(() {
          _pendingLat = null;
          _pendingLng = null;
        });
      }

      var x25519Key =
          BleService.instance.getPeerX25519Key(canonicalTargetPeerId);
      if (x25519Key == null || x25519Key.isEmpty) {
        x25519Key =
            RelayService.instance.getPeerX25519Key(canonicalTargetPeerId);
      }

      debugPrint('[RLINK][Chat] Sending ${parts.length} part(s) to '
          '${canonicalTargetPeerId.substring(0, 8)}, '
          'x25519=${x25519Key != null && x25519Key.isNotEmpty ? "YES" : "NO"}, '
          'relay=${RelayService.instance.isConnected}, '
          'mode=${AppSettings.instance.connectionMode}');

      for (var i = 0; i < parts.length; i++) {
        if (_tearingDown || !mounted) break;
        final chunk = parts[i];
        final isFirst = i == 0;
        msgId = _uuid.v4();
        final msg = ChatMessage(
          id: msgId,
          peerId: canonicalTargetPeerId,
          text: chunk,
          replyToMessageId: isFirst ? _replyToMessageId : null,
          latitude: isFirst ? lat : null,
          longitude: isFirst ? lng : null,
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: MessageStatus.sending,
        );
        await ChatStorageService.instance.saveMessage(msg);
        if (_tearingDown || !mounted) break;

        if (!_savedMessagesLocalOnly && !_isBuiltinAiBot) {
          if (x25519Key != null && x25519Key.isNotEmpty) {
            final encrypted = await CryptoService.instance.encryptMessage(
              plaintext: chunk,
              recipientX25519KeyBase64: x25519Key,
            );
            await GossipRouter.instance.sendEncryptedMessage(
              encrypted: encrypted,
              senderId: myId,
              recipientId: canonicalTargetPeerId,
              messageId: msgId,
              latitude: isFirst ? lat : null,
              longitude: isFirst ? lng : null,
              replyToMessageId: isFirst ? _replyToMessageId : null,
            );
            debugPrint('[RLINK][Chat] Sent ENCRYPTED msg $msgId');
          } else {
            await GossipRouter.instance.sendRawMessage(
              text: chunk,
              senderId: myId,
              recipientId: canonicalTargetPeerId,
              messageId: msgId,
              replyToMessageId: isFirst ? _replyToMessageId : null,
              latitude: isFirst ? lat : null,
              longitude: isFirst ? lng : null,
            );
            debugPrint('[RLINK][Chat] Sent RAW msg $msgId');
          }
        } else {
          debugPrint(
              '[RLINK][Chat] Saved messages / ИИ — сеть не используется');
        }

        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId,
          MessageStatus.sent,
        );
        if (isFirst &&
            autoEmojiPayload != null &&
            !_savedMessagesLocalOnly &&
            _looksLikePublicKey(canonicalTargetPeerId) &&
            RelayService.instance.isConnected) {
          unawaited(EmojiPackDmService.sendAutoPayloadToPeer(
            targetPeerId: canonicalTargetPeerId,
            fromId: myId,
            payload: autoEmojiPayload,
          ));
        }
        if (_tearingDown || !mounted) break;
      }

      if (_tearingDown || !mounted) return;

      await ChatStorageService.instance.loadMessages(canonicalTargetPeerId);
      _scrollToBottom();

      if (!_tearingDown && mounted) {
        setState(() {
          _replyToMessageId = null;
          _replyPreviewText = null;
        });
      }

      if (!_tearingDown && mounted && widget.peerId == kGigachatBotPeerId) {
        unawaited(_completeGigachatReply());
      } else if (!_tearingDown && mounted && widget.peerId == kLibBotPeerId) {
        unawaited(_completeLibReply(text));
      } else if (!_tearingDown && mounted && widget.peerId == kEmojiBotPeerId) {
        unawaited(_completeEmojiBotReply(text));
      }
    } catch (e) {
      if (!mounted) return;
      if (msgId != null) {
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId,
          MessageStatus.failed,
        );
      }
      _showErrorSnack('Ошибка: $e');
    } finally {
      if (!_tearingDown && mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _completeGigachatReply() async {
    if (_tearingDown || !mounted) return;
    setState(() => _aiThinking = true);
    try {
      final reply = await GigachatService.instance.completeAfterUserMessage();
      if (_tearingDown || !mounted) return;
      final botMsg = ChatMessage(
        id: _uuid.v4(),
        peerId: kGigachatBotPeerId,
        text: reply,
        isOutgoing: false,
        timestamp: DateTime.now(),
        status: MessageStatus.delivered,
      );
      await ChatStorageService.instance.saveMessage(botMsg);
      await ChatStorageService.instance.loadMessages(kGigachatBotPeerId);
      if (!_tearingDown && mounted) _scrollToBottom();
    } on GigachatException catch (e) {
      if (!_tearingDown && mounted) {
        _showErrorSnack(e.message);
      }
    } catch (e) {
      if (!_tearingDown && mounted) {
        _showErrorSnack('GigaChat: $e');
      }
    } finally {
      if (!_tearingDown && mounted) setState(() => _aiThinking = false);
    }
  }

  Future<void> _completeLibReply(String userText) async {
    if (_tearingDown || !mounted) return;
    setState(() => _aiThinking = true);
    try {
      final internetModeEnabled = AppSettings.instance.connectionMode != 0;
      final relayOnline = RelayService.instance.isConnected;
      if (!internetModeEnabled || !relayOnline) {
        final botMsg = ChatMessage(
          id: _uuid.v4(),
          peerId: kLibBotPeerId,
          text: 'Lib работает только через интернет-соединение relay. '
              'Включите режим Интернет/Both и дождитесь подключения relay.',
          isOutgoing: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        );
        await ChatStorageService.instance.saveMessage(botMsg);
        await ChatStorageService.instance.loadMessages(kLibBotPeerId);
        if (!_tearingDown && mounted) _scrollToBottom();
        return;
      }
      final lines = await LibBotService.instance.handleUserTurn(userText);
      if (_tearingDown || !mounted) return;
      final combined = lines.join('\n').trim();
      if (combined.isNotEmpty) {
        final botMsg = ChatMessage(
          id: _uuid.v4(),
          peerId: kLibBotPeerId,
          text: combined,
          isOutgoing: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        );
        await ChatStorageService.instance.saveMessage(botMsg);
      }
      if (_tearingDown || !mounted) return;
      await ChatStorageService.instance.loadMessages(kLibBotPeerId);
      if (!_tearingDown && mounted) _scrollToBottom();
    } catch (e) {
      if (!_tearingDown && mounted) {
        _showErrorSnack('Lib: $e');
      }
    } finally {
      if (!_tearingDown && mounted) setState(() => _aiThinking = false);
    }
  }

  Future<void> _completeEmojiBotReply(String userText) async {
    if (_tearingDown || !mounted) return;
    setState(() => _aiThinking = true);
    try {
      final r = await EmojiBotService.instance.handleUserTurn(userText);
      if (_tearingDown || !mounted) return;
      if (r.share != null) {
        final shareMsg = ChatMessage(
          id: _uuid.v4(),
          peerId: kEmojiBotPeerId,
          text: r.share!.previewText,
          isOutgoing: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
          invitePayloadJson: r.share!.invitePayloadJson,
        );
        await ChatStorageService.instance.saveMessage(shareMsg);
      }
      final combined = r.lines.join('\n').trim();
      if (combined.isNotEmpty) {
        final botMsg = ChatMessage(
          id: _uuid.v4(),
          peerId: kEmojiBotPeerId,
          text: combined,
          isOutgoing: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        );
        await ChatStorageService.instance.saveMessage(botMsg);
      }
      if (_tearingDown || !mounted) return;
      await ChatStorageService.instance.loadMessages(kEmojiBotPeerId);
      if (!_tearingDown && mounted) _scrollToBottom();
    } catch (e) {
      if (!_tearingDown && mounted) {
        _showErrorSnack('Emoji: $e');
      }
    } finally {
      if (!_tearingDown && mounted) setState(() => _aiThinking = false);
    }
  }

  Future<void> _pokeEmojiBotAfterOutgoingMedia(ChatMessage msg) async {
    if (widget.peerId != kEmojiBotPeerId) return;
    if (!msg.isOutgoing) return;
    final ip = msg.imagePath;
    if (ip == null || ip.trim().isEmpty) return;
    final resolved = ImageService.instance.resolveStoredPath(ip) ?? ip;
    if (!File(resolved).existsSync()) return;
    if (_tearingDown || !mounted) return;
    setState(() => _aiThinking = true);
    try {
      final lines = await EmojiBotService.instance.handleOutgoingImage(
        resolvedImagePath: resolved,
      );
      if (_tearingDown || !mounted) return;
      final text = lines.join('\n').trim();
      if (text.isNotEmpty) {
        final botMsg = ChatMessage(
          id: _uuid.v4(),
          peerId: kEmojiBotPeerId,
          text: text,
          isOutgoing: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        );
        await ChatStorageService.instance.saveMessage(botMsg);
      }
      await ChatStorageService.instance.loadMessages(kEmojiBotPeerId);
      if (!_tearingDown && mounted) _scrollToBottom();
    } catch (e) {
      if (!_tearingDown && mounted) {
        _showErrorSnack('Emoji: $e');
      }
    } finally {
      if (!_tearingDown && mounted) setState(() => _aiThinking = false);
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
    if (_isDmBot) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isLibBot
                ? 'В чате с Lib доступен только обычный текст'
                : _isGigachatBot
                    ? 'В чате с ИИ доступен только обычный текст'
                    : 'В чате с ботом доступен только обычный текст'),
          ),
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
    if (!mounted) return;
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
    if (!_savedMessagesLocalOnly && !_isDmBot) {
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
                        title:
                            Text(e.title.isEmpty ? '(без названия)' : e.title),
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
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть')),
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
    if (kIsWeb) {
      await _openWebMediaPicker(myId);
      return;
    }
    await showMediaGallerySendSheet(
      context,
      onPhotoPath: (path) => _handlePickedChatImage(XFile(path)),
      onGifPath: (path) => _sendGifFromPath(path, myId),
      onVideoPath: (path) => _sendVideoFile(XFile(path), myId),
      onStickerCropped: _sendStickerFromCroppedBytes,
      onStickerFromLibrary: _sendStickerFromLibraryPath,
      onFilePath: _sendFileFromMediaGalleryPath,
      onLocation: () async => _toggleLocation(),
      onTodo: _isDmBot ? null : _composeAndSendTodo,
      onCalendarEvent: _isDmBot ? null : _composeAndSendCalendar,
    );
  }

  Future<void> _openWebMediaPicker(String myId) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Фото'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Видео'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_outlined),
              title: const Text('Файл'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_open_rounded),
              title: const Text('Меню'),
              onTap: () => Navigator.pop(ctx, 'menu'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'photo') {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      final f = r?.files.firstOrNull;
      if (f?.bytes == null || !mounted) return;
      await _sendWebBytesAsFile(
        bytes: f!.bytes!,
        fileName: f.name.isNotEmpty ? f.name : 'photo.jpg',
        myId: myId,
        textFallback: '📷 Фото',
      );
      return;
    }
    if (choice == 'video') {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
        withData: true,
      );
      final f = r?.files.firstOrNull;
      if (f?.bytes == null || !mounted) return;
      await _sendWebVideoBytes(
        bytes: f!.bytes!,
        fileName: f.name.isNotEmpty ? f.name : 'video.mp4',
        myId: myId,
      );
      return;
    }
    if (choice == 'menu') {
      final menuChoice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  _pendingLat != null
                      ? Icons.location_on
                      : Icons.location_on_outlined,
                ),
                title:
                    Text(_pendingLat != null ? 'Убрать геометку' : 'Геометка'),
                onTap: () => Navigator.pop(ctx, 'location'),
              ),
              if (!_isDmBot)
                ListTile(
                  leading: const Icon(Icons.checklist_rtl),
                  title: const Text('Список дел'),
                  onTap: () => Navigator.pop(ctx, 'todo'),
                ),
              if (!_isDmBot)
                ListTile(
                  leading: const Icon(Icons.event_available_outlined),
                  title: const Text('Событие'),
                  onTap: () => Navigator.pop(ctx, 'calendar'),
                ),
            ],
          ),
        ),
      );
      if (!mounted || menuChoice == null) return;
      if (menuChoice == 'location') {
        await _toggleLocation();
      } else if (menuChoice == 'todo') {
        await _composeAndSendTodo();
      } else if (menuChoice == 'calendar') {
        await _composeAndSendCalendar();
      }
      return;
    }
    final r = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final f = r?.files.firstOrNull;
    if (f?.bytes == null || !mounted) return;
    await _sendWebBytesAsFile(
      bytes: f!.bytes!,
      fileName: f.name.isNotEmpty ? f.name : 'file.bin',
      myId: myId,
      textFallback: '📎 ${f.name.isNotEmpty ? f.name : 'Файл'}',
    );
  }

  Future<void> _sendWebBytesAsFile({
    required Uint8List bytes,
    required String fileName,
    required String myId,
    required String textFallback,
  }) async {
    setState(() => _isSending = true);
    _sendActivity(Activity.sendingFile);
    try {
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      var wasQueued = false;
      if (!_savedMessagesLocalOnly) {
        wasQueued = await _sendMedia(
          bytes: bytes,
          msgId: msgId,
          myId: myId,
          isFile: true,
          fileName: fileName,
          filePath: null,
        );
      }
      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: textFallback,
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          fileName: fileName,
          fileSize: bytes.length,
        ),
        wasQueued: wasQueued,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка отправки: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      _sendActivity(Activity.stopped);
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendWebVideoBytes({
    required Uint8List bytes,
    required String fileName,
    required String myId,
  }) async {
    setState(() => _isSending = true);
    _sendActivity(Activity.sendingFile);
    try {
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      var wasQueued = false;
      if (!_savedMessagesLocalOnly) {
        wasQueued = await _sendMedia(
          bytes: bytes,
          msgId: msgId,
          myId: myId,
          isVideo: true,
          isSquare: false,
          fileName: fileName,
          filePath: null,
        );
      }
      await _saveAndTrack(
        ChatMessage(
          id: msgId,
          peerId: targetPeerId,
          text: '📹 Видео',
          isOutgoing: true,
          timestamp: DateTime.now(),
          status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
          fileName: fileName,
          fileSize: bytes.length,
        ),
        wasQueued: wasQueued,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Ошибка видео: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      _sendActivity(Activity.stopped);
      if (mounted) setState(() => _isSending = false);
    }
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
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
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

  Future<void> _openStickerPicker() async {
    if (_isSending || !mounted) return;
    if (_isDmBot || _savedMessagesLocalOnly) return;
    await showStickerPickerSheet(
      context,
      onPickedSticker: _sendStickerFromLibraryPath,
    );
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
      final libSt = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        imagePath: absPath,
      );
      await _saveAndTrack(libSt, wasQueued: wasQueued);
      if (targetPeerId == kEmojiBotPeerId) {
        unawaited(_pokeEmojiBotAfterOutgoingMedia(libSt));
      }
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
    if (!mounted) return;
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
      final gifMsg = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '🎞 GIF',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        imagePath: saved,
      );
      await _saveAndTrack(gifMsg, wasQueued: wasQueued);
      if (targetPeerId == kEmojiBotPeerId) {
        unawaited(_pokeEmojiBotAfterOutgoingMedia(gifMsg));
      }
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
      unawaited(
          StickerCollectionService.instance.registerAbsoluteStickerPath(path));
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
      final cropSt = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        imagePath: path,
      );
      await _saveAndTrack(cropSt, wasQueued: wasQueued);
      if (targetPeerId == kEmojiBotPeerId) {
        unawaited(_pokeEmojiBotAfterOutgoingMedia(cropSt));
      }
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
    if (!mounted) return;
    setState(() => _isSending = true);
    try {
      final path =
          await ImageService.instance.saveVideo(picked.path, isSquare: false);
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
            bytes: bytes,
            msgId: msgId,
            myId: myId,
            isVideo: true,
            isSquare: false,
            filePath: path,
          );
        }
      }

      await _saveAndTrack(
          ChatMessage(
            id: msgId,
            peerId: targetPeerId,
            text: '📹 Видео',
            isOutgoing: true,
            timestamp: DateTime.now(),
            status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
            videoPath: path,
          ),
          wasQueued: wasQueued);
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

  /// Send photo with compression + editing (opens fullscreen on tap in chat).
  Future<void> _sendImageCompressed(XFile picked, String myId) async {
    final editedBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
          builder: (_) => ImageEditorScreen(imagePath: picked.path)),
    );
    if (editedBytes == null || !mounted) return;

    setState(() => _isSending = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
          '${tmpDir.path}/edit_${DateTime.now().millisecondsSinceEpoch}.png');
      await tmpFile.writeAsBytes(editedBytes);
      final path = await ImageService.instance.compressAndSave(tmpFile.path);
      final bytes = await File(path).readAsBytes();
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;

      final wasQueued = await _sendMedia(
          bytes: bytes, msgId: msgId, myId: myId, filePath: path);
      final imgMsg = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: '',
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
        imagePath: path,
      );
      await _saveAndTrack(imgMsg, wasQueued: wasQueued);
      if (targetPeerId == kEmojiBotPeerId) {
        unawaited(_pokeEmojiBotAfterOutgoingMedia(imgMsg));
      }
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
    if (!mounted) return;
    setState(() => _isSending = true);
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${docsDir.path}/files')
        ..createSync(recursive: true);
      final destPath =
          '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      await File(picked.path).copy(destPath);

      final fileSize = File(destPath).lengthSync();
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
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
            bytes: bytes,
            msgId: msgId,
            myId: myId,
            isFile: true,
            fileName: picked.name,
            filePath: destPath,
          );
        }
      }

      await _saveAndTrack(
          ChatMessage(
            id: msgId,
            peerId: targetPeerId,
            text: '📎 ${picked.name}',
            isOutgoing: true,
            timestamp: DateTime.now(),
            status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
            filePath: destPath,
            fileName: picked.name,
            fileSize: fileSize,
          ),
          wasQueued: wasQueued);
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

    if (kIsWeb) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
        withData: true,
      );
      final f = picked?.files.firstOrNull;
      if (f?.bytes == null || !mounted) return;
      await _sendWebVideoBytes(
        bytes: f!.bytes!,
        fileName: f.name.isNotEmpty ? f.name : 'video.mp4',
        myId: myId,
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

    // Web and some desktop providers can return null path, so keep bytes when needed.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final picked = result.files.first;
    final originalName = picked.name;
    final pickedBytes = picked.bytes;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    if (!mounted) return;
    setState(() => _isSending = true);
    _sendActivity(Activity.sendingFile);
    try {
      final msgId = _uuid.v4();
      final targetPeerId = _looksLikePublicKey(_resolvedPeerId)
          ? _resolvedPeerId
          : widget.peerId;
      bool wasQueued = false;
      String? localPath;
      int fileSize = 0;

      if (kIsWeb) {
        final webBytes = pickedBytes;
        if (webBytes == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Не удалось прочитать файл в браузере'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
        fileSize = webBytes.length;
        if (!_savedMessagesLocalOnly) {
          wasQueued = await _sendMedia(
            bytes: webBytes,
            msgId: msgId,
            myId: myId,
            isFile: true,
            fileName: originalName,
            filePath: null,
          );
        }
      } else {
        // Copy to app's files dir for persistent local storage.
        final docsDir = await getApplicationDocumentsDirectory();
        final filesDir = Directory('${docsDir.path}/files')
          ..createSync(recursive: true);
        final destPath =
            '${filesDir.path}/${DateTime.now().millisecondsSinceEpoch}_$originalName';

        if (picked.path != null) {
          await File(picked.path!).copy(destPath);
        } else if (pickedBytes != null) {
          await File(destPath).writeAsBytes(pickedBytes);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Файл недоступен: нет пути и данных'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        localPath = destPath;
        fileSize = File(destPath).lengthSync();

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
      }

      await _saveAndTrack(
          ChatMessage(
            id: msgId,
            peerId: targetPeerId,
            text: '📎 $originalName',
            isOutgoing: true,
            timestamp: DateTime.now(),
            status: wasQueued ? MessageStatus.sending : MessageStatus.sent,
            filePath: localPath,
            fileName: originalName,
            fileSize: fileSize,
          ),
          wasQueued: wasQueued);
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
      if (!_tearingDown && mounted) setState(() => _isSending = false);
    }
  }

  /// Save a message and, if it was queued for background upload,
  /// register its id so the "Загружается..." bar appears.
  Future<void> _saveAndTrack(ChatMessage msg, {required bool wasQueued}) async {
    await ChatStorageService.instance.saveMessage(msg);
    if (wasQueued && !_tearingDown && mounted) {
      setState(() => _uploadingMsgIds.add(msg.id));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_tearingDown || !mounted) return;
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
      if (_tearingDown || !mounted) return;
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
      if (_tearingDown || !mounted) return;
      final on = results.contains(ConnectivityResult.vpn);
      if (on != _vpnProbablyActive) {
        if (!_tearingDown && mounted) {
          setState(() => _vpnProbablyActive = on);
        }
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

  void _exitBulkSelect() {
    if (!_bulkSelectMode && _selectedMsgIds.isEmpty) return;
    setState(() {
      _bulkSelectMode = false;
      _selectedMsgIds.clear();
    });
  }

  void _enterBulkSelect(ChatMessage msg) {
    setState(() {
      _bulkSelectMode = true;
      _selectedMsgIds
        ..clear()
        ..add(msg.id);
    });
  }

  void _toggleBulkMessageSelection(ChatMessage msg) {
    setState(() {
      if (_selectedMsgIds.contains(msg.id)) {
        _selectedMsgIds.remove(msg.id);
        if (_selectedMsgIds.isEmpty) _bulkSelectMode = false;
      } else {
        _selectedMsgIds.add(msg.id);
      }
    });
  }

  /// В режиме выбора: долгое нажатие — выделить диапазон до этого сообщения.
  void _bulkSelectRangeThrough(List<ChatMessage> messages, int endIndex) {
    final selIdx = <int>[];
    for (var j = 0; j < messages.length; j++) {
      if (_selectedMsgIds.contains(messages[j].id)) selIdx.add(j);
    }
    selIdx.add(endIndex);
    final lo = selIdx.reduce(math.min);
    final hi = selIdx.reduce(math.max);
    setState(() {
      _bulkSelectMode = true;
      for (var j = lo; j <= hi; j++) {
        _selectedMsgIds.add(messages[j].id);
      }
    });
  }

  List<ChatMessage> _selectedMessagesInChatOrder(List<ChatMessage> all) {
    return [
      for (final m in all)
        if (_selectedMsgIds.contains(m.id)) m
    ];
  }

  Future<void> _bulkForwardFromList() async {
    final all =
        ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value;
    final ordered = _selectedMessagesInChatOrder(all);
    if (ordered.isEmpty) return;
    final picked = await showForwardDmTargetSheet(
      context,
      excludePeerId: _resolvedPeerId,
    );
    if (picked == null || !mounted) return;
    final myId = CryptoService.instance.publicKeyHex;
    var okCount = 0;
    var failCount = 0;
    for (var i = 0; i < ordered.length; i++) {
      final m = ordered[i];
      final last = i == ordered.length - 1;
      final fid = m.isOutgoing ? myId : _resolvedPeerId;
      final fnk = m.isOutgoing
          ? (ProfileService.instance.profile?.nickname ?? 'Вы')
          : widget.peerNickname;
      final ok = await _forwardMessageToPeer(
        m,
        picked.peerId,
        fid,
        fnk,
        m.forwardFromChannelId,
        reloadMessagesForTarget: false,
        playSentSound: last,
        showErrorSnack: false,
      );
      if (ok) {
        okCount++;
      } else {
        failCount++;
      }
    }
    if (!mounted) return;
    if (failCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Переслано сообщений: $okCount')),
      );
      _exitBulkSelect();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Переслано: $okCount, ошибок: $failCount',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _bulkDeleteFromList() async {
    final all =
        ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value;
    final outgoing =
        _selectedMessagesInChatOrder(all).where((m) => m.isOutgoing).toList();
    if (outgoing.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Удалить можно только свои сообщения'),
          ),
        );
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщения?'),
        content: Text(
          outgoing.length == 1
              ? 'Сообщение исчезнет у собеседника.'
              : 'Удалить ${outgoing.length} своих сообщений? Они исчезнут у собеседника.',
        ),
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
    if (ok != true || !mounted) return;

    final myId = CryptoService.instance.publicKeyHex;
    for (final m in outgoing) {
      if (_replyToMessageId == m.id) {
        _replyToMessageId = null;
        _replyPreviewText = null;
      }
      if (_editingMessageId == m.id) {
        _editingMessageId = null;
        _editingPreviewText = null;
        _controller.clear();
      }
      try {
        await ChatStorageService.instance.deleteMessage(m.id);
        if (!_savedMessagesLocalOnly) {
          await GossipRouter.instance.sendDeleteMessage(
            messageId: m.id,
            senderId: myId,
            recipientId: _resolvedPeerId,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Ошибка удаления: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
    if (mounted) {
      setState(() {});
      _exitBulkSelect();
    }
  }

  /// Текст для буфера: пересылка, цитата, тело, списки/календарь/приглашения, метки вложений.
  String _plainTextForClipboard(ChatMessage msg) {
    final lines = <String>[];
    final nick = msg.forwardFromNick?.trim();
    if (nick != null && nick.isNotEmpty) {
      lines.add('Переслано от: $nick');
    } else if (msg.forwardFromId != null &&
        msg.forwardFromId!.trim().isNotEmpty) {
      lines.add('Переслано (автор: ${msg.forwardFromId})');
    }

    final replyId = msg.replyToMessageId;
    if (replyId != null && replyId.isNotEmpty) {
      String? snap;
      final list =
          ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value;
      for (final m in list) {
        if (m.id == replyId) {
          snap = m.text.trim();
          if (snap.length > 240) snap = '${snap.substring(0, 237)}…';
          break;
        }
      }
      lines.add(snap != null && snap.isNotEmpty
          ? 'Ответ на: $snap'
          : 'Ответ на сообщение');
    }

    final todo = SharedTodoPayload.tryDecode(msg.text);
    if (todo != null) {
      final title = todo.title.trim();
      if (title.isNotEmpty) lines.add(title);
      for (final it in todo.items) {
        lines.add('${it.done ? "✓" : "○"} ${it.text}');
      }
    } else {
      final cal = SharedCalendarPayload.tryDecode(msg.text);
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
        final inv = _dmInviteMap(msg);
        if (inv != null) {
          final k = inv['kind'] as String?;
          if (k == 'device_link') {
            lines.add('Запрос на связку устройств');
          } else if (k == 'channel') {
            final name = (inv['channelName'] as String?)?.trim() ?? '';
            lines.add(name.isEmpty
                ? 'Приглашение в канал'
                : 'Приглашение в канал: $name');
          } else if (k == 'group') {
            final name = (inv['groupName'] as String?)?.trim() ?? '';
            lines.add(name.isEmpty
                ? 'Приглашение в группу'
                : 'Приглашение в группу: $name');
          } else if (k == 'emoji_pack') {
            final name = (inv['name'] as String?)?.trim() ?? '';
            lines.add(name.isEmpty ? 'Набор эмодзи' : 'Набор эмодзи: $name');
          }
          final t = msg.text.trim();
          if (t.isNotEmpty) lines.add(t);
        } else {
          final missing = dmMessageMissingLocalMedia(msg);
          final t = msg.text.trim();
          if (t.isNotEmpty && !(missing && isSyntheticMediaCaption(msg.text))) {
            lines.add(t);
          }
        }
      }
    }

    if (msg.imagePath != null && msg.imagePath!.trim().isNotEmpty) {
      lines.add('[Изображение]');
    }
    if (msg.videoPath != null && msg.videoPath!.trim().isNotEmpty) {
      lines.add('[Видео]');
    }
    if (msg.voicePath != null && msg.voicePath!.trim().isNotEmpty) {
      lines.add('[Голосовое сообщение]');
    }
    if (msg.filePath != null && msg.filePath!.trim().isNotEmpty) {
      final n = msg.fileName?.trim();
      lines.add(n != null && n.isNotEmpty ? '[Файл: $n]' : '[Файл]');
    }
    if (msg.latitude != null && msg.longitude != null) {
      lines.add('[Гео: ${msg.latitude}, ${msg.longitude}]');
    }

    return humanizeCustomEmojiCodes(lines.join('\n').trim());
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
              leading: const Icon(Icons.checklist_rtl),
              title: const Text('Выбрать'),
              onTap: () {
                Navigator.pop(ctx);
                _enterBulkSelect(msg);
              },
            ),
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
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Скопировать'),
              onTap: () async {
                Navigator.pop(ctx);
                final plain = _plainTextForClipboard(msg);
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
              },
            ),
            ListTile(
              leading: Icon(_pinnedMsgIds.contains(msg.id)
                  ? Icons.push_pin_outlined
                  : Icons.push_pin),
              title: Text(
                  _pinnedMsgIds.contains(msg.id) ? 'Открепить' : 'Закрепить'),
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
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Экспортировать…'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(shareChatMessageExternally(context, msg));
              },
            ),
            if (msg.imagePath != null &&
                msg.imagePath!.trim().isNotEmpty &&
                File(ImageService.instance.resolveStoredPath(msg.imagePath) ??
                        msg.imagePath!)
                    .existsSync())
              ListTile(
                leading: const Icon(Icons.save_alt_outlined),
                title: const Text('Сохранить фото в галерею'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final p =
                      ImageService.instance.resolveStoredPath(msg.imagePath) ??
                          msg.imagePath!;
                  await _saveImageToGallery(p);
                },
              ),
            if (msg.videoPath != null &&
                msg.videoPath!.trim().isNotEmpty &&
                File(msg.videoPath!).existsSync())
              ListTile(
                leading: const Icon(Icons.video_file_outlined),
                title: const Text('Сохранить видео в галерею'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _saveVideoToGallery(msg.videoPath!);
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
    await EmojiPackService.instance.ensureInitialized();
    final emoji = canonicalReactionEmojiKey(
        AppSettings.instance.quickReactionEmoji.trim());
    if (emoji.isEmpty) return;
    await _toggleReaction(msg, emoji);
  }

  Future<void> _openPackByShortcodeFromMessage(
    String shortcode, {
    required String sourcePeerId,
  }) async {
    final packs =
        await EmojiPackService.instance.packsContainingShortcode(shortcode);
    if (!mounted) return;
    if (packs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пак этого эмодзи пока не найден')),
      );
      return;
    }
    final preferred = packs.firstWhere(
      (p) => p.sourcePeerId == sourcePeerId,
      orElse: () => packs.first,
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => EmojiPackDetailScreen(packId: preferred.id),
      ),
    );
  }

  Future<void> _openPeerStickersFromMessage(String sourcePeerId) async {
    if (sourcePeerId.isEmpty ||
        sourcePeerId == CryptoService.instance.publicKeyHex) {
      return;
    }
    String name = sourcePeerId.substring(0, math.min(8, sourcePeerId.length));
    for (final c in ChatStorageService.instance.contactsNotifier.value) {
      if (c.publicKeyHex == sourcePeerId) {
        name = c.nickname;
        break;
      }
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PeerStickersScreen(
          peerId: sourcePeerId,
          peerName: name,
        ),
      ),
    );
  }

  void _onMessagePointerDownQuickReact(PointerDownEvent e, ChatMessage msg) {
    if (_bulkSelectMode) return;
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;
    if (!kIsWeb &&
        (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      return;
    }
    final now = DateTime.now();
    if (_lastQuickPointerMsgId == msg.id &&
        _lastQuickPointerAt != null &&
        now.difference(_lastQuickPointerAt!) <
            const Duration(milliseconds: 450)) {
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
    if (_isEmojiBot) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => const EmojiHubScreen(),
        ),
      );
      return;
    }
    if (_isBuiltinAiBot) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => const ProfileScreen(),
        ),
      );
      return;
    }
    if (_isRelayCatalogDm) {
      _openRelayBotProfile();
      return;
    }
    unawaited(() async {
      final focusMessageId = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => _PeerProfileScreen(
            peerId: _resolvedPeerId,
            nickname: widget.peerNickname,
            avatarColor: widget.peerAvatarColor,
            avatarEmoji: widget.peerAvatarEmoji,
            avatarImagePath: _headerAvatarPath ?? widget.peerAvatarImagePath,
            bannerImagePath: _headerBannerPath ?? widget.peerBannerImagePath,
          ),
        ),
      );
      if (focusMessageId != null && mounted) {
        _jumpToMessageById(focusMessageId);
      }
    }());
  }

  void _jumpToMessageById(String messageId) {
    final messages =
        ChatStorageService.instance.messagesNotifier(_resolvedPeerId).value;
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      try {
        const estH = 72.0;
        _scrollController.jumpTo((idx * estH).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        ));
      } catch (_) {}
    });
  }

  void _openRelayBotProfile() {
    if (!_isRelayCatalogDm) return;
    final h = RelayService.instance.relayCatalogBotHandle(_resolvedPeerId);
    if (h == null || h.isEmpty) return;
    unawaited(
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BotProfileScreen(
            botId: _resolvedPeerId,
            handle: h,
          ),
        ),
      ),
    );
  }

  void _prefetchRelayBotInfoIfNeeded() {
    if (!_isRelayCatalogDm) return;
    final h = RelayService.instance.relayCatalogBotHandle(_resolvedPeerId);
    if (h != null && h.isNotEmpty) {
      unawaited(RelayService.instance.fetchBotInfo(h));
    }
  }

  bool _slashSuggestionListsEqual(
    List<Map<String, String>> a,
    List<Map<String, String>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i]['cmd'] ?? '') != (b[i]['cmd'] ?? '')) return false;
    }
    return true;
  }

  List<Map<String, String>> _computeSlashBotSuggestions() {
    final text = _controller.text;
    final sel = _controller.selection;
    if (!sel.isValid) return const [];
    final end = sel.extentOffset.clamp(0, text.length);
    final before = text.substring(0, end);
    final re = RegExp(r'(?:^|[\s\n])(/[a-zA-Z0-9_]*)$');
    final m = re.firstMatch(before);
    if (m == null) return const [];
    final prefix = m.group(1)!.toLowerCase();
    var all = RelayService.instance.relayCatalogBotCommands(_resolvedPeerId);
    if (all.isEmpty) {
      final h = RelayService.instance.relayCatalogBotHandle(_resolvedPeerId);
      if (h != null) {
        unawaited(RelayService.instance.fetchBotInfo(h));
      }
      return const [];
    }
    return all
        .where((e) => ((e['cmd'] ?? '').toLowerCase()).startsWith(prefix))
        .take(12)
        .map((e) => Map<String, String>.from(e))
        .toList();
  }

  void _onComposeBotSlashHints() {
    if (!mounted || _tearingDown) return;
    if (!_isRelayCatalogDm) {
      if (_slashBotSuggestions.isNotEmpty) {
        setState(() => _slashBotSuggestions = const []);
      }
      return;
    }
    final next = _computeSlashBotSuggestions();
    if (next.length != _slashBotSuggestions.length ||
        !_slashSuggestionListsEqual(next, _slashBotSuggestions)) {
      setState(() => _slashBotSuggestions = next);
    }
  }

  void _applySlashSuggestion(String cmd) {
    final text = _controller.text;
    final sel = _controller.selection;
    if (!sel.isValid) return;
    final end = sel.extentOffset.clamp(0, text.length);
    final before = text.substring(0, end);
    final slash = before.lastIndexOf('/');
    if (slash < 0) return;
    if (text.substring(slash, end).contains(' ')) return;
    final newText = text.replaceRange(slash, end, '$cmd ');
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: slash + cmd.length + 1),
    );
    if (mounted) {
      setState(() => _slashBotSuggestions = const []);
    }
  }

  void _onRequestMissingDmMedia(ChatMessage msg) {
    if (!mounted) return;
    if (PendingMediaService.instance.hasPending(msg.id)) {
      unawaited(_downloadPendingMedia(msg));
      return;
    }
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

  Future<void> _downloadPendingMedia(ChatMessage msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Загрузка…'),
        duration: Duration(seconds: 1),
      ),
    );
    final ok = await PendingMediaService.instance.processBlob(msg.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Данные уже недоступны — попросите переслать')),
      );
    }
  }

  Future<void> _ensureGalAccess() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (await Gal.hasAccess(toAlbum: true)) return;
    await Gal.requestAccess(toAlbum: true);
  }

  Future<void> _saveImageToGallery(String imagePath) async {
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await _ensureGalAccess();
        await Gal.putImage(imagePath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Фото сохранено в галерею')));
        }
      } else if (!kIsWeb) {
        // Desktop: copy to Downloads folder
        final downloads =
            Directory('${Platform.environment['HOME'] ?? '.'}/Downloads');
        final dst = File(
            '${downloads.path}/rlink_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await File(imagePath).copy(dst.path);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Сохранено: ${dst.path}')));
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Сохранение на web пока не поддерживается')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _saveVideoToGallery(String videoPath) async {
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await _ensureGalAccess();
        await Gal.putVideo(videoPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Видео сохранено в галерею')),
          );
        }
      } else if (!kIsWeb) {
        final downloads =
            Directory('${Platform.environment['HOME'] ?? '.'}/Downloads');
        final ext = p.extension(videoPath);
        final safeExt = ext.isNotEmpty ? ext : '.mp4';
        final dst = File(
          '${downloads.path}/rlink_${DateTime.now().millisecondsSinceEpoch}$safeExt',
        );
        await File(videoPath).copy(dst.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Сохранено: ${dst.path}')),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сохранение на web пока не поддерживается'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureMiniPlayerLayoutSync();
    return PopScope(
      canPop: !_bulkSelectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_bulkSelectMode && mounted) {
          // Не вызывать setState синхронно из колбэка pop — элемент может быть
          // уже в процессе деактивации (красный экран _elements.contains).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _exitBulkSelect();
          });
        }
      },
      child: Scaffold(
        appBar: _bulkSelectMode
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Отмена',
                  onPressed: _exitBulkSelect,
                ),
                title: Text(
                  _selectedMsgIds.isEmpty
                      ? 'Выбор сообщений'
                      : '${_selectedMsgIds.length} выбрано',
                ),
                actions: [
                  IconButton(
                    tooltip: 'Переслать',
                    icon: const Icon(Icons.forward),
                    onPressed: _selectedMsgIds.isEmpty
                        ? null
                        : () => unawaited(_bulkForwardFromList()),
                  ),
                  IconButton(
                    tooltip: 'Удалить свои',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _selectedMsgIds.isEmpty
                        ? null
                        : () => unawaited(_bulkDeleteFromList()),
                  ),
                ],
              )
            : AppBar(
                titleSpacing: 0,
                title: Row(children: [
                  _isRelayCatalogDm
                      ? InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: _openRelayBotProfile,
                          child: AvatarWidget(
                            initials: widget.peerNickname.isNotEmpty
                                ? widget.peerNickname[0].toUpperCase()
                                : '?',
                            color: widget.peerAvatarColor,
                            emoji: widget.peerAvatarEmoji,
                            imagePath:
                                _headerAvatarPath ?? widget.peerAvatarImagePath,
                            size: 38,
                            isOnline: !_isDmBot &&
                                (BleService.instance
                                        .isPeerConnected(_resolvedPeerId) ||
                                    (RelayService.instance.isConnected &&
                                        RelayService.instance
                                            .isPeerOnline(_resolvedPeerId))),
                          ),
                        )
                      : AvatarWidget(
                          initials: widget.peerNickname.isNotEmpty
                              ? widget.peerNickname[0].toUpperCase()
                              : '?',
                          color: widget.peerAvatarColor,
                          emoji: widget.peerAvatarEmoji,
                          imagePath:
                              _headerAvatarPath ?? widget.peerAvatarImagePath,
                          size: 38,
                          isOnline: !_isDmBot &&
                              (BleService.instance
                                      .isPeerConnected(_resolvedPeerId) ||
                                  (RelayService.instance.isConnected &&
                                      RelayService.instance
                                          .isPeerOnline(_resolvedPeerId))),
                        ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _isRelayCatalogDm
                        ? InkWell(
                            onTap: _openRelayBotProfile,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        widget.peerNickname,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (RelayService.instance
                                        .relayCatalogBotVerified(
                                            _resolvedPeerId)) ...[
                                      const SizedBox(width: 4),
                                      Icon(
                                        Icons.verified,
                                        size: 16,
                                        color: Colors.blue.shade700,
                                      ),
                                    ],
                                  ],
                                ),
                                if (_isDmBot)
                                  Container(
                                    margin: const EdgeInsets.only(top: 2),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      'БОТ',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.3,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                if (_isDmBot)
                                  Text(
                                    _isLibBot
                                        ? 'Официальный бот · регистратор ботов'
                                        : _isGigachatBot
                                            ? 'Официальный бот · ИИ GigaChat (Сбер)'
                                            : _isEmojiBot
                                                ? 'Официальный бот · свои эмодзи (:shortcode:)'
                                                : 'Сторонний бот · только текст, ответ когда процесс бота в сети',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(widget.peerNickname,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600)),
                                    ),
                                    if (_peerStatusEmoji().isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      StatusEmojiView(
                                        statusEmoji: _peerStatusEmoji(),
                                        fontSize: 16,
                                      ),
                                    ],
                                    if (_isBuiltinAiBot) ...[
                                      const SizedBox(width: 4),
                                      Icon(
                                        Icons.verified,
                                        size: 16,
                                        color: Colors.blue.shade700,
                                      ),
                                    ],
                                  ],
                                ),
                                if (_isDmBot)
                                  Container(
                                    margin: const EdgeInsets.only(top: 2),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      'БОТ',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.3,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                if (_isDmBot)
                                  Text(
                                    _isLibBot
                                        ? 'Официальный бот · регистратор ботов'
                                        : _isGigachatBot
                                            ? 'Официальный бот · ИИ GigaChat (Сбер)'
                                            : _isEmojiBot
                                                ? 'Официальный бот · свои эмодзи (:shortcode:)'
                                                : 'Сторонний бот · только текст, ответ когда процесс бота в сети',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  )
                                else
                                  ValueListenableBuilder<int>(
                                    valueListenable:
                                        TypingService.instance.version,
                                    builder: (_, __, ___) {
                                      final activity = TypingService.instance
                                          .activityFor(_resolvedPeerId);
                                      if (activity != Activity.stopped) {
                                        final label = TypingService.instance
                                            .label(activity);
                                        return Text(
                                          label,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF1DB954)),
                                        );
                                      }
                                      return ValueListenableBuilder<int>(
                                        valueListenable:
                                            BleService.instance.peersCount,
                                        builder: (_, __, ___) {
                                          return ValueListenableBuilder<int>(
                                            valueListenable: RelayService
                                                .instance.presenceVersion,
                                            builder: (_, __, ___) {
                                              final online = BleService.instance
                                                  .isPeerConnected(
                                                      _resolvedPeerId);
                                              final relayOnline = RelayService
                                                      .instance.isConnected &&
                                                  RelayService.instance
                                                      .isPeerOnline(
                                                          _resolvedPeerId);
                                              final isOnline =
                                                  online || relayOnline;
                                              return Text(
                                                isOnline
                                                    ? 'в сети'
                                                    : 'не в сети',
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
                  ),
                ]),
                actions: [
                  if (!_isDmBot && !_savedMessagesLocalOnly)
                    IconButton(
                      tooltip: 'Аудиозвонок',
                      onPressed: () => _startCall(video: false),
                      icon: const Icon(Icons.call_outlined),
                    ),
                  if (!_isDmBot && !_savedMessagesLocalOnly)
                    IconButton(
                      tooltip: 'Видеозвонок',
                      onPressed: () => _startCall(video: true),
                      icon: const Icon(Icons.videocam_outlined),
                    ),
                  PopupMenuButton<String>(
                    itemBuilder: (_) {
                      final hasBg = (AppSettings.instance
                                  .chatBgForPeer(_resolvedPeerId) ??
                              AppSettings.instance
                                  .chatBgForPeer('__global__')) !=
                          null;
                      return [
                        const PopupMenuItem(
                            value: 'profile', child: Text('Профиль')),
                        if (!_isDmBot && !_savedMessagesLocalOnly)
                          const PopupMenuItem(
                            value: 'edit_contact',
                            child: Text('Изменить контакт'),
                          ),
                        if (!_isDmBot)
                          const PopupMenuItem(
                            value: 'peer_stickers',
                            child: Text('Стикеры из чата'),
                          ),
                        if (!_isDmBot)
                          const PopupMenuItem(
                              value: 'chat_cal', child: Text('Календарь чата')),
                        const PopupMenuItem(
                            value: 'background', child: Text('Фон чата')),
                        if (hasBg)
                          const PopupMenuItem(
                              value: 'remove_bg', child: Text('Убрать фон')),
                        const PopupMenuItem(
                            value: 'export', child: Text('Экспорт в файл')),
                        const PopupMenuItem(
                            value: 'delete', child: Text('Удалить чат')),
                      ];
                    },
                    onSelected: (v) async {
                      switch (v) {
                        case 'profile':
                          _openPeerProfile();
                          break;
                        case 'edit_contact':
                          final c = await ChatStorageService.instance
                              .getContact(_resolvedPeerId);
                          if (c == null || !context.mounted) break;
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ContactEditScreen(contact: c),
                            ),
                          );
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
                              content:
                                  const Text('Чат будет удалён окончательно.'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Отмена')),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Удалить',
                                      style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await ChatStorageService.instance
                                .deleteChat(_resolvedPeerId);
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
              SizedBox(height: 0, key: _audioQueueMiniPlayerAnchor),
              // Sending / uploading status bar
              if (_aiThinking)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: Row(children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _isLibBot
                          ? 'Lib отвечает…'
                          : _isGigachatBot
                              ? 'GigaChat формирует ответ…'
                              : _isEmojiBot
                                  ? 'Emoji…'
                                  : 'Ждём ответ бота…',
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ]),
                ),
              if (_isGigachatBot && _vpnProbablyActive)
                Material(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 20,
                          color:
                              Theme.of(context).colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Включён VPN: GigaChat может не ответить или ругаться на сертификат. '
                            'При ошибках попробуйте отключить VPN.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onTertiaryContainer,
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
                            .fold<double?>(null,
                                (acc, v) => acc == null ? v : (acc + v) / 2);
                    final label = uploadProgress != null
                        ? 'Загружается файл... ${(uploadProgress * 100).round()}%'
                        : 'Отправка...';
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Row(children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: uploadProgress,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
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
                  !_isDmBot)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Row(children: [
                    Icon(Icons.person_add_outlined,
                        size: 18, color: Theme.of(context).colorScheme.primary),
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
                            const SnackBar(
                                content: Text('Пользователь заблокирован')),
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
                            x25519Key:
                                CryptoService.instance.x25519PublicKeyBase64,
                            tags: myProfile.tags,
                            statusEmoji: myProfile.statusEmoji,
                          );
                        } else {
                          // Key not yet resolved — broadcast so the peer learns who we are
                          await GossipRouter.instance.broadcastProfile(
                            id: myProfile.publicKeyHex,
                            nick: myProfile.nickname,
                            username: myProfile.username,
                            color: myProfile.avatarColor,
                            emoji: myProfile.avatarEmoji,
                            x25519Key:
                                CryptoService.instance.x25519PublicKeyBase64,
                            tags: myProfile.tags,
                            statusEmoji: myProfile.statusEmoji,
                          );
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Запрос на обмен отправлен — ожидаем ответ'),
                              duration: Duration(seconds: 3),
                            ),
                          );
                          setState(() => _strangerBannerDismissed = true);
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () =>
                          setState(() => _strangerBannerDismissed = true),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close,
                            size: 18,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.5)),
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
                        final path = AppSettings.instance
                                .chatBgForPeer(_resolvedPeerId) ??
                            AppSettings.instance.chatBgForPeer('__global__');
                        if (path == null) return const SizedBox.shrink();
                        return Image.file(File(path), fit: BoxFit.cover);
                      },
                    ),
                    RepaintBoundary(
                      child: ValueListenableBuilder<List<ChatMessage>>(
                        valueListenable: ChatStorageService.instance
                            .messagesNotifier(_resolvedPeerId),
                        builder: (_, messages, __) {
                          if (messages.isEmpty) {
                            return Center(
                              child: Text('Нет сообщений',
                                  style:
                                      TextStyle(color: Colors.grey.shade600)),
                            );
                          }
                          final messageTextById = <String, String>{
                            for (final m in messages) m.id: m.text,
                          };
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted || _tearingDown) return;
                            _scheduleHydrateVoiceTranscripts(messages);
                          });
                          final pinBar = _pinnedIdsChrono.isEmpty
                              ? null
                              : _buildPinnedBar(messages);
                          final n = messages.length;
                          if (n != _lastPinSyncMessageCount &&
                              !_pendingMessageCountPinSync) {
                            _pendingMessageCountPinSync = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _pendingMessageCountPinSync = false;
                              if (_tearingDown || !mounted) return;
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
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemCount: messages.length,
                                  itemBuilder: (_, i) {
                                    final msg = messages[i];
                                    final showDate = i == 0 ||
                                        !_sameDay(messages[i - 1].timestamp,
                                            msg.timestamp);
                                    return Column(
                                        key:
                                            ValueKey<String>('dmrow_${msg.id}'),
                                        children: [
                                          if (showDate)
                                            _DateDivider(date: msg.timestamp),
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (_bulkSelectMode)
                                                Material(
                                                  color: Colors.transparent,
                                                  child: InkWell(
                                                    onTap: () =>
                                                        _toggleBulkMessageSelection(
                                                            msg),
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              left: 6,
                                                              right: 2,
                                                              top: 8),
                                                      child: Icon(
                                                        _selectedMsgIds
                                                                .contains(
                                                                    msg.id)
                                                            ? Icons.check_circle
                                                            : Icons
                                                                .radio_button_unchecked,
                                                        size: 22,
                                                        color: _selectedMsgIds
                                                                .contains(
                                                                    msg.id)
                                                            ? Theme.of(context)
                                                                .colorScheme
                                                                .primary
                                                            : Theme.of(context)
                                                                .colorScheme
                                                                .outline,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              Expanded(
                                                child: SwipeToReply(
                                                  enabled: !_bulkSelectMode,
                                                  isOutgoing: msg.isOutgoing,
                                                  onReply: () =>
                                                      _startReply(msg),
                                                  child: Listener(
                                                    behavior: HitTestBehavior
                                                        .translucent,
                                                    onPointerDown: _bulkSelectMode
                                                        ? null
                                                        : (e) =>
                                                            _onMessagePointerDownQuickReact(
                                                                e, msg),
                                                    child: GestureDetector(
                                                      behavior: HitTestBehavior
                                                          .deferToChild,
                                                      onTap: _bulkSelectMode
                                                          ? () =>
                                                              _toggleBulkMessageSelection(
                                                                  msg)
                                                          : null,
                                                      onLongPress: _bulkSelectMode
                                                          ? () =>
                                                              _bulkSelectRangeThrough(
                                                                  messages, i)
                                                          : () =>
                                                              _onLongPressMessage(
                                                                  msg),
                                                      onDoubleTap:
                                                          _bulkSelectMode
                                                              ? null
                                                              : () => unawaited(
                                                                  _quickReaction(
                                                                      msg)),
                                                      child: _MessageBubble(
                                                        msg: msg,
                                                        bulkSelectMode:
                                                            _bulkSelectMode,
                                                        replyPreviewText: msg
                                                                    .replyToMessageId ==
                                                                null
                                                            ? null
                                                            : messageTextById[msg
                                                                .replyToMessageId],
                                                        onDownloadImage:
                                                            _saveImageToGallery,
                                                        onLongPressSaveImageToGallery:
                                                            _bulkSelectMode
                                                                ? null
                                                                : (p) => unawaited(
                                                                    _saveImageToGallery(
                                                                        p)),
                                                        onLongPressSaveVideoToGallery:
                                                            _bulkSelectMode
                                                                ? null
                                                                : (p) => unawaited(
                                                                    _saveVideoToGallery(
                                                                        p)),
                                                        onCollabPersist:
                                                            _patchSharedCollab,
                                                        onForwardContextTap:
                                                            _onForwardContextTap,
                                                        onRequestMissingMedia:
                                                            _onRequestMissingDmMedia,
                                                        onRetryFailed: (!_isDmBot &&
                                                                !_savedMessagesLocalOnly)
                                                            ? _retryFailedOutgoing
                                                            : null,
                                                        onTranscribeVoice:
                                                            _transcribeVoiceMessage,
                                                        isVoiceTranscribing:
                                                            (messageId) =>
                                                                _voiceTranscribing
                                                                    .contains(
                                                          messageId,
                                                        ),
                                                        voiceTranscript:
                                                            (messageId) =>
                                                                _voiceTranscripts[
                                                                    messageId],
                                                        voiceTranscriptExpanded:
                                                            (messageId) =>
                                                                _voiceTranscriptExpanded[
                                                                    messageId] ??
                                                                false,
                                                        onVoiceTranscriptExpanded:
                                                            (messageId, open) {
                                                          setState(() =>
                                                              _voiceTranscriptExpanded[
                                                                      messageId] =
                                                                  open);
                                                        },
                                                        playbackThread:
                                                            messages,
                                                        playbackIndex: i,
                                                        highlightSlashCommands:
                                                            _isDmBot,
                                                        onSlashCommandTap: _isDmBot
                                                            ? _onSlashCommandFromBubble
                                                            : null,
                                                        dmIncomingBotHeader:
                                                            _isDmBot,
                                                        dmBotDisplayName:
                                                            widget.peerNickname,
                                                        dmBotVerified:
                                                            _isBuiltinAiBot ||
                                                                RelayService
                                                                    .instance
                                                                    .relayCatalogBotVerified(
                                                                        _resolvedPeerId),
                                                        onCustomEmojiTap: (shortcode,
                                                                sourcePeerId) =>
                                                            _openPackByShortcodeFromMessage(
                                                          shortcode,
                                                          sourcePeerId:
                                                              sourcePeerId,
                                                        ),
                                                        onStickerTapFromPeer:
                                                            _openPeerStickersFromMessage,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
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
              if (!_bulkSelectMode) ...[
                if (_editingMessageId != null || _replyToMessageId != null)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.3)),
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
                if (!_bulkSelectMode && _slashBotSuggestions.isNotEmpty)
                  Material(
                    elevation: 2,
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final row in _slashBotSuggestions)
                              ListTile(
                                dense: true,
                                leading: Icon(
                                  Icons.terminal,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                title: Text(
                                  row['cmd'] ?? '',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w600,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                subtitle: (row['desc'] ?? '').isNotEmpty
                                    ? Text(row['desc']!)
                                    : null,
                                onTap: () =>
                                    _applySlashSuggestion(row['cmd'] ?? ''),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                _InputBar(
                  controller: _controller,
                  isSending: _isSending,
                  isRecording: _isRecording,
                  isVoiceRecordingMode: _isRecording && _dmHoldVideoCam == null,
                  voiceControlsEnabled: _isRecording &&
                      _dmHoldVideoCam == null &&
                      _voiceHoldLocked,
                  recordingPaused: _isVoiceRecordingPaused,
                  isHoldVideoStarting: _dmHoldVideoStarting,
                  recordingSecondsNotifier: _recordingSecondsNotifier,
                  recordingWaveformNotifier: _recordingWaveformNotifier,
                  hintText: _isDmBot
                      ? (_isLibBot
                          ? 'Команда для Lib…'
                          : _isEmojiBot
                              ? 'Команда для Emoji…'
                              : _isGigachatBot
                                  ? 'Сообщение для GigaChat…'
                                  : 'Сообщение боту…')
                      : null,
                  aiTextOnlyComposer: _isDmBot && !_isEmojiBot,
                  allowMediaRecord: !isAiBotPeerId(widget.peerId),
                  onOpenEmojiInsert: (!_isDmBot || _isEmojiBot)
                      ? () => unawaited(showChatEmojiInsertSheet(
                            context,
                            onInsert: (insert) {
                              final t = _controller.text;
                              final sel = _controller.selection;
                              final off = sel.isValid ? sel.start : t.length;
                              final end = sel.isValid ? sel.end : t.length;
                              final next = t.replaceRange(off, end, insert);
                              final newOff = off + insert.length;
                              _controller.value = TextEditingValue(
                                text: next,
                                selection:
                                    TextSelection.collapsed(offset: newOff),
                              );
                            },
                          ))
                      : null,
                  locationActive: _pendingLat != null,
                  onSend: _send,
                  onLongPressSend: _scheduleSendDialog,
                  onPickTodo: _isDmBot ? null : _composeAndSendTodo,
                  onPickCalendar: _isDmBot ? null : _composeAndSendCalendar,
                  onOpenMediaGallery: _openMediaGallery,
                  onOpenStickerPicker: (_isDmBot || _savedMessagesLocalOnly)
                      ? null
                      : _openStickerPicker,
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
                  onVoicePause: _pauseVoiceRecording,
                  onVoiceResume: _resumeVoiceRecording,
                  onVoiceTrimLastPart: _trimLastVoiceSegment,
                  onLocation: _toggleLocation,
                  holdVideoPausedListenable: _dmHoldVideoPausedNotifier,
                  onHoldRecordingLockChanged: _onHoldRecordingLockChanged,
                  onHoldVideoLockedPauseToggle: _toggleDmHoldVideoPause,
                ),
              ],
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
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24),
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
              style:
                  TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
        ),
        Expanded(child: Divider(color: Theme.of(context).dividerColor)),
      ]),
    );
  }
}

// ── Приглашения в канал / группу в ЛС ───────────────────────────

Map<String, dynamic>? _dmInviteMap(ChatMessage msg) {
  if (msg.stickerPackPayload != null) return null;
  final raw = msg.invitePayloadJson;
  if (raw != null && raw.isNotEmpty) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final k = m['kind'] as String?;
      final t = m['type'] as String?;
      if (k == 'channel' || k == 'group' || k == 'device_link') return m;
      if (k == 'emoji_pack' || t == 'emoji_pack') {
        return {...m, 'kind': 'emoji_pack'};
      }
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

  Future<void> _respondDeviceLink(
    BuildContext context, {
    required bool accepted,
  }) async {
    final publicKey = (data['publicKey'] as String? ?? '').trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(publicKey)) return;
    final me = ProfileService.instance.profile;
    if (me == null) return;

    final nick = (data['nick'] as String? ?? '').trim();
    final username = (data['username'] as String? ?? '').trim();
    final deviceName = nick.isNotEmpty ? nick : username;
    final settings = AppSettings.instance;

    if (!accepted) {
      await GossipRouter.instance.sendDeviceLinkAck(
        publicKey: me.publicKeyHex,
        nick: me.nickname,
        recipientId: publicKey,
        accepted: false,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Запрос связки отклонен')),
        );
      }
      return;
    }

    final alreadyLinked = settings.isDeviceLinked;
    final linkedToSame =
        settings.linkedDevicePublicKey.toLowerCase() == publicKey;
    if ((alreadyLinked && !linkedToSame) || settings.isPrimaryDevice) {
      await GossipRouter.instance.sendDeviceLinkAck(
        publicKey: me.publicKeyHex,
        nick: me.nickname,
        recipientId: publicKey,
        accepted: false,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Связка уже активна на этом устройстве')),
        );
      }
      return;
    }

    await settings.linkAsChildDevice(
      devicePublicKey: publicKey,
      deviceNickname: deviceName,
    );
    await ChatStorageService.instance.deleteAllDirectMessages();
    await GroupService.instance.resetAll();
    await ChannelService.instance.resetAll();
    EtherService.instance.messages.value = const [];
    EtherService.instance.unreadCount.value = 0;
    await applyConnectionTransport();
    await GossipRouter.instance.sendDeviceLinkAck(
      publicKey: me.publicKeyHex,
      nick: me.nickname,
      recipientId: publicKey,
      accepted: true,
    );
    await DeviceLinkSyncService.instance.onLinkedAsChild();

    // Persist the accepted state on the invite itself.
    final currentInvite = data;
    final enriched = <String, dynamic>{
      ...currentInvite,
      'acceptedAt': DateTime.now().millisecondsSinceEpoch,
    };
    final inviteId = data['inviteMessageId'] as String?;
    if (inviteId != null && inviteId.isNotEmpty) {
      final existing =
          await ChatStorageService.instance.getMessageById(inviteId);
      if (existing != null) {
        await ChatStorageService.instance.saveMessage(
          existing.copyWith(invitePayloadJson: jsonEncode(enriched)),
        );
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Устройство переведено в дочерний режим')),
      );
    }
  }

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
      createdAt:
          data['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
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
      createdAt:
          data['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
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
      createdAt:
          data['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
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
    if (kind == 'device_link') {
      final acceptedAt = (data['acceptedAt'] as num?)?.toInt();
      if (acceptedAt != null) {
        return const SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: null,
            child: Text('Запрос принят'),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: isOut
                ? null
                : () => unawaited(
                      _respondDeviceLink(context, accepted: true),
                    ),
            child: const Text('Принять'),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            onPressed: isOut
                ? null
                : () => unawaited(
                      _respondDeviceLink(context, accepted: false),
                    ),
            child: const Text('Отклонить'),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}

// ── Пузырь сообщения ─────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final String? replyPreviewText;
  final bool bulkSelectMode;
  final Function(String)? onDownloadImage;
  final void Function(String path)? onLongPressSaveImageToGallery;
  final void Function(String path)? onLongPressSaveVideoToGallery;
  final Future<void> Function(ChatMessage msg, String newEncoded)?
      onCollabPersist;
  final void Function(ChatMessage msg)? onForwardContextTap;
  final void Function(ChatMessage msg)? onRequestMissingMedia;
  final Future<void> Function(ChatMessage msg)? onRetryFailed;
  final Future<void> Function(ChatMessage msg)? onTranscribeVoice;
  final bool Function(String messageId)? isVoiceTranscribing;
  final String? Function(String messageId)? voiceTranscript;
  final bool Function(String messageId)? voiceTranscriptExpanded;
  final void Function(String messageId, bool expanded)?
      onVoiceTranscriptExpanded;
  final List<ChatMessage>? playbackThread;
  final int? playbackIndex;
  final bool highlightSlashCommands;
  final void Function(String command)? onSlashCommandTap;
  final bool dmIncomingBotHeader;
  final String? dmBotDisplayName;
  final bool dmBotVerified;
  final Future<void> Function(String shortcode, String sourcePeerId)?
      onCustomEmojiTap;
  final Future<void> Function(String sourcePeerId)? onStickerTapFromPeer;

  const _MessageBubble({
    required this.msg,
    this.replyPreviewText,
    this.bulkSelectMode = false,
    this.onDownloadImage,
    this.onLongPressSaveImageToGallery,
    this.onLongPressSaveVideoToGallery,
    this.onCollabPersist,
    this.onForwardContextTap,
    this.onRequestMissingMedia,
    this.onRetryFailed,
    this.onTranscribeVoice,
    this.isVoiceTranscribing,
    this.voiceTranscript,
    this.voiceTranscriptExpanded,
    this.onVoiceTranscriptExpanded,
    this.playbackThread,
    this.playbackIndex,
    this.highlightSlashCommands = false,
    this.onSlashCommandTap,
    this.dmIncomingBotHeader = false,
    this.dmBotDisplayName,
    this.dmBotVerified = false,
    this.onCustomEmojiTap,
    this.onStickerTapFromPeer,
  });

  static final RegExp _botButtonToken = RegExp(
    r'\[btn:([^\]|]+)\|([^\]]+)\]',
    multiLine: true,
  );

  ({String text, List<(String, String)> buttons}) _parseBotButtons(String raw) {
    final buttons = <(String, String)>[];
    final cleaned = raw.replaceAllMapped(_botButtonToken, (m) {
      final label = (m.group(1) ?? '').trim();
      final command = (m.group(2) ?? '').trim();
      if (label.isEmpty || command.isEmpty || !command.startsWith('/')) {
        return '';
      }
      buttons.add((label, command));
      return '';
    });
    return (text: cleaned.trim(), buttons: buttons);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isOut = msg.isOutgoing;
    final settings = AppSettings.instance;
    final compact = settings.compactMode;
    final missing = dmMessageMissingLocalMedia(msg);
    final inviteMap = _dmInviteMap(msg);
    final parsed = _parseBotButtons(msg.text);
    final plainText = parsed.text;
    final slashButtons = parsed.buttons;

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
            left: isOut ? (compact ? 56 : 64) : (compact ? 8 : 12),
            right: isOut ? (compact ? 8 : 12) : (compact ? 56 : 64),
            bottom: settings.messageBubbleBottomMargin,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: settings.messageVerticalPadding,
          ),
          decoration: BoxDecoration(
            color: isOut ? cs.primary : cs.surfaceContainerHigh,
            borderRadius: settings.bubbleRadius(isMe: isOut),
          ),
          child: Column(
            crossAxisAlignment:
                isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (dmIncomingBotHeader &&
                  !isOut &&
                  (dmBotDisplayName ?? '').isNotEmpty) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        dmBotDisplayName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isOut ? cs.onPrimary : cs.primary,
                        ),
                      ),
                    ),
                    if (dmBotVerified) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.verified,
                        size: 12,
                        color: Colors.blue.shade700,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
              ],
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
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
                    transcript: voiceTranscript?.call(msg.id),
                    transcriptExpanded:
                        voiceTranscriptExpanded?.call(msg.id) ?? false,
                    onTranscriptExpandedChanged: onVoiceTranscriptExpanded ==
                            null
                        ? null
                        : (open) => onVoiceTranscriptExpanded!(msg.id, open),
                    onTranscribeTap: onTranscribeVoice == null
                        ? null
                        : () => unawaited(onTranscribeVoice!(msg)),
                    isTranscribing: isVoiceTranscribing?.call(msg.id) ?? false,
                    hasTranscript: (() {
                      final t = voiceTranscript?.call(msg.id);
                      return t != null && t.trim().isNotEmpty;
                    })(),
                    onPlayWithQueue:
                        playbackThread != null && playbackIndex != null
                            ? () {
                                VoiceService.instance
                                    .playQueue(_dmPlaybackQueueFrom(
                                        playbackThread!, playbackIndex!))
                                    .catchError((e) {
                                  debugPrint('[Voice] playQueue error: $e');
                                });
                              }
                            : null,
                  ),
                ),
              if (msg.videoPath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _VideoMessageBubble(
                    videoPath: msg.videoPath!,
                    isOut: isOut,
                    onPlaySquareWithQueue: playbackThread != null &&
                            playbackIndex != null &&
                            _dmVideoPathIsSquare(msg.videoPath!)
                        ? () {
                            VoiceService.instance
                                .playQueue(_dmPlaybackQueueFrom(
                                    playbackThread!, playbackIndex!))
                                .catchError((e) {
                              debugPrint('[Voice] playQueue sq error: $e');
                            });
                          }
                        : null,
                    onLongPressSaveToGallery: onLongPressSaveVideoToGallery ==
                                null ||
                            !File(msg.videoPath!).existsSync()
                        ? null
                        : () => onLongPressSaveVideoToGallery!(msg.videoPath!),
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
                          onTap: () {
                            if (isSticker &&
                                !msg.isOutgoing &&
                                onStickerTapFromPeer != null) {
                              unawaited(onStickerTapFromPeer!(msg.peerId));
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _FullScreenImageViewer(
                                  imagePath: msg.imagePath!,
                                  onSaveToGallery: onDownloadImage == null
                                      ? null
                                      : () async {
                                          await (onDownloadImage!(
                                              msg.imagePath!) as Future<void>);
                                        },
                                ),
                              ),
                            );
                          },
                          onLongPress: onLongPressSaveImageToGallery == null ||
                                  !File(msg.imagePath!).existsSync()
                              ? null
                              : () {
                                  HapticFeedback.mediumImpact();
                                  onLongPressSaveImageToGallery!(
                                      msg.imagePath!);
                                },
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(isSticker ? 10 : 12),
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
                                  icon: const Icon(Icons.download,
                                      color: Colors.white),
                                  onPressed: () =>
                                      onDownloadImage?.call(msg.imagePath!),
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
                      onAudioQueueFromHere:
                          playbackThread != null && playbackIndex != null
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
                    crossAxisAlignment: isOut
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
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
              else if (msg.stickerPackPayload != null)
                StickerPackCardBubble(
                  payload: msg.stickerPackPayload!,
                  isOutgoing: isOut,
                  colorScheme: cs,
                  sourcePeerId: msg.isOutgoing ? null : msg.peerId,
                  sourcePeerLabel: msg.isOutgoing
                      ? null
                      : () {
                          for (final c in ChatStorageService
                              .instance.contactsNotifier.value) {
                            if (c.publicKeyHex == msg.peerId) {
                              return c.nickname;
                            }
                          }
                          return null;
                        }(),
                )
              else if (inviteMap != null && inviteMap['kind'] == 'emoji_pack')
                EmojiPackCardBubble(
                  data: inviteMap,
                  isOutgoing: isOut,
                )
              else if (inviteMap != null)
                Column(
                  crossAxisAlignment:
                      isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      inviteMap['kind'] == 'device_link'
                          ? 'Запрос на связку устройств'
                          : msg.text,
                      style: TextStyle(
                        color: isOut ? cs.onPrimary : cs.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _DmInviteBubbleActions(
                      data: {
                        ...inviteMap,
                        'inviteMessageId': msg.id,
                      },
                      isOut: isOut,
                      cs: cs,
                    ),
                  ],
                )
              else if (plainText.isNotEmpty &&
                  msg.voicePath == null &&
                  !(missing && isSyntheticMediaCaption(plainText)))
                ValueListenableBuilder<List<Contact>>(
                  valueListenable: ChatStorageService.instance.contactsNotifier,
                  builder: (_, contacts, __) {
                    return RichMessageText(
                      text: plainText,
                      textColor: isOut ? cs.onPrimary : cs.onSurface,
                      isOut: isOut,
                      mentionLabelFor: (hex) => resolveChannelMentionDisplay(
                        hex,
                        contacts,
                        ProfileService.instance.profile,
                      ),
                      onMentionTap: (hex) => openDmFromMentionKey(context, hex),
                      onSlashCommandTap:
                          highlightSlashCommands ? onSlashCommandTap : null,
                      onCustomEmojiTap: onCustomEmojiTap == null
                          ? null
                          : (shortcode) => unawaited(
                                onCustomEmojiTap!(shortcode, msg.peerId),
                              ),
                    );
                  },
                ),
              if (slashButtons.isNotEmpty && onSlashCommandTap != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final btn in slashButtons)
                      InkWell(
                        key: ValueKey('msg_btn_${btn.$2}_${btn.$1}'),
                        onTap: () => onSlashCommandTap!(btn.$2),
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isOut
                                ? cs.onPrimary.withValues(alpha: 0.15)
                                : cs.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isOut
                                  ? cs.onPrimary.withValues(alpha: 0.3)
                                  : cs.primary.withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            btn.$1,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isOut ? cs.onPrimary : cs.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (msg.latitude != null && msg.longitude != null)
                _LocationChip(
                  lat: msg.latitude!,
                  lng: msg.longitude!,
                  isOut: isOut,
                ),
              if (msg.reactions.isNotEmpty)
                _ReactionsWidget(
                    reactions: msg.reactions, isOut: isOut, cs: cs),
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
                  if (isOut &&
                      msg.status == MessageStatus.failed &&
                      onRetryFailed != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Повторить отправку',
                      child: Material(
                        color: Colors.red,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => onRetryFailed!(msg),
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(
                              Icons.refresh_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ] else if (isOut &&
                      AppSettings.instance.showReadReceipts) ...[
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
            child:
                CircularProgressIndicator(strokeWidth: 1.5, color: dimColor));
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
            builder: (_, scale, child) =>
                Transform.scale(scale: scale, child: child),
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
              child: ReactionKeyGlyph(
                reactionKey: e.key,
                size: 18,
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
                          : Colors.white.withValues(alpha: 0.08),
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
                        Icon(
                          Icons.location_on,
                          size: 14,
                          color: isOut ? Colors.white : incomingColor,
                        ),
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

// ── Поле ввода ───────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final bool isRecording;
  final bool isVoiceRecordingMode;
  final bool voiceControlsEnabled;
  final bool recordingPaused;
  final bool isHoldVideoStarting;
  final ValueNotifier<double> recordingSecondsNotifier;
  final ValueNotifier<List<double>> recordingWaveformNotifier;
  final String? hintText;

  /// Чат с ИИ: только текст (без медиа и вложений).
  final bool aiTextOnlyComposer;
  final bool allowMediaRecord;
  final bool locationActive;
  final VoidCallback onSend;
  final VoidCallback? onLongPressSend;
  final VoidCallback? onPickTodo;
  final VoidCallback? onPickCalendar;
  final VoidCallback onOpenMediaGallery;
  final VoidCallback? onOpenEmojiInsert;
  final VoidCallback? onOpenStickerPicker;
  final VoidCallback onPickSquareVideo;
  final VoidCallback onPickFile;
  final VoidCallback onVoiceHoldStart;
  final Future<void> Function() onVideoHoldStart;
  final Future<void> Function() onHoldReleaseSend;
  final Future<void> Function() onHoldCancelDiscard;
  final Future<void> Function() onVoicePause;
  final Future<void> Function() onVoiceResume;
  final Future<void> Function() onVoiceTrimLastPart;
  final VoidCallback onLocation;
  final ValueListenable<bool> holdVideoPausedListenable;
  final void Function(bool locked) onHoldRecordingLockChanged;
  final Future<void> Function() onHoldVideoLockedPauseToggle;

  const _InputBar({
    required this.controller,
    required this.isSending,
    required this.isRecording,
    required this.isVoiceRecordingMode,
    required this.voiceControlsEnabled,
    required this.recordingPaused,
    required this.isHoldVideoStarting,
    required this.recordingSecondsNotifier,
    required this.recordingWaveformNotifier,
    this.hintText,
    this.aiTextOnlyComposer = false,
    this.allowMediaRecord = true,
    required this.locationActive,
    required this.onSend,
    this.onLongPressSend,
    this.onPickTodo,
    this.onPickCalendar,
    required this.onOpenMediaGallery,
    this.onOpenEmojiInsert,
    this.onOpenStickerPicker,
    required this.onPickSquareVideo,
    required this.onPickFile,
    required this.onVoiceHoldStart,
    required this.onVideoHoldStart,
    required this.onHoldReleaseSend,
    required this.onHoldCancelDiscard,
    required this.onVoicePause,
    required this.onVoiceResume,
    required this.onVoiceTrimLastPart,
    required this.onLocation,
    required this.holdVideoPausedListenable,
    required this.onHoldRecordingLockChanged,
    required this.onHoldVideoLockedPauseToggle,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final _focusNode = FocusNode();
  late final VoidCallback _controllerListener;

  /// Панель B/I/S… не перекрывает поле — открывается кнопкой при выделении.
  bool _showFormatStrip = false;

  void _onAppSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onAppSettingsChanged);
    _controllerListener = () {
      if (mounted) {
        setState(() {
          final sel = widget.controller.selection;
          if (!sel.isValid || sel.isCollapsed) {
            _showFormatStrip = false;
          }
        });
      }
    };
    widget.controller.addListener(_controllerListener);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    widget.controller.removeListener(_controllerListener);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerListener);
      widget.controller.addListener(_controllerListener);
      final sel = widget.controller.selection;
      if (!sel.isValid || sel.isCollapsed) {
        _showFormatStrip = false;
      }
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

  Future<void> _openEmojiOrStickerPicker() async {
    if (widget.isSending) return;
    final openEmoji = widget.onOpenEmojiInsert;
    final openSticker = widget.onOpenStickerPicker;
    if (openEmoji != null && openSticker != null) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.mood_rounded),
                title: const Text('Эмодзи'),
                onTap: () => Navigator.pop(ctx, 'emoji'),
              ),
              ListTile(
                leading: const Icon(Icons.emoji_emotions_outlined),
                title: const Text('Стикеры'),
                onTap: () => Navigator.pop(ctx, 'sticker'),
              ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (choice == 'emoji') {
        openEmoji();
      } else if (choice == 'sticker') {
        openSticker();
      }
      return;
    }
    if (openEmoji != null) {
      openEmoji();
      return;
    }
    if (openSticker != null) {
      openSticker();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.trim().isNotEmpty;

    final cs = Theme.of(context).colorScheme;
    final sel = widget.controller.selection;
    final hasSelection = sel.isValid && sel.baseOffset != sel.extentOffset;
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
            if (hasSelection && _showFormatStrip)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    _FmtBtn(
                        label: 'B',
                        bold: true,
                        onTap: () => _wrapSelection('**', '**')),
                    _FmtBtn(
                        label: 'I',
                        italic: true,
                        onTap: () => _wrapSelection('_', '_')),
                    _FmtBtn(
                        label: 'S',
                        strikethrough: true,
                        onTap: () => _wrapSelection('~~', '~~')),
                    _FmtBtn(
                        label: 'U',
                        underline: true,
                        onTap: () => _wrapSelection('__', '__')),
                    _FmtBtn(
                        label: '||', onTap: () => _wrapSelection('||', '||')),
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
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: _showFormatStrip
                      ? 'Скрыть формат'
                      : 'Формат выделенного текста',
                ),
              if (!widget.aiTextOnlyComposer) ...[
                if (widget.onOpenEmojiInsert != null ||
                    widget.onOpenStickerPicker != null)
                  IconButton(
                    onPressed:
                        widget.isSending ? null : _openEmojiOrStickerPicker,
                    icon: Icon(
                      Icons.emoji_emotions_outlined,
                      color: widget.isSending
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
                  onPressed:
                      widget.isSending ? null : widget.onOpenMediaGallery,
                  icon: Icon(Icons.photo_library_outlined,
                      color: widget.isSending
                          ? cs.onSurface.withValues(alpha: 0.3)
                          : cs.onSurfaceVariant,
                      size: 24),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'Галерея и вложения',
                ),
                const SizedBox(width: 2),
              ],
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: widget.isVoiceRecordingMode
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: widget.voiceControlsEnabled
                                    ? (widget.recordingPaused
                                        ? () =>
                                            unawaited(widget.onVoiceResume())
                                        : () =>
                                            unawaited(widget.onVoicePause()))
                                    : null,
                                child: Icon(
                                  widget.recordingPaused
                                      ? Icons.play_circle_fill_rounded
                                      : Icons.pause_circle_filled_rounded,
                                  color: widget.voiceControlsEnabled
                                      ? cs.primary
                                      : cs.onSurfaceVariant
                                          .withValues(alpha: 0.45),
                                  size: 30,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ValueListenableBuilder<List<double>>(
                                  valueListenable:
                                      widget.recordingWaveformNotifier,
                                  builder: (_, bars, __) {
                                    return SizedBox(
                                      height: 36,
                                      child: CustomPaint(
                                        painter: _LiveRecordingWaveformPainter(
                                          bars: bars,
                                          color: cs.primary,
                                          paused: widget.recordingPaused,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              ValueListenableBuilder<double>(
                                valueListenable:
                                    widget.recordingSecondsNotifier,
                                builder: (_, secs, __) {
                                  final mm =
                                      (secs ~/ 60).toString().padLeft(2, '0');
                                  final ss = (secs.floor() % 60)
                                      .toString()
                                      .padLeft(2, '0');
                                  return Text(
                                    '$mm:$ss',
                                    style: TextStyle(
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                      fontWeight: FontWeight.w700,
                                      color: cs.onSurface,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: widget.voiceControlsEnabled &&
                                        widget.recordingPaused
                                    ? () => unawaited(
                                          widget.onVoiceTrimLastPart(),
                                        )
                                    : null,
                                child: Icon(
                                  Icons.content_cut_rounded,
                                  color: widget.recordingPaused
                                      ? cs.secondary
                                      : cs.onSurfaceVariant
                                          .withValues(alpha: 0.4),
                                  size: 22,
                                ),
                              ),
                              if (!widget.voiceControlsEnabled) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.lock_outline_rounded,
                                  size: 16,
                                  color: cs.onSurfaceVariant
                                      .withValues(alpha: 0.55),
                                ),
                              ],
                            ],
                          ),
                        )
                      : ValueListenableBuilder<double>(
                          valueListenable: widget.recordingSecondsNotifier,
                          builder: (_, secs, __) {
                            final s = secs.floor();
                            final t = ((secs % 1) * 10).floor();
                            final sendOnEnter =
                                AppSettings.instance.sendOnEnter;
                            final hasShortcode =
                                widget.controller.text.contains(':');
                            final textStyle = TextStyle(
                              fontSize: 15,
                              color: hasShortcode
                                  ? Colors.transparent
                                  : cs.onSurface,
                            );
                            return Stack(
                              children: [
                                TextField(
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
                                          if (!widget.isSending &&
                                              !widget.isRecording) {
                                            widget.onSend();
                                          }
                                        }
                                      : null,
                                  style: textStyle,
                                  decoration: InputDecoration(
                                    hintText: widget.isRecording
                                        ? 'Запись... ${s}s.$t'
                                        : (widget.hintText ?? 'Сообщение...'),
                                    hintStyle: TextStyle(
                                        color: cs.onSurfaceVariant
                                            .withValues(alpha: 0.6)),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 10),
                                  ),
                                ),
                                if (hasShortcode)
                                  IgnorePointer(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 10),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: CustomEmojiInlineText(
                                          text: widget.controller.text,
                                          maxLines: sendOnEnter ? 1 : 4,
                                          overflow: TextOverflow.clip,
                                          style: TextStyle(
                                            fontSize: 15,
                                            color: cs.onSurface,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(width: 8),
              if (!widget.aiTextOnlyComposer && widget.allowMediaRecord) ...[
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
                  onTap: widget.isSending || widget.isRecording
                      ? null
                      : widget.onSend,
                  onLongPress: (widget.onLongPressSend == null ||
                          !hasText ||
                          widget.isSending ||
                          widget.isRecording)
                      ? null
                      : widget.onLongPressSend,
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
    '.mp3',
    '.ogg',
    '.wav',
    '.m4a',
    '.aac',
    '.flac',
    '.opus',
    '.wma',
    '.mp4a',
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

  Future<void> _open(BuildContext context) async {
    if (!File(filePath).existsSync()) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DocumentPreviewScreen(
          filePath: filePath,
          fileName: fileName,
        ),
      ),
    );
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
    final subColor =
        isOut ? cs.onPrimary.withValues(alpha: 0.65) : cs.onSurfaceVariant;
    final bgColor =
        isOut ? Colors.black.withValues(alpha: 0.15) : cs.surfaceContainerHigh;

    return GestureDetector(
      onTap: () => _open(context),
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

class _DocumentPreviewScreen extends StatefulWidget {
  final String filePath;
  final String fileName;

  const _DocumentPreviewScreen({
    required this.filePath,
    required this.fileName,
  });

  @override
  State<_DocumentPreviewScreen> createState() => _DocumentPreviewScreenState();
}

class _DocumentPreviewScreenState extends State<_DocumentPreviewScreen> {
  late final String _ext = p.extension(widget.fileName).toLowerCase();

  static const _textExts = {
    '.txt',
    '.md',
    '.json',
    '.yaml',
    '.yml',
    '.xml',
    '.csv',
    '.log',
    '.ini',
    '.html',
    '.htm',
    '.dart',
    '.js',
    '.ts',
    '.py',
    '.java',
    '.kt',
    '.swift',
    '.sql',
    '.sh',
    '.ps1',
  };

  bool get _isPdf => _ext == '.pdf';
  bool get _isText => _textExts.contains(_ext);
  bool get _isDocx => _ext == '.docx';
  bool get _isPptx => _ext == '.pptx';
  bool get _isXlsx => _ext == '.xlsx';

  Future<String> _readTextFile() async {
    final bytes = await File(widget.filePath).readAsBytes();
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  String _stripXml(String raw) {
    var s = raw
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  Future<String> _readDocxText() async {
    final bytes = await File(widget.filePath).readAsBytes();
    final z = ZipDecoder().decodeBytes(bytes, verify: false);
    final doc = z.findFile('word/document.xml');
    if (doc == null) return 'Не удалось прочитать содержимое DOCX.';
    final txt = utf8.decode(doc.content as List<int>, allowMalformed: true);
    final clean = _stripXml(txt);
    return clean.isEmpty ? 'Документ пуст.' : clean;
  }

  Future<String> _readPptxText() async {
    final bytes = await File(widget.filePath).readAsBytes();
    final z = ZipDecoder().decodeBytes(bytes, verify: false);
    final slides = z.files
        .where((f) => f.name.startsWith('ppt/slides/slide'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (slides.isEmpty) return 'Слайды не найдены.';
    final out = <String>[];
    for (var i = 0; i < slides.length; i++) {
      final xml =
          utf8.decode(slides[i].content as List<int>, allowMalformed: true);
      final clean = _stripXml(xml);
      if (clean.isNotEmpty) {
        out.add('Слайд ${i + 1}\n$clean');
      }
    }
    return out.isEmpty
        ? 'Текст на слайдах не найден.'
        : out.join('\n\n----------------\n\n');
  }

  Future<String> _readXlsxText() async {
    final bytes = await File(widget.filePath).readAsBytes();
    final z = ZipDecoder().decodeBytes(bytes, verify: false);
    final shared = z.findFile('xl/sharedStrings.xml');
    if (shared == null)
      return 'Предпросмотр XLSX: текстовые ячейки не найдены.';
    final xml = utf8.decode(shared.content as List<int>, allowMalformed: true);
    final matches = RegExp(r'<t[^>]*>([\s\S]*?)</t>').allMatches(xml);
    final values = <String>[];
    for (final m in matches) {
      final t = _stripXml(m.group(1) ?? '');
      if (t.isNotEmpty) values.add(t);
    }
    if (values.isEmpty) {
      return 'Предпросмотр XLSX: текстовые ячейки не найдены.';
    }
    return values.take(500).join('\n');
  }

  Future<void> _openExternal() async {
    try {
      await launchUrl(
        Uri.file(widget.filePath),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  Widget _textPreview(Future<String> Function() loader) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<String>(
      future: loader(),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final txt = (snap.data ?? '').trim();
        if (txt.isEmpty) {
          return Center(
            child: Text(
              'Нечего показать',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          );
        }
        return SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              txt,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget body;
    if (_isPdf) {
      body = SfPdfViewer.file(File(widget.filePath));
    } else if (_isText) {
      body = _textPreview(_readTextFile);
    } else if (_isDocx) {
      body = _textPreview(_readDocxText);
    } else if (_isPptx) {
      body = _textPreview(_readPptxText);
    } else if (_isXlsx) {
      body = _textPreview(_readXlsxText);
    } else {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                size: 48,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'Встроенный просмотр для этого типа пока не поддерживается.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _openExternal,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Открыть во внешнем приложении'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Открыть во внешнем приложении',
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: body,
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
    final subColor =
        isOut ? cs.onPrimary.withValues(alpha: 0.65) : cs.onSurfaceVariant;

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
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
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
  final VoidCallback? onTranscribeTap;
  final bool isTranscribing;
  final bool hasTranscript;
  final String? transcript;
  final bool transcriptExpanded;
  final ValueChanged<bool>? onTranscriptExpandedChanged;

  const _VoiceMessageBubble({
    required this.voicePath,
    required this.isOut,
    this.onPlayWithQueue,
    this.onTranscribeTap,
    this.isTranscribing = false,
    this.hasTranscript = false,
    this.transcript,
    this.transcriptExpanded = false,
    this.onTranscriptExpandedChanged,
  });

  static String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = isOut ? cs.onPrimary : cs.onSurface;
    final activeColor = isOut ? cs.onPrimary : cs.primary;
    final inactiveColor =
        (isOut ? cs.onPrimary : cs.onSurface).withValues(alpha: 0.30);
    final timeColor =
        (isOut ? cs.onPrimary : cs.onSurface).withValues(alpha: 0.55);

    return ValueListenableBuilder<String?>(
      valueListenable: VoiceService.instance.currentlyPlaying,
      builder: (_, playing, __) {
        final isPlaying = playing == voicePath;
        final transcriptTrim = transcript?.trim();
        final hasText = transcriptTrim != null && transcriptTrim.isNotEmpty;
        final subLabel =
            (isOut ? cs.onPrimary : cs.onSurface).withValues(alpha: 0.65);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Play / Pause button — IconButton handles tap reliably across platforms.
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  splashRadius: 22,
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
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: iconColor,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 4),
                // Waveform + duration (read-only, no seek to keep iOS/Mac stable).
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: VoiceService.instance.playProgress,
                      builder: (_, progress, __) {
                        final p = isPlaying
                            ? (progress.isFinite
                                ? progress.clamp(0.0, 1.0)
                                : 0.0)
                            : 0.0;
                        return SizedBox(
                          width: 120,
                          height: 28,
                          child: CustomPaint(
                            painter: _WaveformPainter(
                              seed: voicePath.hashCode,
                              progress: p,
                              activeColor: activeColor,
                              inactiveColor: inactiveColor,
                            ),
                          ),
                        );
                      },
                    ),
                    if (isPlaying)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: ValueListenableBuilder<Duration>(
                          valueListenable: VoiceService.instance.playDuration,
                          builder: (_, dur, __) {
                            if (dur.inMilliseconds <= 0) {
                              return Text('0:00',
                                  style: TextStyle(
                                      fontSize: 10, color: timeColor));
                            }
                            return ValueListenableBuilder<double>(
                              valueListenable:
                                  VoiceService.instance.playProgress,
                              builder: (_, progress, __) {
                                final p = progress.isFinite
                                    ? progress.clamp(0.0, 1.0)
                                    : 0.0;
                                final elapsed = Duration(
                                    milliseconds:
                                        (p * dur.inMilliseconds).round());
                                return Text(
                                  '${_fmtDur(elapsed)} / ${_fmtDur(dur)}',
                                  style:
                                      TextStyle(fontSize: 10, color: timeColor),
                                );
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onTranscribeTap,
                  child: isTranscribing
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: (isOut ? cs.onPrimary : cs.onSurface)
                                .withValues(alpha: 0.8),
                          ),
                        )
                      : Icon(
                          hasTranscript
                              ? Icons.subtitles_rounded
                              : Icons.subtitles_outlined,
                          size: 20,
                          color: (isOut ? cs.onPrimary : cs.onSurface)
                              .withValues(alpha: 0.7),
                        ),
                ),
              ],
            ),
            if (hasText && onTranscriptExpandedChanged != null) ...[
              const SizedBox(height: 4),
              InkWell(
                onTap: () => onTranscriptExpandedChanged!(!transcriptExpanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        transcriptExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: subLabel,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        'Расшифровка',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: subLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (transcriptExpanded)
                Padding(
                  padding: const EdgeInsets.only(left: 2, top: 2, right: 4),
                  child: SelectionArea(
                    child: Text(
                      transcriptTrim,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: isOut ? cs.onPrimary : cs.onSurface,
                      ),
                    ),
                  ),
                ),
            ],
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

class _LiveRecordingWaveformPainter extends CustomPainter {
  final List<double> bars;
  final Color color;
  final bool paused;

  const _LiveRecordingWaveformPainter({
    required this.bars,
    required this.color,
    required this.paused,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.fill
      ..color = paused ? color.withValues(alpha: 0.35) : color;
    final baseY = size.height / 2;
    final count = bars.isEmpty ? 24 : bars.length;
    const gap = 2.0;
    final barW = ((size.width - (count - 1) * gap) / count).clamp(1.0, 4.0);
    final maxH = size.height * 0.9;
    for (var i = 0; i < count; i++) {
      final amp = i < bars.length ? bars[i].clamp(0.05, 1.0) : 0.05;
      final h = (maxH * amp).clamp(2.0, maxH);
      final x = i * (barW + gap);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baseY - h / 2, barW, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(r, p);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveRecordingWaveformPainter oldDelegate) {
    return oldDelegate.bars != bars ||
        oldDelegate.color != color ||
        oldDelegate.paused != paused;
  }
}

class _VideoMessageBubble extends StatefulWidget {
  final String videoPath;
  final bool isOut;
  final VoidCallback? onPlaySquareWithQueue;
  final VoidCallback? onLongPressSaveToGallery;

  const _VideoMessageBubble({
    required this.videoPath,
    required this.isOut,
    this.onPlaySquareWithQueue,
    this.onLongPressSaveToGallery,
  });

  @override
  State<_VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends State<_VideoMessageBubble> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _playing = false;
  int _embedPauseGen = 0;

  /// Воспроизведение квадратика из очереди голосовых (без полноэкранного плеера).
  bool _queueDriveActive = false;
  bool _squareEndDispatched = false;
  int _lastSquarePausePulse = 0;
  int _lastSquareResumePulse = 0;
  ScrollPosition? _squarePipScrollPosition;

  bool get _isSquare => _ChatScreenState._videoPathIsSquare(widget.videoPath);

  bool get _squareUsesQueue =>
      _isSquare && widget.onPlaySquareWithQueue != null;

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

  void _detachSquarePipScroll() {
    _squarePipScrollPosition?.removeListener(_onScrollForSquarePipViewport);
    _squarePipScrollPosition = null;
  }

  void _attachSquarePipScrollListener() {
    if (!_squareUsesQueue) return;
    final scrollable = Scrollable.maybeOf(context);
    final pos = scrollable?.position;
    if (pos == _squarePipScrollPosition) return;
    _detachSquarePipScroll();
    _squarePipScrollPosition = pos;
    _squarePipScrollPosition?.addListener(_onScrollForSquarePipViewport);
  }

  void _onScrollForSquarePipViewport() {
    _scheduleSquareViewportReportForPip();
  }

  void _scheduleSquareViewportReportForPip() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reportSquareViewportForQueuePipNow();
    });
  }

  void _reportSquareViewportForQueuePipNow() {
    if (!_squareUsesQueue || !mounted) return;
    final cur = VoiceService.instance.currentlyPlaying.value;
    if (cur != widget.videoPath) {
      VoiceService.instance
          .reportSquareBubbleViewportCoverage(widget.videoPath, false);
      return;
    }
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) {
      VoiceService.instance
          .reportSquareBubbleViewportCoverage(widget.videoPath, false);
      return;
    }
    final topLeft = ro.localToGlobal(Offset.zero);
    final rect = topLeft & ro.size;
    final media = MediaQuery.of(context);
    final pad = media.padding;
    final view = Rect.fromLTRB(
      0,
      pad.top,
      media.size.width,
      media.size.height - pad.bottom,
    );
    final overlap = rect.overlaps(view);
    VoiceService.instance
        .reportSquareBubbleViewportCoverage(widget.videoPath, overlap);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_squareUsesQueue) {
      _attachSquarePipScrollListener();
      _scheduleSquareViewportReportForPip();
    }
  }

  @override
  void didUpdateWidget(covariant _VideoMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSq = _ChatScreenState._videoPathIsSquare(oldWidget.videoPath) &&
        oldWidget.onPlaySquareWithQueue != null;
    final newSq = _isSquare && widget.onPlaySquareWithQueue != null;
    if (oldWidget.videoPath != widget.videoPath || oldSq != newSq) {
      if (oldSq) {
        VoiceService.instance
            .reportSquareBubbleViewportCoverage(oldWidget.videoPath, false);
      }
      if (!newSq) {
        _detachSquarePipScroll();
      } else if (newSq && !oldSq) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _attachSquarePipScrollListener();
          _scheduleSquareViewportReportForPip();
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    _lastSquarePausePulse = VoiceService.instance.squareVideoUiPausePulse.value;
    _lastSquareResumePulse =
        VoiceService.instance.squareVideoUiResumePulse.value;
    VoiceService.instance.currentlyPlaying
        .addListener(_onCurrentlyPlayingChanged);
    VoiceService.instance.playbackSession
        .addListener(_onPlaybackSessionForSquareUi);
    VoiceService.instance.squareVideoUiPausePulse
        .addListener(_onSquarePausePulse);
    VoiceService.instance.squareVideoUiResumePulse
        .addListener(_onSquareResumePulse);
    if (File(widget.videoPath).existsSync()) {
      _initPlayer();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_squareUsesQueue) {
        _attachSquarePipScrollListener();
        _scheduleSquareViewportReportForPip();
      }
    });
  }

  void _onPlaybackSessionForSquareUi() {
    if (!mounted || !_squareUsesQueue) return;
    if (!VoiceService.instance.isCurrentQueueSquareAtPath(widget.videoPath)) {
      return;
    }
    if (!VoiceService.instance.hasSquareQueueVideoController) return;
    final sess = VoiceService.instance.playbackSession.value;
    final playingUi = sess != null && !sess.isPaused;
    if (_playing != playingUi) {
      setState(() => _playing = playingUi);
    }
  }

  void _onCurrentlyPlayingChanged() {
    if (!mounted || !_squareUsesQueue) {
      return;
    }
    final curAll = VoiceService.instance.currentlyPlaying.value;
    if (curAll != widget.videoPath) {
      VoiceService.instance
          .reportSquareBubbleViewportCoverage(widget.videoPath, false);
    } else {
      _scheduleSquareViewportReportForPip();
    }
    if (_ctrl == null || !_initialized) {
      return;
    }
    final cur = VoiceService.instance.currentlyPlaying.value;
    final vsOwns =
        VoiceService.instance.isCurrentQueueSquareAtPath(widget.videoPath) &&
            VoiceService.instance.hasSquareQueueVideoController;

    if (cur == widget.videoPath) {
      if (vsOwns) {
        final sess = VoiceService.instance.playbackSession.value;
        final playingUi = sess != null && !sess.isPaused;
        if (!_queueDriveActive || _playing != playingUi) {
          setState(() {
            _queueDriveActive = true;
            _playing = playingUi;
          });
        }
        return;
      }
      if (!_queueDriveActive) {
        unawaited(_syncStartQueueDrive());
      }
    } else if (_queueDriveActive) {
      _syncStopQueueDrive();
    }
  }

  Future<void> _syncStartQueueDrive() async {
    if (!mounted || _ctrl == null || !_initialized) return;
    if (_queueDriveActive) return;
    _queueDriveActive = true;
    _squareEndDispatched = false;
    try {
      _ctrl!.setLooping(false);
      await _ctrl!.seekTo(Duration.zero);
      _ctrl!.removeListener(_onSquareQueueTick);
      _ctrl!.addListener(_onSquareQueueTick);
      await _ctrl!.play();
    } catch (e) {
      debugPrint('[VideoMessage] queue drive start: $e');
    }
    if (mounted) setState(() => _playing = true);
  }

  void _syncStopQueueDrive() {
    if (!_queueDriveActive) return;
    _queueDriveActive = false;
    _squareEndDispatched = false;
    if (_ctrl != null) {
      try {
        _ctrl!.removeListener(_onSquareQueueTick);
      } catch (_) {}
      try {
        _ctrl!.pause();
      } catch (_) {}
      try {
        _ctrl!.setLooping(!_squareUsesQueue);
      } catch (_) {}
    }
    if (mounted) setState(() => _playing = false);
  }

  void _onSquareQueueTick() {
    if (!_queueDriveActive || _ctrl == null || !mounted) return;
    final v = _ctrl!.value;
    if (!v.isInitialized) return;
    final totalMs = v.duration.inMilliseconds;
    if (totalMs <= 0) return;
    VoiceService.instance.reportSquarePlaybackProgress(
      v.position.inMilliseconds / totalMs,
    );
    if (_squareEndDispatched) return;
    if (v.position.inMilliseconds >= totalMs - 80) {
      _squareEndDispatched = true;
      unawaited(
        VoiceService.instance.onSquareVideoPlaybackEnded(widget.videoPath),
      );
    }
  }

  void _onSquarePausePulse() {
    if (!mounted) return;
    final g = VoiceService.instance.squareVideoUiPausePulse.value;
    if (g == _lastSquarePausePulse) return;
    _lastSquarePausePulse = g;
    if (!_squareUsesQueue) return;
    if (VoiceService.instance.currentlyPlaying.value != widget.videoPath) {
      return;
    }
    if (VoiceService.instance.hasSquareQueueVideoController &&
        VoiceService.instance.isCurrentQueueSquareAtPath(widget.videoPath)) {
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (_ctrl == null) return;
    try {
      _ctrl!.pause();
    } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  void _onSquareResumePulse() {
    if (!mounted) return;
    final g = VoiceService.instance.squareVideoUiResumePulse.value;
    if (g == _lastSquareResumePulse) return;
    _lastSquareResumePulse = g;
    if (!_squareUsesQueue) return;
    if (VoiceService.instance.currentlyPlaying.value != widget.videoPath) {
      return;
    }
    if (VoiceService.instance.hasSquareQueueVideoController &&
        VoiceService.instance.isCurrentQueueSquareAtPath(widget.videoPath)) {
      if (mounted) setState(() => _playing = true);
      return;
    }
    if (_ctrl == null || !_initialized) return;
    try {
      _ctrl!.play();
    } catch (_) {}
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _initPlayer() async {
    final ctrl = VideoPlayerController.file(File(widget.videoPath));
    try {
      await ctrl.initialize();
      if (_isSquare) {
        ctrl.setLooping(!_squareUsesQueue);
      } else {
        // Seek to first frame so it shows as a thumbnail; don't auto-play.
        await ctrl.seekTo(Duration.zero);
      }
      if (mounted) {
        setState(() {
          _ctrl = ctrl;
          _initialized = true;
        });
        _onCurrentlyPlayingChanged();
        if (_squareUsesQueue) {
          _scheduleSquareViewportReportForPip();
        }
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
    _detachSquarePipScroll();
    if (_squareUsesQueue) {
      VoiceService.instance
          .reportSquareBubbleViewportCoverage(widget.videoPath, false);
    }
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    VoiceService.instance.currentlyPlaying
        .removeListener(_onCurrentlyPlayingChanged);
    VoiceService.instance.playbackSession
        .removeListener(_onPlaybackSessionForSquareUi);
    VoiceService.instance.squareVideoUiPausePulse
        .removeListener(_onSquarePausePulse);
    VoiceService.instance.squareVideoUiResumePulse
        .removeListener(_onSquareResumePulse);
    if (_queueDriveActive && _ctrl != null) {
      try {
        _ctrl!.removeListener(_onSquareQueueTick);
      } catch (_) {}
    }
    _ctrl?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_ctrl == null || !_initialized) return;
    if (_playing) {
      _ctrl!.pause();
      setState(() => _playing = false);
      if (_queueDriveActive &&
          VoiceService.instance.currentlyPlaying.value == widget.videoPath) {
        unawaited(VoiceService.instance.pausePlayback());
      }
      return;
    }
    if (widget.onPlaySquareWithQueue != null) {
      final cur = VoiceService.instance.currentlyPlaying.value;
      if (cur == widget.videoPath && _queueDriveActive) {
        unawaited(VoiceService.instance.resumePlayback());
        return;
      }
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

  static String _fmtVideoDur(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildCircle() {
    final exists = File(widget.videoPath).existsSync();
    final ctrl = _ctrl;

    return GestureDetector(
      onTap: exists ? _togglePlay : null,
      onLongPress: exists && widget.onLongPressSaveToGallery != null
          ? () {
              HapticFeedback.mediumImpact();
              widget.onLongPressSaveToGallery!();
            }
          : null,
      child: SizedBox(
        width: 160,
        height: 160,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _initialized && ctrl != null
                  ? VideoPlayer(ctrl)
                  : Container(
                      color: const Color(0xFF1A1A1A),
                      child: exists
                          ? const Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white54),
                              ),
                            )
                          : const Center(
                              child: Text('Файл не найден',
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 11),
                                  textAlign: TextAlign.center),
                            ),
                    ),
              if (exists && !_playing)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_circle_fill,
                            color: Colors.white, size: 52),
                        if (_initialized &&
                            ctrl != null &&
                            ctrl.value.duration.inSeconds > 0) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _fmtVideoDur(ctrl.value.duration),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              if (_playing && _initialized && ctrl != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Center(
                      child: ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: ctrl,
                        builder: (_, v, __) {
                          if (v.duration.inMilliseconds <= 0) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${_fmtVideoDur(v.position)} / ${_fmtVideoDur(v.duration)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        },
                      ),
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
                  builder: (_) => DmVideoFullscreenPage(path: widget.videoPath),
                ),
              )
          : null,
      onLongPress: exists && widget.onLongPressSaveToGallery != null
          ? () {
              HapticFeedback.mediumImpact();
              widget.onLongPressSaveToGallery!();
            }
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

enum _DmMaterialKind {
  squareVideo,
  voice,
  video,
  photo,
  file,
  link,
  phone,
  code,
}

class _DmMaterialEntry {
  final _DmMaterialKind kind;
  final ChatMessage message;
  final DateTime timestamp;
  final String title;
  final String? subtitle;
  final String? mediaPath;
  final String? payload;

  const _DmMaterialEntry({
    required this.kind,
    required this.message,
    required this.timestamp,
    required this.title,
    this.subtitle,
    this.mediaPath,
    this.payload,
  });
}

class _PeerProfileScreen extends StatefulWidget {
  final String peerId;
  // Initial values from widget params (used while DB loads)
  final String nickname;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;
  final String? bannerImagePath;

  const _PeerProfileScreen({
    required this.peerId,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    this.bannerImagePath,
  });

  @override
  State<_PeerProfileScreen> createState() => _PeerProfileScreenState();
}

class _PeerProfileScreenState extends State<_PeerProfileScreen> {
  List<_DmMaterialEntry> _materials = [];
  _DmMaterialKind _selectedKind = _DmMaterialKind.photo;
  int _dateFilterDays = 0; // 0 = all time
  String _fileTypeFilter = 'all';

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
  bool _isOwnedRelayBot = false;
  Map<String, dynamic>? _ownedRelayBotRow;

  @override
  void initState() {
    super.initState();
    _loadAll();
    // Реактивно подхватываем обновления контакта (аватар, баннер, ник, теги),
    // которые прилетают по BLE/relay пока экран открыт.
    ChatStorageService.instance.contactsNotifier
        .addListener(_onContactsChanged);
  }

  @override
  void dispose() {
    ChatStorageService.instance.contactsNotifier
        .removeListener(_onContactsChanged);
    _musicPlayer?.dispose();
    super.dispose();
  }

  void _onContactsChanged() {
    if (!mounted) return;
    final contacts = ChatStorageService.instance.contactsNotifier.value;
    Contact? c;
    for (final x in contacts) {
      if (x.publicKeyHex == widget.peerId) {
        c = x;
        break;
      }
    }
    if (c == null) return;
    final newAvatar =
        ImageService.instance.resolveStoredPath(c.avatarImagePath);
    final newBanner =
        ImageService.instance.resolveStoredPath(c.bannerImagePath);
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
    final msgs = await ChatStorageService.instance
        .getMessages(widget.peerId, limit: 1000);
    if (!mounted) return;
    setState(() {
      if (contact != null) {
        _nick = contact.nickname;
        _username = contact.username.isEmpty ? null : contact.username;
        _color = contact.avatarColor;
        _emoji = contact.avatarEmoji;
        _avatarPath =
            ImageService.instance.resolveStoredPath(contact.avatarImagePath);
        _bannerPath =
            ImageService.instance.resolveStoredPath(contact.bannerImagePath);
        _musicPath =
            ImageService.instance.resolveStoredPath(contact.profileMusicPath);
        _tags = contact.tags;
      } else {
        _musicPath = null;
        _avatarPath =
            ImageService.instance.resolveStoredPath(widget.avatarImagePath);
        _bannerPath =
            ImageService.instance.resolveStoredPath(widget.bannerImagePath);
      }
      _materials = _collectMaterials(msgs);
    });
    unawaited(_refreshOwnedRelayBotState());
  }

  List<_DmMaterialEntry> _collectMaterials(List<ChatMessage> msgs) {
    final out = <_DmMaterialEntry>[];
    final linkRx = RegExp(r'https?://\S+');
    final fenceRx = RegExp(r'```([^\n`]*)\r?\n?([\s\S]*?)```');
    final inlineCodeRx = RegExp(r'`([^`\n]+)`');

    for (final m in msgs) {
      final ts = m.timestamp;
      final imagePath = _dmResolveMsgPath(m.imagePath);
      final voicePath = _dmResolveMsgPath(m.voicePath);
      final videoPath = _dmResolveMsgPath(m.videoPath);
      final filePath = _dmResolveMsgPath(m.filePath);

      if (imagePath != null) {
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.photo,
          message: m,
          timestamp: ts,
          title: 'Фото',
          subtitle: m.text.trim().isEmpty ? null : m.text.trim(),
          mediaPath: imagePath,
        ));
      }
      if (voicePath != null) {
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.voice,
          message: m,
          timestamp: ts,
          title: 'Голосовое',
          subtitle: m.text.trim().isEmpty ? null : m.text.trim(),
          mediaPath: voicePath,
        ));
      }
      if (videoPath != null) {
        out.add(_DmMaterialEntry(
          kind: _dmVideoPathIsSquare(videoPath)
              ? _DmMaterialKind.squareVideo
              : _DmMaterialKind.video,
          message: m,
          timestamp: ts,
          title: _dmVideoPathIsSquare(videoPath) ? 'Квадратик' : 'Видео',
          subtitle: m.text.trim().isEmpty ? null : m.text.trim(),
          mediaPath: videoPath,
        ));
      }
      if (filePath != null) {
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.file,
          message: m,
          timestamp: ts,
          title: m.fileName?.trim().isNotEmpty == true
              ? m.fileName!.trim()
              : 'Файл',
          subtitle: m.text.trim().isEmpty ? null : m.text.trim(),
          mediaPath: filePath,
        ));
      }

      final text = m.text;
      if (text.trim().isEmpty) continue;

      for (final lm in linkRx.allMatches(text)) {
        final url = lm.group(0)!;
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.link,
          message: m,
          timestamp: ts,
          title: url,
          payload: url,
        ));
      }

      for (final pm in _collectPhoneMatches(text)) {
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.phone,
          message: m,
          timestamp: ts,
          title: pm,
          payload: pm,
        ));
      }

      for (final cm in fenceRx.allMatches(text)) {
        final raw = (cm.group(2) ?? '').trim();
        if (raw.isEmpty) continue;
        final preview = raw.split('\n').first.trim();
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.code,
          message: m,
          timestamp: ts,
          title: preview.isEmpty ? 'Код' : preview,
          payload: raw,
        ));
      }
      for (final cm in inlineCodeRx.allMatches(text)) {
        final raw = (cm.group(1) ?? '').trim();
        if (raw.isEmpty) continue;
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.code,
          message: m,
          timestamp: ts,
          title: raw,
          payload: raw,
        ));
      }
      for (final rawLine in text.split('\n')) {
        final line = rawLine.trim();
        if (!_looksLikeCodeLine(line)) continue;
        out.add(_DmMaterialEntry(
          kind: _DmMaterialKind.code,
          message: m,
          timestamp: ts,
          title: line,
          payload: line,
        ));
      }
    }

    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  List<String> _collectPhoneMatches(String text) {
    final out = <String>[];
    final phoneRx = RegExp(r'(?<!\S)\+[\d\s\-\(\).]+');
    for (final m in phoneRx.allMatches(text)) {
      final raw = (m.group(0) ?? '').trim();
      final digits = raw.replaceAll(RegExp(r'\D'), '');
      if (digits.length < 10 || digits.length > 15) continue;
      out.add(raw);
    }
    return out;
  }

  bool _looksLikeCodeLine(String line) {
    if (line.isEmpty) return false;
    if (line.startsWith(r'$ ') ||
        line.startsWith('PS ') ||
        line.contains('|')) {
      return true;
    }
    if (line.startsWith('python ') ||
        line.startsWith('flutter ') ||
        line.startsWith('dart ') ||
        line.startsWith('npm ') ||
        line.startsWith('git ') ||
        line.startsWith('curl ') ||
        line.startsWith('Get-') ||
        line.startsWith('Set-') ||
        line.startsWith('New-')) {
      return true;
    }
    return false;
  }

  bool _peerProfileBannerVisible(String? p) {
    if (p == null || p.isEmpty) return false;
    if (p.startsWith('http://') || p.startsWith('https://')) return true;
    if (kIsWeb) return false;
    return File(p).existsSync();
  }

  Widget _peerProfileBannerBackground(int color) {
    final p = _bannerPath;
    if (!_peerProfileBannerVisible(p)) return _bannerFallback(color);
    Widget image;
    if (p!.startsWith('http://') || p.startsWith('https://')) {
      image = Image.network(
        p,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _bannerFallback(color),
      );
    } else {
      image = Image.file(
        File(p),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _bannerFallback(color),
      );
    }
    return Container(
      color: Color(color).withValues(alpha: 0.2),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: image,
          ),
        ),
      ),
    );
  }

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
    if (action == 'edit_bot_profile') {
      await _showEditOwnedBotProfileDialog();
      return;
    }
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

  bool _looksLikeHex64(String v) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(v.trim());

  Future<void> _refreshOwnedRelayBotState() async {
    if (!_looksLikeHex64(widget.peerId)) {
      if (mounted && (_isOwnedRelayBot || _ownedRelayBotRow != null)) {
        setState(() {
          _isOwnedRelayBot = false;
          _ownedRelayBotRow = null;
        });
      }
      return;
    }
    final ack = await RelayService.instance.sendBotOwnerList();
    if (!mounted) return;
    if (ack['ok'] != true || ack['bots'] is! List) {
      setState(() {
        _isOwnedRelayBot = false;
        _ownedRelayBotRow = null;
      });
      return;
    }
    final id = widget.peerId.toLowerCase();
    Map<String, dynamic>? row;
    for (final raw in (ack['bots'] as List)) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final botId = (m['botId'] as String?)?.toLowerCase() ?? '';
      if (botId == id) {
        row = m;
        break;
      }
    }
    setState(() {
      _isOwnedRelayBot = row != null;
      _ownedRelayBotRow = row;
    });
  }

  Future<void> _showEditOwnedBotProfileDialog() async {
    if (!_isOwnedRelayBot) return;
    final row = _ownedRelayBotRow ?? <String, dynamic>{};
    final handle = (row['handle'] as String?)?.trim() ?? '';
    final nameCtrl =
        TextEditingController(text: (row['displayName'] as String?) ?? _nick);
    final descCtrl =
        TextEditingController(text: (row['description'] as String?) ?? '');
    final avatarCtrl =
        TextEditingController(text: (row['avatarUrl'] as String?) ?? '');
    final bannerCtrl =
        TextEditingController(text: (row['bannerUrl'] as String?) ?? '');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title:
              Text(handle.isEmpty ? 'Профиль бота' : 'Профиль бота @$handle'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    maxLength: 64,
                    decoration: const InputDecoration(labelText: 'Имя бота'),
                  ),
                  TextField(
                    controller: descCtrl,
                    maxLength: 512,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(labelText: 'Описание'),
                  ),
                  TextField(
                    controller: avatarCtrl,
                    decoration: const InputDecoration(
                      labelText: 'URL аватара (пусто = сброс)',
                    ),
                  ),
                  TextField(
                    controller: bannerCtrl,
                    decoration: const InputDecoration(
                      labelText: 'URL баннера (пусто = сброс)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;

      final oldName = (row['displayName'] as String?)?.trim() ?? '';
      final oldDesc = (row['description'] as String?)?.trim() ?? '';
      final oldAvatar = (row['avatarUrl'] as String?)?.trim() ?? '';
      final oldBanner = (row['bannerUrl'] as String?)?.trim() ?? '';
      final newName = nameCtrl.text.trim();
      final newDesc = descCtrl.text.trim();
      final newAvatar = avatarCtrl.text.trim();
      final newBanner = bannerCtrl.text.trim();

      final changes = <String, dynamic>{};
      if (newName != oldName && newName.isNotEmpty) {
        changes['displayName'] = newName;
      }
      if (newDesc != oldDesc) {
        changes['description'] = newDesc;
      }
      if (newAvatar != oldAvatar) {
        if (newAvatar.isEmpty) {
          changes['clearAvatar'] = true;
        } else {
          changes['avatarUrl'] = newAvatar;
        }
      }
      if (newBanner != oldBanner) {
        if (newBanner.isEmpty) {
          changes['clearBanner'] = true;
        } else {
          changes['bannerUrl'] = newBanner;
        }
      }
      if (changes.isEmpty) return;
      final ack = await RelayService.instance.sendBotOwnerPatch(
        botId: widget.peerId,
        changes: changes,
      );
      if (!mounted) return;
      if (ack['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Профиль бота обновлён')),
        );
        await _refreshOwnedRelayBotState();
        await _loadAll();
      } else {
        final err = ack['error']?.toString() ?? 'unknown';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось обновить: $err'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      nameCtrl.dispose();
      descCtrl.dispose();
      avatarCtrl.dispose();
      bannerCtrl.dispose();
    }
  }

  Iterable<_DmMaterialEntry> _filteredMaterials() {
    Iterable<_DmMaterialEntry> items =
        _materials.where((m) => m.kind == _selectedKind);
    if (_dateFilterDays > 0) {
      final from = DateTime.now().subtract(Duration(days: _dateFilterDays));
      items = items.where((m) => m.timestamp.isAfter(from));
    }
    if (_selectedKind == _DmMaterialKind.file && _fileTypeFilter != 'all') {
      items = items.where((m) {
        final ext = p
            .extension((m.message.fileName ?? m.mediaPath ?? ''))
            .toLowerCase();
        switch (_fileTypeFilter) {
          case 'image':
            return const {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic'}
                .contains(ext);
          case 'video':
            return const {'.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v'}
                .contains(ext);
          case 'audio':
            return const {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg'}
                .contains(ext);
          case 'doc':
            return const {
              '.doc',
              '.docx',
              '.pdf',
              '.txt',
              '.rtf',
              '.md',
              '.xls',
              '.xlsx',
              '.ppt',
              '.pptx'
            }.contains(ext);
          case 'archive':
            return const {'.zip', '.rar', '.7z', '.tar', '.gz'}.contains(ext);
          case 'other':
            return !const {
              '.png',
              '.jpg',
              '.jpeg',
              '.gif',
              '.webp',
              '.heic',
              '.mp4',
              '.mov',
              '.mkv',
              '.webm',
              '.avi',
              '.m4v',
              '.mp3',
              '.m4a',
              '.aac',
              '.wav',
              '.flac',
              '.ogg',
              '.doc',
              '.docx',
              '.pdf',
              '.txt',
              '.rtf',
              '.md',
              '.xls',
              '.xlsx',
              '.ppt',
              '.pptx',
              '.zip',
              '.rar',
              '.7z',
              '.tar',
              '.gz',
            }.contains(ext);
        }
        return true;
      });
    }
    return items;
  }

  String _kindTitle(_DmMaterialKind k) {
    switch (k) {
      case _DmMaterialKind.squareVideo:
        return 'Квадратики';
      case _DmMaterialKind.voice:
        return 'Голосовые';
      case _DmMaterialKind.video:
        return 'Видео';
      case _DmMaterialKind.photo:
        return 'Фото';
      case _DmMaterialKind.file:
        return 'Файлы';
      case _DmMaterialKind.link:
        return 'Ссылки';
      case _DmMaterialKind.phone:
        return 'Телефоны';
      case _DmMaterialKind.code:
        return 'Код';
    }
  }

  IconData _kindIcon(_DmMaterialKind k) {
    switch (k) {
      case _DmMaterialKind.squareVideo:
        return Icons.crop_square_rounded;
      case _DmMaterialKind.voice:
        return Icons.mic_outlined;
      case _DmMaterialKind.video:
        return Icons.videocam_outlined;
      case _DmMaterialKind.photo:
        return Icons.photo_outlined;
      case _DmMaterialKind.file:
        return Icons.attach_file_outlined;
      case _DmMaterialKind.link:
        return Icons.link;
      case _DmMaterialKind.phone:
        return Icons.phone_outlined;
      case _DmMaterialKind.code:
        return Icons.code;
    }
  }

  Widget _materialTile(BuildContext context, _DmMaterialEntry e) {
    final cs = Theme.of(context).colorScheme;
    final subtitle = e.subtitle;
    Widget leading;
    if (e.kind == _DmMaterialKind.photo && e.mediaPath != null) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(e.mediaPath!),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.photo),
        ),
      );
    } else {
      leading = Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(_kindIcon(e.kind), size: 22, color: cs.onPrimaryContainer),
      );
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(
        e.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle == null || subtitle.isEmpty
            ? '${e.timestamp.day.toString().padLeft(2, '0')}.${e.timestamp.month.toString().padLeft(2, '0')}.${e.timestamp.year} ${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}'
            : subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.pop(context, e.message.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stories = StoryService.instance.storiesFor(widget.peerId);

    final nick = _nick ?? widget.nickname;
    final color = _color ?? widget.avatarColor;
    final emoji = _emoji ?? widget.avatarEmoji;
    final avatarPath = _avatarPath ?? widget.avatarImagePath;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Collapsible header with banner + avatar ──
          SliverAppBar(
            expandedHeight: _peerProfileBannerVisible(_bannerPath) ? 220 : 120,
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
                      if (_isOwnedRelayBot)
                        const PopupMenuItem(
                          value: 'edit_bot_profile',
                          child: Row(children: [
                            Icon(Icons.edit_outlined, size: 20),
                            SizedBox(width: 12),
                            Text('Редактировать профиль бота'),
                          ]),
                        ),
                      if (isBlocked)
                        const PopupMenuItem(
                          value: 'unblock',
                          child: Row(children: [
                            Icon(Icons.lock_open,
                                size: 20, color: Colors.green),
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
                          Icon(Icons.delete_outline,
                              size: 20, color: Colors.red),
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
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
              background: _peerProfileBannerBackground(color),
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
                      hasUnviewedStory:
                          StoryService.instance.hasUnviewedStory(widget.peerId),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      nick,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700),
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
                      style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.4),
                          fontFamily: 'monospace'),
                    ),
                  ),

                  // ── Tags ──
                  if (_tags.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _tags
                          .map((tag) => Chip(
                                label: Text(tag,
                                    style: const TextStyle(fontSize: 12)),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                backgroundColor: cs.primaryContainer,
                              ))
                          .toList(),
                    ),
                  ],

                  const SizedBox(height: 12),
                  ValueListenableBuilder<int>(
                    valueListenable: RelayService.instance.presenceVersion,
                    builder: (_, __, ___) {
                      final hasMusic =
                          _musicPath != null && File(_musicPath!).existsSync();
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
                              icon: Icon(_musicPlaying
                                  ? Icons.stop
                                  : Icons.play_arrow),
                              label: Text(_musicPlaying ? 'Стоп' : 'Слушать'),
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
                  const SizedBox(height: 8),
                  Text(
                    'Материалы чата',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _DmMaterialKind.values.map((k) {
                      final c = _materials.where((m) => m.kind == k).length;
                      return ChoiceChip(
                        label: Text('${_kindTitle(k)} · $c'),
                        selected: _selectedKind == k,
                        onSelected: (_) => setState(() => _selectedKind = k),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.date_range_outlined, size: 18),
                      const SizedBox(width: 8),
                      const Text('Дата:'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _dateFilterDays,
                        items: const [
                          DropdownMenuItem(
                              value: 0, child: Text('За все время')),
                          DropdownMenuItem(value: 7, child: Text('7 дней')),
                          DropdownMenuItem(value: 30, child: Text('30 дней')),
                          DropdownMenuItem(value: 90, child: Text('90 дней')),
                          DropdownMenuItem(value: 365, child: Text('1 год')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _dateFilterDays = v);
                        },
                      ),
                    ],
                  ),
                  if (_selectedKind == _DmMaterialKind.file) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.filter_alt_outlined, size: 18),
                        const SizedBox(width: 8),
                        const Text('Тип файла:'),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _fileTypeFilter,
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('Все')),
                            DropdownMenuItem(
                                value: 'image', child: Text('Изображения')),
                            DropdownMenuItem(
                                value: 'video', child: Text('Видео')),
                            DropdownMenuItem(
                                value: 'audio', child: Text('Аудио')),
                            DropdownMenuItem(
                                value: 'doc', child: Text('Документы')),
                            DropdownMenuItem(
                                value: 'archive', child: Text('Архивы')),
                            DropdownMenuItem(
                                value: 'other', child: Text('Прочее')),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _fileTypeFilter = v);
                          },
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  ...(() {
                    final filtered = _filteredMaterials().toList();
                    if (filtered.isEmpty) {
                      return <Widget>[
                        Text(
                          'Ничего не найдено по фильтрам',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ];
                    }
                    return filtered
                        .take(200)
                        .map((e) => _materialTile(context, e))
                        .toList();
                  })(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bannerFallback(int color) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(color).withValues(alpha: 0.65),
              Color(color).withValues(alpha: 0.35),
            ],
          ),
        ),
      );
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
                style: TextStyle(
                    fontSize: 10, color: color, fontWeight: FontWeight.w500)),
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

class _FullScreenImageViewer extends StatefulWidget {
  final String imagePath;
  final Future<void> Function()? onSaveToGallery;

  const _FullScreenImageViewer({
    required this.imagePath,
    this.onSaveToGallery,
  });

  @override
  State<_FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<_FullScreenImageViewer> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: 0.5,
              maxScale: 6,
              clipBehavior: Clip.none,
              boundaryMargin: const EdgeInsets.all(80),
              child: Center(
                child: Image.file(
                  File(widget.imagePath),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  if (widget.onSaveToGallery != null)
                    IconButton(
                      tooltip: 'Сохранить в галерею',
                      icon: const Icon(Icons.download,
                          color: Colors.white, size: 26),
                      onPressed: () async {
                        await widget.onSaveToGallery!();
                      },
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
