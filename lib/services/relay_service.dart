import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_settings.dart';
import 'ble_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'profile_service.dart';

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
class RelayService {
  RelayService._();
  static final RelayService instance = RelayService._();

  /// Default public relay server
  static const defaultServerUrl = 'wss://rlink-relay.onrender.com';

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _intentionalClose = false;

  /// Current connection state
  final ValueNotifier<RelayState> state = ValueNotifier(RelayState.disconnected);

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

  /// Search results
  final ValueNotifier<List<RelayPeer>> searchResults = ValueNotifier([]);

  /// Callback for receiving blobs
  void Function(String fromId, String msgId, Uint8List data,
      bool isVoice, bool isVideo, bool isSquare, bool isFile, String? fileName)? onBlobReceived;

  /// Peer X25519 keys discovered via relay
  final Map<String, String> _peerX25519Keys = {};

  /// Online presence of known peers
  final Map<String, bool> _peerOnline = {};
  final ValueNotifier<int> presenceVersion = ValueNotifier(0);

  bool get isConnected => state.value == RelayState.connected;
  String? get serverUrl => AppSettings.instance.relayServerUrl;

  /// Check if a peer is online on relay
  bool isPeerOnline(String publicKey) => _peerOnline[publicKey] ?? false;

  /// Get X25519 key for a peer discovered via relay
  String? getPeerX25519Key(String publicKey) => _peerX25519Keys[publicKey];

  /// Find full public key by 8-char prefix (for directed relay sends).
  /// Checks online peers first, then all known peers.
  String? findPeerByPrefix(String rid8) {
    final prefix = rid8.toLowerCase();
    // Check online peers first
    for (final key in _peerOnline.keys) {
      if (key.toLowerCase().startsWith(prefix)) return key;
    }
    return null;
  }

  // ── Connect / Disconnect ─────────────────────────────────────

  Future<void> connect() async {
    if (state.value == RelayState.connected ||
        state.value == RelayState.connecting) return;

    final customUrl = AppSettings.instance.relayServerUrl;
    final url = customUrl.isNotEmpty ? customUrl : defaultServerUrl;

    final myKey = CryptoService.instance.publicKeyHex;
    if (myKey.isEmpty) return;

    state.value = RelayState.connecting;
    _intentionalClose = false;

    try {
      debugPrint('[RLINK][Relay] Connecting to $url');
      _channel = WebSocketChannel.connect(Uri.parse(url));
      await _channel!.ready;

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
      final nick = ProfileService.instance.profile?.nickname ?? '';
      final x25519Key = CryptoService.instance.x25519PublicKeyBase64;
      _channel!.sink.add(jsonEncode({
        'type': 'register',
        'publicKey': myKey,
        'nick': nick,
        if (x25519Key.isNotEmpty) 'x25519': x25519Key,
      }));

      // Start ping timer (keep-alive every 30s)
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (isConnected) {
          try {
            _channel?.sink.add(jsonEncode({'type': 'ping'}));
          } catch (_) {}
        }
      });

      state.value = RelayState.connected;
      debugPrint('[RLINK][Relay] Connected and registered');
    } catch (e) {
      debugPrint('[RLINK][Relay] Connection failed: $e');
      state.value = RelayState.disconnected;
      _scheduleReconnect();
    }
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
    debugPrint('[RLINK][Relay] Disconnected');
  }

  void _onDisconnected() {
    _pingTimer?.cancel();
    _subscription?.cancel();
    _channel = null;
    _chunkQueue.clear();
    _draining = false;
    state.value = RelayState.disconnected;
    if (!_intentionalClose && !_disposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_disposed && !_intentionalClose && AppSettings.instance.relayEnabled) {
        connect();
      }
    });
  }

  void dispose() {
    _disposed = true;
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
    if (!isConnected) return;
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
      _channel?.sink.add(jsonEncode(envelope));
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
    _channel?.sink.add(jsonEncode(msg));
    Future.delayed(_chunkInterval, _drainNext);
  }

  /// Broadcast a gossip packet to all connected relay peers.
  /// img_chunk packets are throttled through the same queue as directed sends.
  Future<void> broadcastPacket(GossipPacket packet) async {
    if (!isConnected) return;
    final bytes = packet.encode();
    final b64 = base64Encode(bytes);
    final envelope = <String, dynamic>{'type': 'broadcast', 'data': b64};

    if (packet.type == 'img_chunk') {
      _chunkQueue.add(envelope);
      _startDraining();
    } else {
      _channel?.sink.add(jsonEncode(envelope));
    }
  }

  /// Send a compressed blob (voice/video/file) as a single relay message.
  /// This bypasses the chunk protocol — much faster over internet.
  /// The blob carries img_meta info so the receiver can reconstruct.
  Future<void> sendBlob({
    required String recipientKey,
    required String fromId,
    required String msgId,
    required Uint8List compressedData,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    String? fileName,
  }) async {
    if (!isConnected) return;
    final b64 = base64Encode(compressedData);
    final envelope = {
      'type': 'blob',
      'to': recipientKey,
      'msgId': msgId,
      'from': fromId,
      'data': b64,
      if (isVoice) 'voice': true,
      if (isVideo) 'video': true,
      if (isSquare) 'sq': true,
      if (isFile) 'file': true,
      if (fileName != null) 'fname': fileName,
    };
    try {
      _channel?.sink.add(jsonEncode(envelope));
      debugPrint('[RLINK][Relay] Sent blob ${compressedData.length} bytes for $msgId');
    } catch (e) {
      debugPrint('[RLINK][Relay] Failed to send blob: $e');
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

  /// Search for users by nickname or ID
  Future<void> searchUsers(String query) async {
    if (!isConnected || query.trim().isEmpty) {
      searchResults.value = [];
      return;
    }
    debugPrint('[RLINK][Relay] Searching for: "${query.trim()}"');
    _channel?.sink.add(jsonEncode({
      'type': 'search',
      'query': query.trim(),
    }));
  }

  // ── Receive ──────────────────────────────────────────────────

  void _onMessage(dynamic raw) {
    if (raw is! String) return;

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String?;
    switch (type) {
      case 'registered':
        final count = msg['onlineCount'] as int? ?? 0;
        onlineCount.value = count;
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
        break; // keep-alive response

      case 'error':
        debugPrint('[RLINK][Relay] Server error: ${msg['msg']}');
        break;
    }
  }

  void _handleIncomingPacket(Map<String, dynamic> msg) {
    final from = msg['from'] as String?;
    final data = msg['data'] as String?;
    if (from == null || data == null) return;

    try {
      // Decode base64 → raw bytes → feed to GossipRouter
      // GossipRouter handles decryption, dedup, and delivery
      final bytes = base64Decode(data);
      GossipRouter.instance.onPacketReceived(
        Uint8List.fromList(bytes),
        sourceId: 'relay:$from',
      );
    } catch (e) {
      debugPrint('[RLINK][Relay] Failed to decode incoming packet: $e');
    }
  }

  void _handleSearchResult(Map<String, dynamic> msg) {
    final results = msg['results'] as List? ?? [];
    final peers = results.map((r) {
      final m = r as Map<String, dynamic>;
      final peer = RelayPeer(
        publicKey: m['publicKey'] as String? ?? '',
        nick: m['nick'] as String? ?? '',
        shortId: m['shortId'] as String? ?? '',
        online: m['online'] as bool? ?? false,
        x25519Key: m['x25519'] as String? ?? '',
      );
      // Store X25519 key from search results
      if (peer.x25519Key.isNotEmpty && peer.publicKey.isNotEmpty) {
        _peerX25519Keys[peer.publicKey] = peer.x25519Key;
        BleService.instance.registerPeerX25519Key(peer.publicKey, peer.x25519Key);
        unawaited(ChatStorageService.instance.updateContactX25519Key(peer.publicKey, peer.x25519Key));
      }
      // Track as online
      if (peer.publicKey.isNotEmpty) {
        _peerOnline[peer.publicKey] = peer.online;
      }
      return peer;
    }).toList();
    debugPrint('[RLINK][Relay] Search results: ${peers.length} peers found');
    for (final p in peers) {
      debugPrint('[RLINK][Relay]   → ${p.shortId} "${p.nick}" (${p.publicKey.substring(0, 16)}...)');
    }
    searchResults.value = peers;
  }

  void _handlePresence(Map<String, dynamic> msg) {
    final publicKey = msg['publicKey'] as String?;
    final online = msg['online'] as bool?;
    if (publicKey == null || online == null) return;

    _peerOnline[publicKey] = online;
    presenceVersion.value++;

    // Store X25519 key if provided (for E2E encryption with relay-discovered peers)
    final x25519Key = msg['x25519'] as String?;
    if (x25519Key != null && x25519Key.isNotEmpty) {
      _peerX25519Keys[publicKey] = x25519Key;
      BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
      unawaited(ChatStorageService.instance.updateContactX25519Key(publicKey, x25519Key));
      debugPrint('[RLINK][Relay] Presence: ${publicKey.substring(0, 8)} → ${online ? 'online' : 'offline'} (x25519 key received)');
    } else {
      debugPrint('[RLINK][Relay] Presence: ${publicKey.substring(0, 8)} → ${online ? 'online' : 'offline'}');
    }
  }

  void _handleIncomingBlob(Map<String, dynamic> msg) {
    final from = msg['from'] as String?;
    final msgId = msg['msgId'] as String?;
    final data = msg['data'] as String?;
    if (from == null || msgId == null || data == null) return;

    try {
      final bytes = base64Decode(data);
      final isVoice = (msg['voice'] as bool?) ?? false;
      final isVideo = (msg['video'] as bool?) ?? false;
      final isSquare = (msg['sq'] as bool?) ?? false;
      final isFile = (msg['file'] as bool?) ?? false;
      final fileName = msg['fname'] as String?;
      debugPrint('[RLINK][Relay] Received blob ${bytes.length} bytes for $msgId');
      onBlobReceived?.call(from, msgId, Uint8List.fromList(bytes),
          isVoice, isVideo, isSquare, isFile, fileName);
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
    } else if (status == 'error') {
      debugPrint('[RLINK][Relay] Delivery ERROR → ${to.substring(0, 8)}');
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
  final String shortId;
  final bool online;
  final String x25519Key;

  const RelayPeer({
    required this.publicKey,
    required this.nick,
    required this.shortId,
    required this.online,
    this.x25519Key = '',
  });
}
