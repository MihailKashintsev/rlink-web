import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_settings.dart';
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
      debugPrint('[Relay] Connecting to $url');
      _channel = WebSocketChannel.connect(Uri.parse(url));
      await _channel!.ready;

      // Listen for messages
      _subscription = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (e) {
          debugPrint('[Relay] WebSocket error: $e');
          _onDisconnected();
        },
      );

      // Register with server
      final nick = ProfileService.instance.profile?.nickname ?? '';
      _channel!.sink.add(jsonEncode({
        'type': 'register',
        'publicKey': myKey,
        'nick': nick,
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
      debugPrint('[Relay] Connected and registered');
    } catch (e) {
      debugPrint('[Relay] Connection failed: $e');
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
    debugPrint('[Relay] Disconnected');
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

  /// Search for users by nickname or ID
  Future<void> searchUsers(String query) async {
    if (!isConnected || query.trim().isEmpty) {
      searchResults.value = [];
      return;
    }
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
        debugPrint('[Relay] Registered, $count users online');
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

      case 'delivery_status':
        _handleDeliveryStatus(msg);
        break;

      case 'pong':
        break; // keep-alive response

      case 'error':
        debugPrint('[Relay] Server error: ${msg['msg']}');
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
      debugPrint('[Relay] Failed to decode incoming packet: $e');
    }
  }

  void _handleSearchResult(Map<String, dynamic> msg) {
    final results = msg['results'] as List? ?? [];
    searchResults.value = results.map((r) {
      final m = r as Map<String, dynamic>;
      return RelayPeer(
        publicKey: m['publicKey'] as String? ?? '',
        nick: m['nick'] as String? ?? '',
        shortId: m['shortId'] as String? ?? '',
        online: m['online'] as bool? ?? false,
      );
    }).toList();
  }

  void _handlePresence(Map<String, dynamic> msg) {
    final publicKey = msg['publicKey'] as String?;
    final online = msg['online'] as bool?;
    if (publicKey == null || online == null) return;

    _peerOnline[publicKey] = online;
    presenceVersion.value++;
    debugPrint('[Relay] Presence: ${publicKey.substring(0, 8)} → ${online ? 'online' : 'offline'}');
  }

  void _handleDeliveryStatus(Map<String, dynamic> msg) {
    final to = msg['to'] as String?;
    final status = msg['status'] as String?;
    if (to == null || status == null) return;
    debugPrint('[Relay] Delivery to ${to.substring(0, 8)}: $status');
  }
}

// ── Models ──────────────────────────────────────────────────────

enum RelayState { disconnected, connecting, connected }

class RelayPeer {
  final String publicKey;
  final String nick;
  final String shortId;
  final bool online;

  const RelayPeer({
    required this.publicKey,
    required this.nick,
    required this.shortId,
    required this.online,
  });
}
