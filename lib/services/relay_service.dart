import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_settings.dart';
import 'ble_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'profile_service.dart';
import 'relay_web_warmup.dart';
import 'diagnostics_log_service.dart';

int _relayJsonInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

bool? _relayJsonBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
  }
  return null;
}

String _relayShort(String key) {
  if (key.isEmpty) return 'empty';
  return key.length > 8 ? key.substring(0, 8) : key;
}

void _relayTrace(String line) {
  debugPrint(line);
  DiagnosticsLogService.instance.add(line);
}

/// ═══════════════════════════════════════════════════════════════════
/// RelayService — WebSocket transport for internet messaging
/// ═══════════════════════════════════════════════════════════════════
///
/// Security model:
///   • All GossipPackets are encrypted E2E BEFORE relay (ChaCha20-Poly1305)
///   • Server sees only opaque base64 blobs — zero knowledge
///   • Server cannot read, modify, or forge messages
///   • X25519 ECDH ephemeral keys for perfect forward secrecy
///   • Ed25519 identity keys for authentication
///
/// The relay is just a "dumb pipe" — same packets that go over BLE
/// go through the relay. GossipRouter doesn't even know which
/// transport delivered the packet.
/// ═══════════════════════════════════════════════════════════════════
class RelayService with WidgetsBindingObserver {
  RelayService._();
  static final RelayService instance = RelayService._();

  // ── Reliability state ────────────────────────────────────────
  /// Время последнего полученного pong от сервера (для watchdog'а).
  DateTime _lastPongAt = DateTime.now();
  /// Счётчик неудачных попыток подключения (для exp backoff).
  int _retryCount = 0;
  /// Один раз навешиваем lifecycle-наблюдатель.
  bool _lifecycleAttached = false;

  /// Default public relay server.
  /// Захардкожен — пользователь не может переопределить через настройки
  /// (см. serverUrl getter и connect() ниже).
  static const defaultServerUrl = 'wss://rlink.ru.tuna.am';
  static const List<String> fallbackServerUrls = <String>[
    defaultServerUrl,
    'wss://ru.tuna.am',
  ];

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _intentionalClose = false;

  /// Current connection state
  final ValueNotifier<RelayState> state = ValueNotifier(RelayState.disconnected);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Online users count from server
  final ValueNotifier<int> onlineCount = ValueNotifier(0);

  /// Throttled queue for img_chunk packets (relay has strict rate limits).
  /// img_meta and control packets bypass the queue and are sent immediately.
  final _chunkQueue = <Map<String, dynamic>>[];
  bool _draining = false;
  // 50 ms between chunks = 20 chunks/sec. Stays well under relay rate limit
  // (300/10s = 30/sec) leaving headroom for control packets.
  // A 257-chunk photo takes ~13 s — acceptable for mesh transfer.
  static const _chunkInterval = Duration(milliseconds: 50);

  /// Last search query (for local fallback when server returns 0)
  String _lastSearchQuery = '';

  /// Search results
  final ValueNotifier<List<RelayPeer>> searchResults = ValueNotifier([]);

  /// Callback for receiving blobs
  void Function(
      String fromId,
      String msgId,
      Uint8List data,
      bool isVoice,
      bool isVideo,
      bool isSquare,
      bool isFile,
      bool isSticker,
      String? fileName,
      bool viewOnce)? onBlobReceived;

  /// Callback when a new peer comes online (publicKey) — used for avatar sync
  void Function(String publicKey)? onPeerOnline;

  /// Callback fired when a directed packet could not be delivered because the
  /// recipient is offline. The argument is the recipient's public key.
  /// Used by [MediaUploadQueue] to abort and re-queue inflight uploads.
  void Function(String recipientKey)? onDeliveryFailed;

  /// Зашифрованный снимок аккаунта (список каналов + ревизия), пришёл с relay.
  void Function(String sealedBlob)? onAccountSyncBlob;

  /// Подписанные записи публичного каталога каналов (`channel_dir_snapshot` после register).
  void Function(List<dynamic> entries)? onChannelDirectorySnapshot;

  /// Peer X25519 keys discovered via relay
  final Map<String, String> _peerX25519Keys = {};

  /// Online presence of known peers
  final Map<String, bool> _peerOnline = {};
  /// Peer nicks discovered via relay presence
  final Map<String, String> _peerNicks = {};
  /// Peer usernames discovered via relay presence
  final Map<String, String> _peerUsernames = {};
  final ValueNotifier<int> presenceVersion = ValueNotifier(0);

  bool get isConnected => state.value == RelayState.connected;
  /// URL сервера всегда захардкожен в defaultServerUrl.
  /// Любое значение в AppSettings.relayServerUrl игнорируется,
  /// чтобы клиенты не могли подключаться к чужим relay.
  String? get serverUrl => defaultServerUrl;

  Future<void> _safeSend(
    Map<String, dynamic> payload, {
    String context = '',
  }) async {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(payload));
    } catch (e) {
      final msg = e.toString();
      _relayTrace(
          '[RLINK][Relay] send failed${context.isEmpty ? '' : ' ($context)'}: $msg');
      // Browser can throw NotFoundError when underlying WS object is gone.
      // Force reconnect to restore a valid transport.
      if (!_intentionalClose && !_disposed) {
        unawaited(reconnect());
      }
    }
  }

  /// Check if a peer is online on relay
  bool isPeerOnline(String publicKey) => _peerOnline[publicKey] ?? false;

  /// Register a peer's username from gossip profile packet
  void registerPeerUsername(String publicKey, String username) {
    if (username.isNotEmpty) _peerUsernames[publicKey] = username;
  }

  /// Get X25519 key for a peer discovered via relay
  String? getPeerX25519Key(String publicKey) => _peerX25519Keys[publicKey];

  /// Find full public key by 8-char prefix (for directed relay sends).
  /// Checks online peers first, then contacts cache.
  String? findPeerByPrefix(String rid8) {
    final prefix = rid8.toLowerCase();
    final fullHex = RegExp(r'^[0-9a-fA-F]{64}$');
    // Check online peers first
    for (final key in _peerOnline.keys) {
      if (fullHex.hasMatch(key) && key.toLowerCase().startsWith(prefix)) {
        return key;
      }
    }
    // Fallback: check contacts cache
    for (final c in ChatStorageService.instance.contactsNotifier.value) {
      final key = c.publicKeyHex.trim();
      if (fullHex.hasMatch(key) && key.toLowerCase().startsWith(prefix)) {
        return key;
      }
    }
    return null;
  }

  // ── Connect / Disconnect ─────────────────────────────────────

  Future<void> connect() async {
    if (state.value == RelayState.connected ||
        state.value == RelayState.connecting) { return; }

    // Режим «только Bluetooth» — relay не используем.
    if (AppSettings.instance.connectionMode < 1) {
      debugPrint('[RLINK][Relay] connect() skipped — BLE-only mode');
      return;
    }

    var myKey = CryptoService.instance.publicKeyHex;
    if (myKey.isEmpty) {
      // Key may be temporarily unavailable if connect() races init.
      // Re-read existing keys from storage, but never regenerate implicitly.
      try {
        await CryptoService.instance.init();
        myKey = CryptoService.instance.publicKeyHex;
        final p = ProfileService.instance.profile;
        if (p != null && p.publicKeyHex != myKey) {
          await ProfileService.instance.updateProfile();
        }
      } catch (_) {}
      if (myKey.isEmpty) {
        lastError.value = 'Локальный публичный ключ не инициализирован';
        return;
      }
    }

    state.value = RelayState.connecting;
    _intentionalClose = false;
    lastError.value = null;

    String? connectedUrl;
    Exception? lastConnectError;
    for (final url in fallbackServerUrls) {
      try {
        if (kIsWeb) {
          final httpBase = url.replaceFirst('wss://', 'https://');
          await warmupRelayWebSession(httpBase);
        }
        debugPrint('[RLINK][Relay] Connecting to $url');
        _channel = WebSocketChannel.connect(Uri.parse(url));
        await _channel!.ready;
        connectedUrl = url;
        break;
      } catch (e) {
        try {
          await _channel?.sink.close();
        } catch (_) {}
        _channel = null;
        lastConnectError = Exception('$url: $e');
      }
    }
    if (connectedUrl == null || _channel == null) {
      final msg =
          (lastConnectError ?? Exception('No relay endpoint available'))
              .toString();
      debugPrint('[RLINK][Relay] Connection failed: $msg');
      lastError.value = msg;
      state.value = RelayState.disconnected;
      _scheduleReconnect();
      return;
    }

    try {

      // Listen for messages
      _subscription = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (e) {
          debugPrint('[RLINK][Relay] WebSocket error: $e');
          _onDisconnected();
        },
      );

      // Register with server (include X25519 key for E2E encryption)
      final profile = ProfileService.instance.profile;
      final nick = profile?.nickname ?? '';
      final username = profile?.username ?? '';
      final x25519Key = CryptoService.instance.x25519PublicKeyBase64;
      await _safeSend({
        'type': 'register',
        'publicKey': myKey,
        'nick': nick,
        if (username.isNotEmpty) 'username': username,
        if (x25519Key.isNotEmpty) 'x25519': x25519Key,
      }, context: 'register');

      // Start ping timer (keep-alive every 30s) с pong-watchdog'ом.
      // Если за 70 сек не пришёл ни один pong — соединение мертво (tuna закрыла,
      // сеть оборвалась без RST), форсим close → reconnect.
      _pingTimer?.cancel();
      _lastPongAt = DateTime.now();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!isConnected) return;
        final since = DateTime.now().difference(_lastPongAt);
        if (since > const Duration(seconds: 70)) {
          _relayTrace(
              '[RLINK][Relay] No pong for ${since.inSeconds}s — closing socket');
          try {
            _channel?.sink.close();
          } catch (_) {}
          return;
        }
        try {
          _safeSend({'type': 'ping'}, context: 'ping');
        } catch (_) {}
      });

      // Подписаться на AppLifecycleState один раз — чтобы при возврате окна
      // из background сразу проверить, жив ли сокет.
      _attachLifecycleObserver();

      state.value = RelayState.connected;
      lastError.value = null;
      _relayTrace('[RLINK][Relay] Connected and registered via $connectedUrl');
    } catch (e) {
      debugPrint('[RLINK][Relay] Connection failed: $e');
      lastError.value = e.toString();
      state.value = RelayState.disconnected;
      _scheduleReconnect();
    }
  }

  /// Force reconnect — disconnect and reconnect immediately.
  Future<void> reconnect() async {
    _relayTrace('[RLINK][Relay] Force reconnect requested');
    _intentionalClose = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _chunkQueue.clear();
    _draining = false;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    state.value = RelayState.disconnected;
    _intentionalClose = false;
    await connect();
  }

  void disconnect() {
    _intentionalClose = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _chunkQueue.clear();
    _draining = false;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    state.value = RelayState.disconnected;
    lastError.value = null;
    _relayTrace('[RLINK][Relay] Disconnected');
  }

  void _onDisconnected() {
    // Capture closeCode/closeReason до того как обнулим _channel.
    final cc = _channel?.closeCode;
    final cr = _channel?.closeReason;
    _pingTimer?.cancel();
    _subscription?.cancel();
    _channel = null;
    _chunkQueue.clear();
    _draining = false;
    state.value = RelayState.disconnected;
    final detail = cc == null
        ? ''
        : ' (closeCode=$cc${cr == null || cr.isEmpty ? '' : ', $cr'})';
    _relayTrace('[RLINK][Relay] Disconnected$detail');
    lastError.value = 'Соединение закрыто$detail';
    if (!_intentionalClose && !_disposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // Экспоненциальный backoff: 1, 2, 4, 8, 16, 30, 30, … секунд (cap 30).
    final delay = _retryCount >= 5 ? 30 : (1 << _retryCount);
    _retryCount++;
    _relayTrace('[RLINK][Relay] Reconnect in ${delay}s (attempt #$_retryCount)');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_disposed &&
          !_intentionalClose &&
          AppSettings.instance.connectionMode >= 1) {
        connect();
      }
    });
  }

  // ── Lifecycle observer ─────────────────────────────────────────
  void _attachLifecycleObserver() {
    if (_lifecycleAttached) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleAttached = true;
    } catch (_) {
      // WidgetsBinding ещё не инициализирован (например, в early init или unit-test) — не критично.
    }
  }

  // Параметр назван `lifecycle`, чтобы не затенять поле класса `state`
  // (ValueNotifier<RelayState>). Линт avoid_renaming_method_parameters
  // здесь игнорируется осознанно.
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) { // ignore: avoid_renaming_method_parameters
    if (lifecycle != AppLifecycleState.resumed) return;
    if (state.value != RelayState.connected) {
      _relayTrace(
          '[RLINK][Relay] Lifecycle resumed (state=${state.value}) → reconnect');
      reconnect();
      return;
    }
    // Соединение помечено connected, но за время сна сокет мог стать мёртвым
    // незаметно. Если pong старее 30 сек — превентивно переподключаемся.
    final since = DateTime.now().difference(_lastPongAt);
    if (since > const Duration(seconds: 30)) {
      _relayTrace(
          '[RLINK][Relay] Lifecycle resumed, stale pong (${since.inSeconds}s) → reconnect');
      reconnect();
    }
  }

  void dispose() {
    _disposed = true;
    if (_lifecycleAttached) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _lifecycleAttached = false;
    }
    disconnect();
  }

  // ── Send ─────────────────────────────────────────────────────

  /// Send an encrypted gossip packet to a specific peer via relay.
  /// The packet data is ALREADY encrypted by GossipRouter — we just
  /// base64-encode and forward as an opaque blob.
  ///
  /// img_chunk packets are throttled through an internal queue to avoid
  /// relay server rate-limiting (100+ chunks/image would be rejected instantly).
  Future<void> sendPacket(GossipPacket packet, {String? recipientKey}) async {
    if (!isConnected) {
      _relayTrace(
          '[RLINK][Relay][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=not_connected');
      return;
    }
    final bytes = packet.encode();
    final b64 = base64Encode(bytes);

    final Map<String, dynamic> envelope;
    if (recipientKey != null && recipientKey.isNotEmpty) {
      envelope = {'type': 'packet', 'to': recipientKey, 'data': b64};
    } else {
      envelope = {'type': 'broadcast', 'data': b64};
    }

    if (packet.type == 'img_chunk') {
      // Queue chunks and drain at _chunkInterval pace to avoid rate-limiting
      _chunkQueue.add(envelope);
      _startDraining();
    } else {
      // Control, text, meta, profile packets go out immediately
      if (packet.type == 'msg' ||
          packet.type == 'raw' ||
          packet.type == 'pair_req' ||
          packet.type == 'pair_acc') {
        _relayTrace('[RLINK][Relay][TX] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
            'to=${_relayShort(recipientKey ?? '')} rid=${_relayShort(packet.recipientId ?? '')} '
            'r8=${packet.payload['r'] ?? '-'}');
      }
      await _safeSend(envelope, context: 'sendPacket:${packet.type}');
    }
  }

  void _startDraining() {
    if (_draining) return;
    _draining = true;
    _drainNext();
  }

  void _drainNext() {
    if (_chunkQueue.isEmpty || !isConnected) {
      _draining = false;
      return;
    }
    final msg = _chunkQueue.removeAt(0);
    unawaited(_safeSend(msg, context: 'drainChunk'));
    Future.delayed(_chunkInterval, _drainNext);
  }

  /// Broadcast a gossip packet to all connected relay peers.
  /// img_chunk packets are throttled through the same queue as directed sends.
  Future<void> broadcastPacket(GossipPacket packet) async {
    if (!isConnected) {
      _relayTrace(
          '[RLINK][Relay][DROP] type=${packet.type} id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} reason=not_connected');
      return;
    }
    final bytes = packet.encode();
    final b64 = base64Encode(bytes);
    final envelope = <String, dynamic>{'type': 'broadcast', 'data': b64};

    if (packet.type == 'img_chunk') {
      _chunkQueue.add(envelope);
      _startDraining();
    } else {
      if (packet.type == 'ether') {
        _relayTrace('[RLINK][Relay][TX] type=ether id=${packet.id.substring(0, packet.id.length.clamp(0, 8))} '
            'len=${(packet.payload['text'] as String?)?.length ?? 0}');
      }
      await _safeSend(envelope, context: 'broadcastPacket:${packet.type}');
    }
  }

  /// Send a compressed blob (voice/video/file/story-image) as a single relay message.
  ///
  /// Sends as relay type `blob` — no packet wrapping, no double-base64.
  /// The relay routes it via the `to` field and the receiver handles it via
  /// [_handleIncomingBlob].  Relay limit: 10 MB raw message (vs 256 KB for packets).
  Future<void> sendBlob({
    required String recipientKey,
    required String fromId,
    required String msgId,
    required Uint8List compressedData,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    bool isSticker = false,
    String? fileName,
    bool viewOnce = false,
  }) async {
    if (!isConnected) return;
    final b64 = base64Encode(compressedData);
    // Send as 'blob' type directly — single base64, no packet wrapping.
    // The relay server routes via 'to', replaces it with 'from', and forwards.
    final msg = <String, dynamic>{
      'type': 'blob',
      'to': recipientKey,
      'msgId': msgId,
      'from': fromId,
      'data': b64,
      if (isVoice) 'voice': true,
      if (isVideo) 'video': true,
      if (isSquare) 'sq': true,
      if (isFile) 'file': true,
      if (isSticker) 'stk': true,
      if (fileName != null) 'fname': fileName,
      if (viewOnce) 'vo': true,
    };
    try {
      await _safeSend(msg, context: 'sendBlob');
      debugPrint('[RLINK][Relay] Sent blob ${compressedData.length} bytes for $msgId');
    } catch (e) {
      debugPrint('[RLINK][Relay] Failed to send blob: $e');
    }
  }

  /// Send a single chunk of a large blob via relay.
  ///
  /// Also uses `blob` type — bypasses rate limiting and the 256 KB packet limit.
  /// Relay limit per message: 10 MB raw (chunk after base64 ≈ 267 KB for 200 KB raw).
  Future<void> sendBlobChunk({
    required String recipientKey,
    required String fromId,
    required String msgId,
    required int chunkIdx,
    required int chunkTotal,
    required Uint8List chunkData,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    bool isSticker = false,
    String? fileName,
    bool viewOnce = false,
  }) async {
    if (!isConnected) return;
    final b64 = base64Encode(chunkData);
    // Meta flags + filename only in first chunk — saves bytes.
    final msg = <String, dynamic>{
      'type': 'blob',
      'to': recipientKey,
      'msgId': msgId,
      'from': fromId,
      'data': b64,
      'cIdx': chunkIdx,
      'cTot': chunkTotal,
      if (chunkIdx == 0 && isVoice) 'voice': true,
      if (chunkIdx == 0 && isVideo) 'video': true,
      if (chunkIdx == 0 && isSquare) 'sq': true,
      if (chunkIdx == 0 && isFile) 'file': true,
      if (chunkIdx == 0 && isSticker) 'stk': true,
      if (chunkIdx == 0 && fileName != null) 'fname': fileName,
      if (chunkIdx == 0 && viewOnce) 'vo': true,
    };
    try {
      await _safeSend(msg, context: 'sendBlobChunk');
      debugPrint('[RLINK][Relay] Sent blob chunk $chunkIdx/$chunkTotal '
          '(${chunkData.length} bytes) for $msgId');
    } catch (e) {
      debugPrint('[RLINK][Relay] Failed to send blob chunk: $e');
    }
  }

  /// Progress notifier for current blob transfer (0.0 - 1.0)
  final ValueNotifier<double> sendProgress = ValueNotifier(0);
  String? _currentSendMsgId;
  String? get currentSendMsgId => _currentSendMsgId;
  void updateSendProgress(String msgId, double progress) {
    _currentSendMsgId = progress >= 1.0 ? null : msgId;
    sendProgress.value = progress;
  }

  /// Search for users by nickname, username, or ID.
  /// Searches local presence cache + contacts first, then queries server.
  Future<void> searchUsers(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      searchResults.value = [];
      return;
    }
    _lastSearchQuery = q;
    debugPrint('[RLINK][Relay] Searching for: "$q" (known online: ${knownOnlinePeers.length})');

    // Immediately search local presence cache + contacts DB (instant results)
    final localResults = _searchLocalPeers(q);
    if (localResults.isNotEmpty) {
      debugPrint('[RLINK][Relay] Local match: ${localResults.length}');
      searchResults.value = localResults;
    }

    // Also query server for authoritative results
    if (isConnected) {
      _safeSend({
        'type': 'search',
        'query': q,
      }, context: 'search');
    }
  }

  /// Search known online peers from local presence cache + contacts DB
  List<RelayPeer> _searchLocalPeers(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return [];

    final myKey = CryptoService.instance.publicKeyHex;
    final results = <String, RelayPeer>{};

    // Search online presence cache
    for (final entry in _peerOnline.entries) {
      if (!entry.value) continue;
      if (entry.key == myKey) continue;

      final publicKey = entry.key;
      final shortId = publicKey.length > 8 ? publicKey.substring(0, 8) : publicKey;
      final nick = _peerNicks[publicKey] ?? '';
      final uname = _peerUsernames[publicKey] ?? '';

      if (nick.toLowerCase().contains(q) ||
          uname.toLowerCase().contains(q) ||
          shortId.toLowerCase().contains(q) ||
          publicKey.toLowerCase().startsWith(q)) {
        results[publicKey] = RelayPeer(
          publicKey: publicKey,
          nick: nick,
          username: uname,
          shortId: shortId,
          online: true,
          x25519Key: _peerX25519Keys[publicKey] ?? '',
        );
      }
    }

    // Also search contacts DB for username matches (gossip-delivered usernames)
    for (final c in ChatStorageService.instance.contactsNotifier.value) {
      if (c.publicKeyHex == myKey) continue;
      if (results.containsKey(c.publicKeyHex)) continue;
      final shortId = c.publicKeyHex.length > 8 ? c.publicKeyHex.substring(0, 8) : c.publicKeyHex;
      if (c.username.toLowerCase().contains(q) ||
          c.nickname.toLowerCase().contains(q) ||
          shortId.toLowerCase().contains(q) ||
          c.publicKeyHex.toLowerCase().startsWith(q)) {
        results[c.publicKeyHex] = RelayPeer(
          publicKey: c.publicKeyHex,
          nick: c.nickname,
          username: c.username,
          shortId: shortId,
          online: _peerOnline[c.publicKeyHex] ?? false,
          x25519Key: _peerX25519Keys[c.publicKeyHex] ?? c.x25519Key ?? '',
        );
      }
    }
    return results.values.toList();
  }

  /// All known online peers (from presence data)
  List<RelayPeer> get knownOnlinePeers {
    final myKey = CryptoService.instance.publicKeyHex;
    return _peerOnline.entries
        .where((e) => e.value && e.key != myKey)
        .map((e) {
          final pk = e.key;
          return RelayPeer(
            publicKey: pk,
            nick: _peerNicks[pk] ?? '',
            username: _peerUsernames[pk] ?? '',
            shortId: pk.length > 8 ? pk.substring(0, 8) : pk,
            online: true,
            x25519Key: _peerX25519Keys[pk] ?? '',
          );
        }).toList();
  }

  // ── Receive ──────────────────────────────────────────────────

  void _onMessage(dynamic raw) {
    // package:web_socket may deliver JSON as UTF-8 [Uint8List] on some browsers
    // or proxies; treat both text and binary frames as JSON payloads.
    final String payload;
    if (raw is String) {
      payload = raw;
    } else if (raw is Uint8List) {
      try {
        payload = utf8.decode(raw);
      } catch (_) {
        return;
      }
    } else if (raw is List<int>) {
      try {
        payload = utf8.decode(raw);
      } catch (_) {
        return;
      }
    } else {
      return;
    }

    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    try {
      final type = msg['type']?.toString();
      switch (type) {
        case 'registered':
          final count = _relayJsonInt(msg['onlineCount']);
          onlineCount.value = count;
          // Успешный handshake → сбрасываем backoff.
          _retryCount = 0;
          _lastPongAt = DateTime.now();
          debugPrint('[RLINK][Relay] Registered, $count users online');
          break;

        case 'packet':
          _handleIncomingPacket(msg);
          break;

        case 'search_result':
          _handleSearchResult(msg);
          break;

        case 'presence':
          _handlePresence(msg);
          break;

        case 'blob':
          _handleIncomingBlob(msg);
          break;

        case 'delivery_status':
          _handleDeliveryStatus(msg);
          break;

        case 'pong':
          // keep-alive response — обновляем watchdog
          _lastPongAt = DateTime.now();
          break;

        case 'account_sync_blob':
          final data = msg['data'] as String?;
          if (data != null && data.isNotEmpty) {
            onAccountSyncBlob?.call(data);
          }
          break;

        case 'channel_dir_snapshot':
          final list = msg['channels'] as List<dynamic>?;
          if (list != null && list.isNotEmpty) {
            onChannelDirectorySnapshot?.call(list);
          }
          break;

        case 'channel_dir_ack':
          break;

        case 'account_sync_ack':
          break;

        case 'error':
          debugPrint('[RLINK][Relay] Server error: ${msg['msg']}');
          break;
      }
    } catch (e, st) {
      debugPrint('[RLINK][Relay] _onMessage error: $e\n$st');
      if (kIsWeb) {
        // ignore: avoid_print
        print('[RLINK][Relay] _onMessage error: $e');
      }
    }
  }

  /// Публикация записи в каталог публичных каналов (подписанный JSON — см. [ChannelDirectoryRelay]).
  Future<void> putChannelDirectory({
    required String payload,
    required String signatureHex,
  }) async {
    if (!isConnected) return;
    if (payload.isEmpty || payload.length > 16384) return;
    if (signatureHex.length != 128) return;
    try {
      await _safeSend({
        'type': 'channel_dir_put',
        'payload': payload,
        'signature': signatureHex,
      }, context: 'channel_dir_put');
    } catch (e) {
      debugPrint('[RLINK][Relay] channel_dir_put failed: $e');
    }
  }

  /// Сохранить на relay зашифрованный бокс аккаунта (тот же формат, что admin_cfg2).
  Future<void> putAccountSyncBlob(String sealedBoxJson) async {
    if (!isConnected) return;
    if (sealedBoxJson.length > 131072) return;
    try {
      await _safeSend({
        'type': 'account_sync_put',
        'data': sealedBoxJson,
      }, context: 'account_sync_put');
    } catch (e) {
      debugPrint('[RLINK][Relay] account_sync_put failed: $e');
    }
  }

  void _handleIncomingPacket(Map<String, dynamic> msg) {
    final from = msg['from'] as String?;
    final data = msg['data'] as String?;
    if (from == null || data == null) return;

    try {
      // Decode base64 → check if this is a blob wrapped in a packet envelope
      final bytes = base64Decode(data);

      // Try to detect blob-in-packet: valid UTF-8 JSON with 'isBlob' flag
      bool handled = false;
      try {
        final jsonStr = utf8.decode(bytes);
        final inner = jsonDecode(jsonStr) as Map<String, dynamic>;
        if (inner['isBlob'] == true) {
          // This is a blob wrapped as a packet — delegate to blob handler
          inner['from'] = from; // ensure sender info
          _handleIncomingBlob(inner);
          handled = true;
        }
      } catch (_) {
        // Not JSON / not a blob — treat as normal gossip packet
      }

      if (!handled) {
        final decoded = GossipPacket.decode(Uint8List.fromList(bytes));
        if (decoded != null &&
            (decoded.type == 'msg' ||
                decoded.type == 'raw' ||
                decoded.type == 'pair_req' ||
                decoded.type == 'pair_acc' ||
                decoded.type == 'ether')) {
          _relayTrace('[RLINK][Relay][RX] type=${decoded.type} id=${decoded.id.substring(0, decoded.id.length.clamp(0, 8))} '
              'from=${_relayShort(from)} rid=${_relayShort(decoded.recipientId ?? '')} r8=${decoded.payload['r'] ?? '-'}');
        }
        // Regular gossip packet — feed to GossipRouter
        GossipRouter.instance.onPacketReceived(
          Uint8List.fromList(bytes),
          sourceId: 'relay:$from',
        );
      }
    } catch (e) {
      debugPrint('[RLINK][Relay] Failed to decode incoming packet: $e');
    }
  }

  void _handleSearchResult(Map<String, dynamic> msg) {
    final results = msg['results'] as List? ?? [];
    final serverPeers = results.map((r) {
      final m = r as Map<String, dynamic>;
      final peer = RelayPeer(
        publicKey: m['publicKey'] as String? ?? '',
        nick: m['nick'] as String? ?? '',
        username: m['username'] as String? ?? '',
        shortId: m['shortId'] as String? ?? '',
        online: _relayJsonBool(m['online']) ?? false,
        x25519Key: m['x25519'] as String? ?? '',
      );
      if (peer.x25519Key.isNotEmpty && peer.publicKey.isNotEmpty) {
        _peerX25519Keys[peer.publicKey] = peer.x25519Key;
        BleService.instance.registerPeerX25519Key(peer.publicKey, peer.x25519Key);
        unawaited(ChatStorageService.instance.updateContactX25519Key(peer.publicKey, peer.x25519Key));
      }
      if (peer.publicKey.isNotEmpty) {
        _peerOnline[peer.publicKey] = peer.online;
      }
      return peer;
    }).toList();

    debugPrint('[RLINK][Relay] Server search: ${serverPeers.length} results');

    if (serverPeers.isNotEmpty) {
      // Merge server + local (server wins for duplicates)
      final merged = <String, RelayPeer>{};
      for (final p in serverPeers) { merged[p.publicKey] = p; }
      final local = _searchLocalPeers(_lastSearchQuery);
      for (final p in local) { merged.putIfAbsent(p.publicKey, () => p); }
      searchResults.value = merged.values.toList();
    } else if (_lastSearchQuery.isNotEmpty) {
      // Server returned 0 — fall back to local presence cache + contacts
      final local = _searchLocalPeers(_lastSearchQuery);
      if (local.isNotEmpty) {
        debugPrint('[RLINK][Relay] Server 0 → local fallback: ${local.length} matches');
        searchResults.value = local;
      } else if (searchResults.value.isEmpty) {
        // Only clear if no results were already set by the initial local search
        searchResults.value = [];
        final online = knownOnlinePeers;
        debugPrint('[RLINK][Relay] No match. Online peers (${online.length}): '
            '${online.map((p) => '${p.shortId}("${p.nick}")').join(', ')}');
      }
    } else {
      searchResults.value = serverPeers;
    }

    for (final p in searchResults.value) {
      debugPrint('[RLINK][Relay]   → ${p.shortId} "${p.nick}"');
    }
  }

  void _handlePresence(Map<String, dynamic> msg) {
    final publicKey = msg['publicKey'] as String?;
    final online = _relayJsonBool(msg['online']);
    if (publicKey == null || online == null) return;

    _peerOnline[publicKey] = online;
    presenceVersion.value++;

    // Store X25519 key if provided (for E2E encryption with relay-discovered peers)
    final x25519Key = msg['x25519'] as String?;
    if (x25519Key != null && x25519Key.isNotEmpty) {
      _peerX25519Keys[publicKey] = x25519Key;
      BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
      unawaited(ChatStorageService.instance.updateContactX25519Key(publicKey, x25519Key));
    }

    // Store nick and username from presence data
    final nick = msg['nick'] as String?;
    if (nick != null && nick.isNotEmpty) {
      _peerNicks[publicKey] = nick;
    }
    final uname = msg['username'] as String?;
    if (uname != null && uname.isNotEmpty) {
      _peerUsernames[publicKey] = uname;
    }

    debugPrint('[RLINK][Relay] Presence: ${publicKey.substring(0, 8)} → ${online ? 'online' : 'offline'}');

    // Notify about new peer online (for avatar sync, etc.)
    if (online) {
      onPeerOnline?.call(publicKey);
    }
  }

  /// In-flight blob chunk assemblies, keyed by msgId.
  final Map<String, _BlobAssembly> _blobAssemblies = {};

  void _handleIncomingBlob(Map<String, dynamic> msg) {
    final from = msg['from'] as String?;
    final msgId = msg['msgId'] as String?;
    final data = msg['data'] as String?;
    if (from == null || msgId == null || data == null) return;

    try {
      final bytes = base64Decode(data);
      final chunkIdx = msg['cIdx'] as int?;
      final chunkTotal = msg['cTot'] as int?;

      // Single-blob path (no chunking)
      if (chunkIdx == null || chunkTotal == null || chunkTotal <= 1) {
        final isVoice = (msg['voice'] as bool?) ?? false;
        final isVideo = (msg['video'] as bool?) ?? false;
        final isSquare = (msg['sq'] as bool?) ?? false;
        final isFile = (msg['file'] as bool?) ?? false;
        final isSticker = (msg['stk'] as bool?) ?? false;
        final fileName = msg['fname'] as String?;
        final viewOnce = (msg['vo'] as bool?) ?? false;
        debugPrint('[RLINK][Relay] Received blob ${bytes.length} bytes for $msgId');
        onBlobReceived?.call(from, msgId, Uint8List.fromList(bytes),
            isVoice, isVideo, isSquare, isFile, isSticker, fileName, viewOnce);
        return;
      }

      // Chunked path — accumulate until all chunks are in.
      final assembly = _blobAssemblies.putIfAbsent(
        msgId,
        () => _BlobAssembly(total: chunkTotal, from: from),
      );
      assembly.chunks[chunkIdx] = Uint8List.fromList(bytes);
      // First chunk carries the media-type flags and filename.
      if (chunkIdx == 0) {
        assembly.isVoice = (msg['voice'] as bool?) ?? false;
        assembly.isVideo = (msg['video'] as bool?) ?? false;
        assembly.isSquare = (msg['sq'] as bool?) ?? false;
        assembly.isFile = (msg['file'] as bool?) ?? false;
        assembly.isSticker = (msg['stk'] as bool?) ?? false;
        assembly.fileName = msg['fname'] as String?;
        assembly.viewOnce = (msg['vo'] as bool?) ?? false;
      }
      debugPrint('[RLINK][Relay] Blob chunk $chunkIdx/$chunkTotal '
          '(${bytes.length} bytes) for $msgId '
          '[${assembly.chunks.length}/${assembly.total}]');

      if (assembly.chunks.length >= assembly.total) {
        // All chunks received — concatenate in order and deliver.
        final builder = BytesBuilder();
        for (var i = 0; i < assembly.total; i++) {
          final c = assembly.chunks[i];
          if (c == null) {
            debugPrint('[RLINK][Relay] Missing chunk $i for $msgId — dropping');
            _blobAssemblies.remove(msgId);
            return;
          }
          builder.add(c);
        }
        final full = builder.toBytes();
        _blobAssemblies.remove(msgId);
        debugPrint('[RLINK][Relay] Assembled chunked blob ${full.length} bytes for $msgId');
        onBlobReceived?.call(from, msgId, full,
            assembly.isVoice, assembly.isVideo, assembly.isSquare,
            assembly.isFile, assembly.isSticker, assembly.fileName,
            assembly.viewOnce);
      }
    } catch (e) {
      debugPrint('[RLINK][Relay] Failed to decode blob: $e');
    }
  }

  void _handleDeliveryStatus(Map<String, dynamic> msg) {
    final to = msg['to'] as String?;
    final status = msg['status'] as String?;
    if (to == null || status == null) return;
    if (status == 'offline') {
      _peerOnline[to] = false;
      presenceVersion.value++;
      debugPrint('[RLINK][Relay] Delivery FAILED → ${to.substring(0, 8)} is OFFLINE');
      onDeliveryFailed?.call(to);
    } else if (status == 'error') {
      debugPrint('[RLINK][Relay] Delivery ERROR → ${to.substring(0, 8)}');
      onDeliveryFailed?.call(to);
    } else {
      debugPrint('[RLINK][Relay] Delivery to ${to.substring(0, 8)}: $status');
    }
  }
}

// ── Models ──────────────────────────────────────────────────────

enum RelayState { disconnected, connecting, connected }

class RelayPeer {
  final String publicKey;
  final String nick;
  final String username;
  final String shortId;
  final bool online;
  final String x25519Key;

  const RelayPeer({
    required this.publicKey,
    required this.nick,
    this.username = '',
    required this.shortId,
    required this.online,
    this.x25519Key = '',
  });
}

/// Accumulator for a chunked blob arriving over relay.
class _BlobAssembly {
  final int total;
  final String from;
  final Map<int, Uint8List> chunks = {};
  bool isVoice = false;
  bool isVideo = false;
  bool isSquare = false;
  bool isFile = false;
  bool isSticker = false;
  bool viewOnce = false;
  String? fileName;
  _BlobAssembly({required this.total, required this.from});
}
