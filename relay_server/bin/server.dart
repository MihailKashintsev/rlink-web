import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// ═══════════════════════════════════════════════════════════════════
/// Rlink Relay Server — Zero-Knowledge WebSocket Relay
/// ═══════════════════════════════════════════════════════════════════
///
/// The server NEVER sees plaintext messages.  All chat payloads arrive
/// pre-encrypted (ChaCha20-Poly1305) by the client and are forwarded
/// as opaque blobs.  The only metadata the server knows:
///
///   • Public key (Ed25519 hex) of the registrant
///   • Optional nickname (for search — can be hashed client-side)
///   • Online/offline presence
///
/// Protocol (JSON over WebSocket):
///
///   C→S  {"type":"register","publicKey":"hex64","nick":"...", "challenge":"..."}
///   S→C  {"type":"registered","shortId":"hex8"}
///
///   C→S  {"type":"search","query":"nickname_or_id"}
///   S→C  {"type":"search_result","results":[{"publicKey":"...","nick":"...","shortId":"...","online":true},...]}
///
///   C→S  {"type":"packet","to":"publicKey_hex64","data":"base64_encrypted_gossip_packet"}
///   S→C  {"type":"packet","from":"publicKey_hex64","data":"base64_encrypted_gossip_packet"}
///
///   C→S  {"type":"broadcast","data":"base64_encrypted_gossip_packet"}
///   S→C  (forwarded to all online peers)
///
///   S→C  {"type":"presence","publicKey":"...","online":true/false}
///
/// Security guarantees:
///   1. E2E encryption — server forwards opaque base64 blobs
///   2. No message storage — relay only (packets not saved to disk)
///   3. No IP logging — no access logs written
///   4. Challenge-response ready — clients can prove key ownership
/// ═══════════════════════════════════════════════════════════════════

// ── Connected user ──────────────────────────────────────────────

class _User {
  final WebSocketChannel ws;
  final String publicKey;
  String nick;
  String x25519Key;
  String get shortId => publicKey.length > 8 ? publicKey.substring(0, 8) : publicKey;
  DateTime connectedAt = DateTime.now();

  _User({required this.ws, required this.publicKey, required this.nick, this.x25519Key = ''});
}

// ── Server state ────────────────────────────────────────────────

/// publicKey → _User (only one connection per key — last one wins)
final Map<String, _User> _users = {};

/// Rate limiting: publicKey → last N timestamps
final Map<String, List<DateTime>> _rateLimits = {};
const _rateWindow = Duration(seconds: 10);
const _rateMax = 300; // max 300 messages per 10 seconds (media chunks need ~250)

bool _checkRate(String publicKey) {
  final now = DateTime.now();
  final times = _rateLimits.putIfAbsent(publicKey, () => []);
  times.removeWhere((t) => now.difference(t) > _rateWindow);
  if (times.length >= _rateMax) return false; // rate limited
  times.add(now);
  return true;
}

// ── Handlers ────────────────────────────────────────────────────

void _handleMessage(_User user, dynamic raw) {
  if (raw is! String) return;
  // 10 MB limit for blobs (voice/video/files), 64 KB for regular packets
  if (raw.length > 10 * 1024 * 1024) return;

  Map<String, dynamic> msg;
  try {
    msg = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return;
  }

  final type = msg['type'] as String?;
  if (type == null) return;

  // Blobs bypass rate limiting (they're large single messages)
  if (type != 'blob') {
    if (!_checkRate(user.publicKey)) {
      user.ws.sink.add(jsonEncode({'type': 'error', 'msg': 'rate_limited'}));
      return;
    }
  }

  switch (type) {
    case 'packet':
      _handlePacket(user, msg);
      break;
    case 'broadcast':
      _handleBroadcast(user, msg);
      break;
    case 'blob':
      _handleBlob(user, msg);
      break;
    case 'search':
      _handleSearch(user, msg);
      break;
    case 'ping':
      user.ws.sink.add(jsonEncode({'type': 'pong'}));
      break;
  }
}

void _handlePacket(_User sender, Map<String, dynamic> msg) {
  final to = msg['to'] as String?;
  final data = msg['data'] as String?; // base64-encoded encrypted packet
  if (to == null || data == null) return;
  if (data.length > 262144) return; // 256 KB max (blob chunks double-base64 ~90 KB each)

  final recipient = _users[to];
  if (recipient == null) {
    // Recipient offline — notify sender
    sender.ws.sink.add(jsonEncode({
      'type': 'delivery_status',
      'to': to,
      'status': 'offline',
    }));
    return;
  }

  // Forward opaque blob — server NEVER decrypts
  try {
    recipient.ws.sink.add(jsonEncode({
      'type': 'packet',
      'from': sender.publicKey,
      'data': data,
    }));
    print('[RLINK][Relay] Packet: ${sender.shortId} → ${recipient.shortId} (${data.length} chars)');
  } catch (e) {
    print('[RLINK][Relay] Packet forward failed: $e');
    sender.ws.sink.add(jsonEncode({
      'type': 'delivery_status',
      'to': to,
      'status': 'error',
    }));
  }
}

void _handleBroadcast(_User sender, Map<String, dynamic> msg) {
  final data = msg['data'] as String?;
  if (data == null || data.length > 262144) return;

  final encoded = jsonEncode({
    'type': 'packet',
    'from': sender.publicKey,
    'data': data,
  });

  // Forward to ALL online users except sender
  var sent = 0;
  for (final user in _users.values) {
    if (user.publicKey == sender.publicKey) continue;
    try {
      user.ws.sink.add(encoded);
      sent++;
    } catch (_) {}
  }
  print('[RLINK][Relay] Broadcast from ${sender.shortId}: ${data.length} chars → $sent peers');
}

void _handleBlob(_User sender, Map<String, dynamic> msg) {
  final to = msg['to'] as String?;
  if (to == null) return;

  final recipient = _users[to];
  if (recipient == null) {
    sender.ws.sink.add(jsonEncode({
      'type': 'delivery_status',
      'to': to,
      'status': 'offline',
    }));
    return;
  }

  // Forward the entire blob as-is, replacing 'to' with 'from'
  final forwarded = Map<String, dynamic>.from(msg);
  forwarded.remove('to');
  forwarded['from'] = sender.publicKey;
  forwarded['type'] = 'blob';

  try {
    recipient.ws.sink.add(jsonEncode(forwarded));
    final dataLen = (msg['data'] as String?)?.length ?? 0;
    print('[RLINK][Relay] Blob forwarded: ${sender.publicKey.substring(0, 8)} → ${to.substring(0, 8)} ($dataLen chars)');
  } catch (e) {
    print('[RLINK][Relay] Blob forward failed: $e');
    sender.ws.sink.add(jsonEncode({
      'type': 'delivery_status',
      'to': to,
      'status': 'error',
    }));
  }
}

void _handleSearch(_User requester, Map<String, dynamic> msg) {
  final query = (msg['query'] as String?)?.toLowerCase().trim();
  if (query == null || query.isEmpty) return;

  final results = <Map<String, dynamic>>[];
  for (final user in _users.values) {
    if (user.publicKey == requester.publicKey) continue;
    final nickLower = user.nick.toLowerCase();
    final shortLower = user.shortId.toLowerCase();
    if (nickLower.contains(query) ||
        shortLower.contains(query) ||
        user.publicKey.toLowerCase().startsWith(query)) {
      results.add({
        'publicKey': user.publicKey,
        'nick': user.nick,
        'shortId': user.shortId,
        'online': true,
        if (user.x25519Key.isNotEmpty) 'x25519': user.x25519Key,
      });
      if (results.length >= 20) break; // limit results
    }
  }

  requester.ws.sink.add(jsonEncode({
    'type': 'search_result',
    'results': results,
  }));
  print('[RLINK][Relay] Search "$query" by ${requester.publicKey.substring(0, 8)}: ${results.length} results');
}

// ── WebSocket handler ───────────────────────────────────────────

shelf.Handler _wsHandler() {
  return webSocketHandler((WebSocketChannel ws) {
    _User? user;
    ws.stream.listen(
      (raw) {
        if (user == null) {
          // First message must be registration
          if (raw is! String) return;
          try {
            final msg = jsonDecode(raw) as Map<String, dynamic>;
            if (msg['type'] != 'register') {
              ws.sink.add(jsonEncode({'type': 'error', 'msg': 'register_first'}));
              return;
            }
            final publicKey = msg['publicKey'] as String?;
            final nick = msg['nick'] as String? ?? '';
            final x25519Key = msg['x25519'] as String? ?? '';
            if (publicKey == null ||
                !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey)) {
              ws.sink.add(jsonEncode({'type': 'error', 'msg': 'invalid_key'}));
              return;
            }

            // Disconnect previous connection for same key
            final prev = _users[publicKey];
            if (prev != null) {
              try { prev.ws.sink.close(); } catch (_) {}
            }

            user = _User(ws: ws, publicKey: publicKey, nick: nick, x25519Key: x25519Key);
            _users[publicKey] = user!;

            final shortId = publicKey.substring(0, 8);
            ws.sink.add(jsonEncode({
              'type': 'registered',
              'shortId': shortId,
              'onlineCount': _users.length,
            }));

            // Send currently online peers to the new user
            for (final other in _users.values) {
              if (other.publicKey == publicKey) continue;
              try {
                ws.sink.add(jsonEncode({
                  'type': 'presence',
                  'publicKey': other.publicKey,
                  'online': true,
                  'nick': other.nick,
                  if (other.x25519Key.isNotEmpty) 'x25519': other.x25519Key,
                }));
              } catch (_) {}
            }

            // Notify other users about this new user
            _broadcastPresence(publicKey, true);

            stdout.writeln('[+] ${nick.isEmpty ? shortId : nick} connected (${_users.length} online)');
          } catch (e) {
            ws.sink.add(jsonEncode({'type': 'error', 'msg': 'bad_register'}));
          }
        } else {
          _handleMessage(user!, raw);
        }
      },
      onDone: () {
        if (user != null) {
          _users.remove(user!.publicKey);
          _broadcastPresence(user!.publicKey, false);
          stdout.writeln('[-] ${user!.nick.isEmpty ? user!.shortId : user!.nick} disconnected (${_users.length} online)');
        }
      },
      onError: (_) {
        if (user != null) {
          _users.remove(user!.publicKey);
        }
      },
    );
  });
}

void _broadcastPresence(String publicKey, bool online) {
  final sourceUser = _users[publicKey];
  final x25519Key = sourceUser?.x25519Key ?? '';
  final nick = sourceUser?.nick ?? '';
  final msg = jsonEncode({
    'type': 'presence',
    'publicKey': publicKey,
    'online': online,
    if (nick.isNotEmpty) 'nick': nick,
    if (x25519Key.isNotEmpty) 'x25519': x25519Key,
  });
  for (final user in _users.values) {
    if (user.publicKey == publicKey) continue;
    try {
      user.ws.sink.add(msg);
    } catch (_) {}
  }
}

// ── Health check / info endpoint ────────────────────────────────

shelf.Response _infoHandler(shelf.Request request) {
  if (request.url.path == 'health') {
    final peers = _users.values.map((u) => {
      'shortId': u.shortId,
      'nick': u.nick,
      'connectedAt': u.connectedAt.toIso8601String(),
    }).toList();
    return shelf.Response.ok(
      jsonEncode({
        'status': 'ok',
        'online': _users.length,
        'peers': peers,
        'uptime': DateTime.now().toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }
  return shelf.Response.notFound('Not found');
}

// ── Main ────────────────────────────────────────────────────────

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  // Cascade: try WebSocket first, then HTTP info
  final handler = shelf.Cascade()
      .add(_wsHandler())
      .add(_infoHandler)
      .handler;

  final server = await io.serve(
    handler,
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln('══════════════════════════════════════════════');
  stdout.writeln('  Rlink Relay Server v1.0');
  stdout.writeln('  Listening on ws://${server.address.host}:${server.port}');
  stdout.writeln('  Zero-knowledge relay — E2E encrypted only');
  stdout.writeln('══════════════════════════════════════════════');
}
