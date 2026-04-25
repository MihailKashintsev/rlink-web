import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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
///
/// Публичный каталог каналов (отступление от «полного» zero-knowledge):
///   • Клиент шлёт `channel_dir_put` с JSON-телом и Ed25519-подписью (ключ = adminId).
///   • Сервер проверяет подпись, хранит последнюю версию публичных каналов на диске.
///   • При `register` клиент получает `channel_dir_snapshot` — видны id, название,
///     username, universalCode и др. поля из подписанного JSON (метаданные публичного канала).
///   • Лимиты: размер снимка (`_channelDirSnapshotMaxEntries`, сортировка по updatedAt),
///     макс. длина подписываемого JSON (`_channelDirMaxPayloadChars`), отдельный rate limit put по adminId.
///   • `tombstones` в JSON растут при снятии канала с публикации — при необходимости можно
///     чистить старые ключи офлайн-скриптом (клиентам нужны только rev для антистейла).
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

/// Opaque encrypted blobs per Ed25519 identity (список каналов + метаданные синхронизации
/// аккаунта — клиент шифрует, relay не читает содержимое).
final Map<String, String> _accountBlobs = {};

// ── Публичный каталог каналов (подпись админа, персистентность) ──

final Map<String, Map<String, dynamic>> _channelDirectory = {};
/// После удаления канала из каталога — максимальный seen updatedAt (антиретрансляция).
final Map<String, int> _channelDirTombstones = {};
final Ed25519 _ed25519 = Ed25519();

const _channelDirFile = 'channel_directory.json';
const _channelDirMaxPayloadChars = 16384;
const _channelDirSnapshotMaxEntries = 4000;

/// Rate limit отдельно от общего flood: adminId → метки времени put.
final Map<String, List<DateTime>> _channelDirPutLimits = {};
const _channelDirPutWindow = Duration(minutes: 10);
const _channelDirPutMax = 180; // до 180 put на админа за 10 минут

bool _checkChannelDirPutRate(String adminId) {
  final now = DateTime.now();
  final times = _channelDirPutLimits.putIfAbsent(adminId, () => []);
  times.removeWhere((t) => now.difference(t) > _channelDirPutWindow);
  if (times.length >= _channelDirPutMax) return false;
  times.add(now);
  return true;
}

Future<bool> _verifyChannelDirSignature(
  String payloadJson,
  String signatureHex,
  String adminId,
) async {
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(adminId)) return false;
  if (signatureHex.length != 128) return false;
  try {
    final pubBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      pubBytes[i] = int.parse(adminId.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final sigBytes = Uint8List(64);
    for (var i = 0; i < 64; i++) {
      sigBytes[i] = int.parse(signatureHex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final pubKey = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
    return await _ed25519.verify(
      utf8.encode(payloadJson),
      signature: Signature(sigBytes, publicKey: pubKey),
    );
  } catch (_) {
    return false;
  }
}

void _loadChannelDirectory() {
  try {
    final f = File(_channelDirFile);
    if (!f.existsSync()) return;
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map) return;
    final chans = decoded['channels'];
    final tombs = decoded['tombstones'];
    if (chans is Map) {
      chans.forEach((k, v) {
        if (k is String && v is Map) {
          _channelDirectory[k] = Map<String, dynamic>.from(v);
        }
      });
    }
    if (tombs is Map) {
      tombs.forEach((k, v) {
        if (k is String && v is num) {
          _channelDirTombstones[k] = v.toInt();
        }
      });
    }
    stdout.writeln(
      '[RLINK][Relay] Loaded ${_channelDirectory.length} public channel dir entries',
    );
  } catch (e) {
    stdout.writeln('[RLINK][Relay] channel_directory load: $e');
  }
}

void _persistChannelDirectory() {
  try {
    File(_channelDirFile).writeAsStringSync(jsonEncode({
      'channels': _channelDirectory,
      'tombstones': _channelDirTombstones,
    }));
  } catch (e) {
    stdout.writeln('[RLINK][Relay] channel_directory save: $e');
  }
}

int _dirUpdatedAt(Map<String, dynamic> m) =>
    (m['updatedAt'] as num?)?.toInt() ?? 0;

void _sendChannelDirSnapshot(WebSocketChannel ws) {
  if (_channelDirectory.isEmpty) return;
  final entries = _channelDirectory.values.toList();
  entries.sort((a, b) => _dirUpdatedAt(b).compareTo(_dirUpdatedAt(a)));
  final slice = entries.length > _channelDirSnapshotMaxEntries
      ? entries.sublist(0, _channelDirSnapshotMaxEntries)
      : entries;
  try {
    ws.sink.add(jsonEncode({
      'type': 'channel_dir_snapshot',
      'channels': slice,
    }));
    stdout.writeln(
      '[RLINK][Relay] channel_dir_snapshot → ${slice.length} entries',
    );
  } catch (e) {
    stdout.writeln('[RLINK][Relay] channel_dir_snapshot send: $e');
  }
}

void _handleChannelDirPut(_User user, Map<String, dynamic> msg) {
  unawaited(_handleChannelDirPutAsync(user, msg));
}

Future<void> _handleChannelDirPutAsync(
  _User user,
  Map<String, dynamic> msg,
) async {
  final payloadJson = msg['payload'] as String?;
  final signatureHex = msg['signature'] as String?;
  if (payloadJson == null ||
      payloadJson.isEmpty ||
      payloadJson.length > _channelDirMaxPayloadChars) {
    return;
  }
  if (signatureHex == null || signatureHex.length != 128) return;

  Map<String, dynamic> obj;
  try {
    obj = jsonDecode(payloadJson) as Map<String, dynamic>;
  } catch (_) {
    return;
  }

  final channelId = obj['channelId'] as String?;
  final adminId = obj['adminId'] as String?;
  if (channelId == null ||
      channelId.isEmpty ||
      adminId == null ||
      adminId.isEmpty) {
    return;
  }
  if (adminId != user.publicKey) {
    try {
      user.ws.sink.add(jsonEncode({
        'type': 'channel_dir_ack',
        'ok': false,
        'error': 'admin_mismatch',
      }));
    } catch (_) {}
    return;
  }

  if (!_checkChannelDirPutRate(adminId)) {
    try {
      user.ws.sink.add(jsonEncode({
        'type': 'channel_dir_ack',
        'ok': false,
        'error': 'rate_limited',
      }));
    } catch (_) {}
    return;
  }

  final ok =
      await _verifyChannelDirSignature(payloadJson, signatureHex, adminId);
  if (!ok) {
    try {
      user.ws.sink.add(jsonEncode({
        'type': 'channel_dir_ack',
        'ok': false,
        'error': 'bad_signature',
      }));
    } catch (_) {}
    return;
  }

  final updatedAt = _dirUpdatedAt(obj);
  if (updatedAt <= 0) {
    try {
      user.ws.sink.add(jsonEncode({
        'type': 'channel_dir_ack',
        'ok': false,
        'error': 'bad_updatedAt',
      }));
    } catch (_) {}
    return;
  }

  final tomb = _channelDirTombstones[channelId] ?? 0;
  if (updatedAt <= tomb) {
    try {
      user.ws.sink.add(jsonEncode({
        'type': 'channel_dir_ack',
        'ok': false,
        'error': 'stale',
      }));
    } catch (_) {}
    return;
  }

  final isPublic = obj['isPublic'] as bool? ?? true;
  if (!isPublic) {
    _channelDirectory.remove(channelId);
    if (updatedAt > tomb) {
      _channelDirTombstones[channelId] = updatedAt;
    }
    _persistChannelDirectory();
    stdout.writeln(
      '[RLINK][Relay] channel_dir remove $channelId (tombstone $updatedAt)',
    );
    try {
      user.ws.sink.add(jsonEncode({'type': 'channel_dir_ack', 'ok': true}));
    } catch (_) {}
    return;
  }

  final existing = _channelDirectory[channelId];
  if (existing != null) {
    if (updatedAt < _dirUpdatedAt(existing)) {
      try {
        user.ws.sink.add(jsonEncode({
          'type': 'channel_dir_ack',
          'ok': false,
          'error': 'stale',
        }));
      } catch (_) {}
      return;
    }
  }

  _channelDirectory[channelId] = obj;
  _persistChannelDirectory();
  stdout.writeln(
    '[RLINK][Relay] channel_dir put $channelId updatedAt=$updatedAt',
  );
  try {
    user.ws.sink.add(jsonEncode({'type': 'channel_dir_ack', 'ok': true}));
  } catch (_) {}
}

void _loadAccountBlobs() {
  try {
    final f = File('account_blobs.json');
    if (!f.existsSync()) return;
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map) return;
    decoded.forEach((k, v) {
      if (k is String && v is String) _accountBlobs[k] = v;
    });
    stdout.writeln('[RLINK][Relay] Loaded ${_accountBlobs.length} account sync blobs');
  } catch (e) {
    stdout.writeln('[RLINK][Relay] account_blobs load: $e');
  }
}

void _persistAccountBlobs() {
  try {
    File('account_blobs.json').writeAsStringSync(jsonEncode(_accountBlobs));
  } catch (e) {
    stdout.writeln('[RLINK][Relay] account_blobs save: $e');
  }
}

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
  // 100 MB limit for blobs (voice/video/files). Большие файлы клиент
  // всё равно режет на чанки (~90 KB каждый), так что в этот лимит
  // упираются только крупные single-blob сообщения (длинные голосовые,
  // большие single-shot фото/видео без чанкования).
  if (raw.length > 100 * 1024 * 1024) return;

  Map<String, dynamic> msg;
  try {
    msg = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return;
  }

  final type = msg['type'] as String?;
  if (type == null) return;

  // Blobs и каталог каналов не считаем в общий flood лимит (отдельный лимит у put).
  if (type != 'blob' && type != 'channel_dir_put') {
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
    case 'account_sync_put':
      _handleAccountSyncPut(user, msg);
      break;
    case 'channel_dir_put':
      _handleChannelDirPut(user, msg);
      break;
  }
}

/// Клиент кладёт зашифрованный JSON (n/ct/m от ChaCha20), тот же формат что admin_cfg2.
void _handleAccountSyncPut(_User user, Map<String, dynamic> msg) {
  final data = msg['data'] as String?;
  if (data == null || data.isEmpty || data.length > 131072) return;
  _accountBlobs[user.publicKey] = data;
  _persistAccountBlobs();
  try {
    user.ws.sink.add(jsonEncode({'type': 'account_sync_ack', 'ok': true}));
  } catch (_) {}
  print('[RLINK][Relay] account_sync_put ${user.shortId} (${data.length} chars)');
}

void _handlePacket(_User sender, Map<String, dynamic> msg) {
  final toRaw = msg['to'] as String?;
  final data = msg['data'] as String?; // base64-encoded encrypted packet
  if (toRaw == null || data == null) return;
  if (data.length > 262144) return; // 256 KB max (blob chunks double-base64 ~90 KB each)
  final to = toRaw.toLowerCase();

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
  final toRaw = msg['to'] as String?;
  if (toRaw == null) return;
  final to = toRaw.toLowerCase();

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
  // pingInterval=25s включает native WebSocket control-pings (RFC 6455 ping/pong
  // на уровне протокола, не application-level). Браузер отвечает автоматически
  // без JS-таймеров — не подвержен throttling неактивных табов. Это держит WS
  // живым через tuna и другие прокси (обычный idle-timeout 60-120 сек).
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
            final publicKeyRaw = msg['publicKey'] as String?;
            final nick = msg['nick'] as String? ?? '';
            final x25519Key = msg['x25519'] as String? ?? '';
            if (publicKeyRaw == null ||
                !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKeyRaw)) {
              ws.sink.add(jsonEncode({'type': 'error', 'msg': 'invalid_key'}));
              return;
            }
            final publicKey = publicKeyRaw.toLowerCase();

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

            final accBlob = _accountBlobs[publicKey];
            if (accBlob != null && accBlob.isNotEmpty) {
              try {
                ws.sink.add(jsonEncode({
                  'type': 'account_sync_blob',
                  'data': accBlob,
                }));
              } catch (_) {}
            }

            _sendChannelDirSnapshot(ws);

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
          final cc = ws.closeCode;
          final cr = ws.closeReason;
          _users.remove(user!.publicKey);
          _broadcastPresence(user!.publicKey, false);
          final id = user!.nick.isEmpty ? user!.shortId : user!.nick;
          final detail = cc == null
              ? ''
              : ' [closeCode=$cc${cr == null || cr.isEmpty ? '' : ', $cr'}]';
          stdout.writeln('[-] $id disconnected (${_users.length} online)$detail');
        }
      },
      onError: (e) {
        if (user != null) {
          _users.remove(user!.publicKey);
          stdout.writeln('[-] ${user!.shortId} ws error: $e');
        }
      },
    );
  }, pingInterval: const Duration(seconds: 25));
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
  _loadAccountBlobs();
  _loadChannelDirectory();

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
