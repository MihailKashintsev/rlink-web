import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../../services/ai_bot_constants.dart';
import '../../services/app_settings.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/relay_service.dart';

// ─── Pure-Dart SHA-256 (no external package needed) ────────────────
String sha256Hex(String input) => _sha256Digest(utf8.encode(input));

String _sha256Digest(List<int> data) {
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

  const k = <int>[
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
  ];

  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  final bitLen = data.length * 8;
  final padded = List<int>.from(data)..add(0x80);
  while (padded.length % 64 != 56) { padded.add(0); }
  for (var i = 56; i >= 0; i -= 8) { padded.add((bitLen >> i) & 0xFF); }

  for (var offset = 0; offset < padded.length; offset += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (padded[offset + i * 4] << 24) |
             (padded[offset + i * 4 + 1] << 16) |
             (padded[offset + i * 4 + 2] << 8) |
             padded[offset + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3);
      final s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10);
      w[i] = (w[i-16] + s0 + w[i-7] + s1) & 0xFFFFFFFF;
    }

    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (h + s1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;
      h = g; g = f; f = e; e = (d + temp1) & 0xFFFFFFFF;
      d = c; c = b; b = a; a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF; h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF; h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF; h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF; h7 = (h7 + h) & 0xFFFFFFFF;
  }

  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${hex(h0)}${hex(h1)}${hex(h2)}${hex(h3)}${hex(h4)}${hex(h5)}${hex(h6)}${hex(h7)}';
}

// ─── Admin Screen ──────────────────────────────────────────────────

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _searchCtrl = TextEditingController();
  String _query = '';
  List<_RelayAdminBot> _relayBots = const [];
  bool _relayBotsLoading = false;
  bool _includeRevokedBots = false;
  String? _relayBotsError;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    ChannelService.instance.loadVerificationRequests();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
    unawaited(_loadRelayBots());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Сменить пароль',
            onPressed: _changePassword,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.verified_outlined), text: 'Заявки'),
            Tab(icon: Icon(Icons.tv_outlined), text: 'Каналы'),
            Tab(icon: Icon(Icons.smart_toy_outlined), text: 'Боты'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Поиск...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _searchCtrl.clear(),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildRequestsTab(),
                _buildChannelsTab(),
                _buildBotsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Tab 1: Verification Requests ─────────────────────────────
  Widget _buildRequestsTab() {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<VerificationRequest>>(
      valueListenable: ChannelService.instance.pendingVerifications,
      builder: (_, requests, __) {
        final filtered = _query.isEmpty
            ? requests
            : requests.where((r) {
                final q = _query;
                return r.channelName.toLowerCase().contains(q) ||
                    (r.description ?? '').toLowerCase().contains(q) ||
                    r.adminId.toLowerCase().contains(q);
              }).toList();

        if (filtered.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_outlined,
                    size: 64, color: cs.primary.withValues(alpha: 0.3)),
                const SizedBox(height: 16),
                Text(
                  requests.isEmpty
                      ? 'Нет запросов на верификацию'
                      : 'Ничего не найдено',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          itemCount: filtered.length,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemBuilder: (_, i) => _RequestTile(
            request: filtered[i],
            onApprove: () => _approve(filtered[i]),
            onReject: () => _reject(filtered[i]),
          ),
        );
      },
    );
  }

  // ── Tab 2: All Channels (foreign agent / block / delete) ─────
  Widget _buildChannelsTab() {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: ChannelService.instance.version,
      builder: (_, __, ___) {
        return FutureBuilder<List<Channel>>(
          future: ChannelService.instance.getChannels(),
          builder: (_, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snap.data!;
            final filtered = _query.isEmpty
                ? all
                : all.where((c) {
                    final q = _query;
                    return c.name.toLowerCase().contains(q) ||
                        (c.description ?? '').toLowerCase().contains(q) ||
                        c.adminId.toLowerCase().contains(q) ||
                        c.universalCode.toLowerCase().contains(q);
                  }).toList();

            if (filtered.isEmpty) {
              return Center(
                child: Text(
                  all.isEmpty ? 'Нет каналов' : 'Ничего не найдено',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              );
            }

            return ListView.builder(
              itemCount: filtered.length,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (_, i) => _ChannelAdminTile(
                channel: filtered[i],
                onToggleForeignAgent: () =>
                    _toggleForeignAgent(filtered[i]),
                onToggleBlock: () => _toggleBlock(filtered[i]),
                onDelete: () => _deleteChannel(filtered[i]),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBotsTab() {
    final cs = Theme.of(context).colorScheme;
    final enabled = AppSettings.instance.enabledBotIds.toSet();
    final builtins = _query.isEmpty
        ? kBuiltinAiBots
        : kBuiltinAiBots
            .where((b) =>
                b.name.toLowerCase().contains(_query) ||
                b.description.toLowerCase().contains(_query))
            .toList();
    final relayFiltered = _query.isEmpty
        ? _relayBots
        : _relayBots.where((b) => b.matches(_query)).toList();

    return RefreshIndicator(
      onRefresh: _loadRelayBots,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const Icon(Icons.settings_ethernet_outlined),
            title: const Text('Relay-боты (админ)'),
            subtitle: Text(_relayBotsError ??
                'Поиск по @нику, названию и полному botId (64 hex).'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('revoked'),
                Switch(
                  value: _includeRevokedBots,
                  onChanged: (v) async {
                    setState(() => _includeRevokedBots = v);
                    await _loadRelayBots();
                  },
                ),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: _relayBotsLoading ? null : () => unawaited(_loadRelayBots()),
                  icon: _relayBotsLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          if (relayFiltered.isEmpty && !_relayBotsLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _relayBotsError != null ? 'Ошибка загрузки списка ботов' : 'Релей-боты не найдены',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            )
          else
            ...relayFiltered.map((b) => _RelayBotAdminTile(
                  bot: b,
                  onToggleVerified: () => _updateRelayBot(botId: b.botId, verified: !b.verified),
                  onToggleBlocked: () => _updateRelayBot(botId: b.botId, blocked: !b.blocked),
                  onRevoke: () => _confirmAndRevokeRelayBot(b),
                )),
          const Divider(height: 26),
          const ListTile(
            leading: Icon(Icons.smart_toy_outlined),
            title: Text('Встроенные боты приложения'),
            subtitle: Text('Локальный переключатель Lib/GigaChat'),
          ),
          ...builtins.map((bot) {
            final isEnabled = enabled.contains(bot.id);
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SwitchListTile(
                value: isEnabled,
                secondary: CircleAvatar(
                  backgroundColor: Color(bot.avatarColor),
                  child: Text(bot.avatarEmoji, style: const TextStyle(fontSize: 18)),
                ),
                title: Text(
                  bot.name,
                  style:
                      const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                subtitle: Text(bot.description),
                onChanged: (_) => _toggleBot(bot.id),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Actions ──────────────────────────────────────────────────
  Future<void> _approve(VerificationRequest req) async {
    final myKey = CryptoService.instance.publicKeyHex;
    await GossipRouter.instance.sendVerificationApproval(
      channelId: req.channelId,
      verifiedBy: myKey,
    );
    await ChannelService.instance.verifyChannel(req.channelId, myKey);
    await ChannelService.instance.removeVerificationRequest(req.channelId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${req.channelName} верифицирован')),
      );
    }
  }

  Future<void> _reject(VerificationRequest req) async {
    await ChannelService.instance.removeVerificationRequest(req.channelId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${req.channelName} отклонён')),
      );
    }
  }

  Future<void> _toggleForeignAgent(Channel ch) async {
    final newValue = !ch.foreignAgent;
    final myKey = CryptoService.instance.publicKeyHex;
    await ChannelService.instance.setForeignAgent(ch.id, newValue);
    await GossipRouter.instance.sendChannelForeignAgent(
      channelId: ch.id,
      value: newValue,
      byAdmin: myKey,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(newValue
            ? '${ch.name}: помечен как ИНОАГЕНТ'
            : '${ch.name}: метка ИНОАГЕНТ снята'),
      ));
    }
  }

  Future<void> _toggleBlock(Channel ch) async {
    final newValue = !ch.blocked;
    final myKey = CryptoService.instance.publicKeyHex;
    await ChannelService.instance.setBlocked(ch.id, newValue);
    await GossipRouter.instance.sendChannelBlock(
      channelId: ch.id,
      value: newValue,
      byAdmin: myKey,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(newValue
            ? '${ch.name}: заблокирован'
            : '${ch.name}: разблокирован'),
      ));
    }
  }

  Future<void> _deleteChannel(Channel ch) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить канал?'),
        content: Text(
            'Канал "${ch.name}" будет удалён у всех по уникальному коду '
            '${ch.universalCode.isNotEmpty ? ch.universalCode : ch.id.substring(0, 8)}… '
            '(не по имени). Действие необратимо.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final myKey = CryptoService.instance.publicKeyHex;
    await GossipRouter.instance.sendChannelAdminDelete(
      channelId: ch.id,
      byAdmin: myKey,
      universalCode: ch.universalCode,
    );
    await ChannelService.instance.deleteChannel(ch.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${ch.name} удалён')),
      );
    }
  }

  Future<void> _toggleBot(String botId) async {
    final current = AppSettings.instance.enabledBotIds.toSet();
    if (current.contains(botId)) {
      current.remove(botId);
    } else {
      current.add(botId);
    }
    await AppSettings.instance.setEnabledBotIds(current.toList());
    await _publishAdminSync();
    if (mounted) setState(() {});
  }

  Future<void> _loadRelayBots() async {
    if (_relayBotsLoading) return;
    setState(() {
      _relayBotsLoading = true;
      _relayBotsError = null;
    });
    try {
      final data = await RelayService.instance.sendAdminBotList(
        adminHash: AppSettings.instance.adminPasswordHash,
        query: _query,
        includeRevoked: _includeRevokedBots,
      );
      if (data['ok'] != true) {
        throw Exception(data['error']?.toString() ?? 'request_failed');
      }
      final raw = data['bots'];
      final out = <_RelayAdminBot>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            out.add(_RelayAdminBot.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }
      if (!mounted) return;
      setState(() => _relayBots = out);
    } catch (e) {
      if (!mounted) return;
      setState(() => _relayBotsError = e.toString());
    } finally {
      if (mounted) setState(() => _relayBotsLoading = false);
    }
  }

  Future<void> _updateRelayBot({
    required String botId,
    bool? verified,
    bool? blocked,
    bool revoke = false,
  }) async {
    try {
      final ack = await RelayService.instance.sendAdminBotUpdate(
        adminHash: AppSettings.instance.adminPasswordHash,
        botId: botId,
        verified: verified,
        blocked: blocked,
        revoke: revoke,
      );
      if (ack['ok'] != true) {
        throw Exception(ack['error']?.toString() ?? 'request_failed');
      }
      await _loadRelayBots();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Параметры бота обновлены')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _confirmAndRevokeRelayBot(_RelayAdminBot bot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить бота из relay?'),
        content: Text(
          'Бот @${bot.handle} (${bot.botId.substring(0, 12)}...) будет отозван. '
          'Доступы будут закрыты, владельцу придётся пересоздать бота.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _updateRelayBot(botId: bot.botId, revoke: true);
  }

  Future<void> _publishAdminSync() async {
    final hash = AppSettings.instance.adminPasswordHash;
    final curRev = AppSettings.instance.adminPasswordSyncRev;
    final rev = curRev + 1;
    final myId = CryptoService.instance.publicKeyHex;
    final chans = myId.isEmpty
        ? <String>[]
        : await ChannelService.instance.subscribedChannelIdsForAccountSync(myId);
    final bots = AppSettings.instance.enabledBotIds;
    final inner = jsonEncode({
      'hash': hash,
      'rev': rev,
      'chans': chans,
      'bots': bots,
    });
    final sealed = await CryptoService.instance.sealAdminPanelSync(inner);
    await AppSettings.instance.bumpAccountSyncRevisionOnly(rev, sealed);
    await GossipRouter.instance.sendAdminConfigSecure(
      adminPasswordHash: hash,
      revision: rev,
      channelIds: chans,
      botIds: bots,
    );
    await RelayService.instance.putAccountSyncBlob(sealed);
  }

  void _changePassword() {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сменить пароль'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Текущий пароль',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Новый пароль',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Подтвердите пароль',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final oldHash = sha256Hex(oldCtrl.text);
              if (oldHash != AppSettings.instance.adminPasswordHash) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Неверный текущий пароль'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              if (newCtrl.text.isEmpty) return;
              if (newCtrl.text != confirmCtrl.text) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Пароли не совпадают'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              final newHash = sha256Hex(newCtrl.text);
              final rev = DateTime.now().millisecondsSinceEpoch;
              final myId = CryptoService.instance.publicKeyHex;
              final chans = myId.isEmpty
                  ? <String>[]
                  : await ChannelService.instance
                      .subscribedChannelIdsForAccountSync(myId);
              final bots = AppSettings.instance.enabledBotIds;
              final inner = jsonEncode({
                'hash': newHash,
                'rev': rev,
                'chans': chans,
                'bots': bots,
              });
              final sealed =
                  await CryptoService.instance.sealAdminPanelSync(inner);
              await AppSettings.instance
                  .completeAdminPasswordRollout(newHash, rev, sealed);
              await GossipRouter.instance.sendAdminConfigSecure(
                adminPasswordHash: newHash,
                revision: rev,
                channelIds: chans,
                botIds: bots,
              );
              await RelayService.instance.putAccountSyncBlob(sealed);
              if (ctx.mounted) Navigator.pop(ctx);
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Пароль изменён — зашифрованная синхронизация с вашими устройствами',
                  ),
                ),
              );
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  final VerificationRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _RequestTile({
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final date = DateTime.fromMillisecondsSinceEpoch(request.requestedAt);
    final dateStr =
        '${date.day}.${date.month.toString().padLeft(2, '0')}.${date.year}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: Text(request.avatarEmoji,
                      style: const TextStyle(fontSize: 20)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(request.channelName,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16)),
                      Text('${request.subscriberCount} подписчиков',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                Text(dateStr,
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
            if (request.description != null &&
                request.description!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(request.description!,
                  style:
                      TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            ],
            const SizedBox(height: 4),
            Text(
                'Admin: ${request.adminId.length > 16 ? "${request.adminId.substring(0, 16)}..." : request.adminId}',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  child: const Text('Отклонить',
                      style: TextStyle(color: Colors.red)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.verified, size: 18),
                  label: const Text('Верифицировать'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RelayAdminBot {
  final String botId;
  final String handle;
  final String displayName;
  final String ownerEd25519Pub;
  final String description;
  final bool verified;
  final bool blocked;
  final bool revoked;

  const _RelayAdminBot({
    required this.botId,
    required this.handle,
    required this.displayName,
    required this.ownerEd25519Pub,
    required this.description,
    required this.verified,
    required this.blocked,
    required this.revoked,
  });

  bool matches(String q) {
    final x = q.toLowerCase();
    return botId.toLowerCase().contains(x) ||
        handle.toLowerCase().contains(x) ||
        displayName.toLowerCase().contains(x) ||
        ownerEd25519Pub.toLowerCase().contains(x) ||
        description.toLowerCase().contains(x);
  }

  factory _RelayAdminBot.fromJson(Map<String, dynamic> j) {
    return _RelayAdminBot(
      botId: (j['botId'] as String? ?? '').toLowerCase(),
      handle: j['handle'] as String? ?? '',
      displayName: j['displayName'] as String? ?? '',
      ownerEd25519Pub: (j['ownerEd25519Pub'] as String? ?? '').toLowerCase(),
      description: j['description'] as String? ?? '',
      verified: j['verified'] == true,
      blocked: j['blocked'] == true,
      revoked: j['revoked'] == true,
    );
  }
}

class _RelayBotAdminTile extends StatelessWidget {
  final _RelayAdminBot bot;
  final VoidCallback onToggleVerified;
  final VoidCallback onToggleBlocked;
  final VoidCallback onRevoke;

  const _RelayBotAdminTile({
    required this.bot,
    required this.onToggleVerified,
    required this.onToggleBlocked,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  child: Icon(Icons.smart_toy_outlined),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@${bot.handle} — ${bot.displayName}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bot.botId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (bot.description.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                bot.description.trim(),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Owner: ${bot.ownerEd25519Pub}',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (bot.verified) _chip('VERIFIED', Colors.blue),
                if (bot.blocked) _chip('BLOCKED', Colors.red),
                if (bot.revoked) _chip('REVOKED', Colors.red.shade900),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: bot.revoked ? null : onToggleVerified,
                  icon: Icon(
                    bot.verified ? Icons.verified : Icons.verified_outlined,
                    size: 16,
                  ),
                  label: Text(bot.verified ? 'Снять галочку' : 'Выдать галочку'),
                ),
                OutlinedButton.icon(
                  onPressed: bot.revoked ? null : onToggleBlocked,
                  icon: Icon(
                    bot.blocked ? Icons.lock_open : Icons.block,
                    size: 16,
                    color: bot.blocked ? Colors.red : null,
                  ),
                  label: Text(bot.blocked ? 'Разблокировать' : 'Блокировать'),
                ),
                FilledButton.icon(
                  onPressed: bot.revoked ? null : onRevoke,
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Удалить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _ChannelAdminTile extends StatelessWidget {
  final Channel channel;
  final VoidCallback onToggleForeignAgent;
  final VoidCallback onToggleBlock;
  final VoidCallback onDelete;

  const _ChannelAdminTile({
    required this.channel,
    required this.onToggleForeignAgent,
    required this.onToggleBlock,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Color(channel.avatarColor),
                  child: Text(channel.avatarEmoji,
                      style: const TextStyle(fontSize: 20)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(channel.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16)),
                          ),
                          if (channel.verified) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.verified,
                                size: 16, color: cs.primary),
                          ],
                        ],
                      ),
                      Text('${channel.subscriberIds.length} подписчиков',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(
                        'Код: ${channel.universalCode.isNotEmpty ? channel.universalCode : "—"} · id ${channel.id.length >= 8 ? channel.id.substring(0, 8) : channel.id}…',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (channel.foreignAgent || channel.blocked) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  if (channel.foreignAgent)
                    _chip('ИНОАГЕНТ', Colors.orange),
                  if (channel.blocked) _chip('ЗАБЛОКИРОВАН', Colors.red),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: onToggleForeignAgent,
                  icon: Icon(Icons.flag_outlined,
                      size: 16,
                      color:
                          channel.foreignAgent ? Colors.orange : null),
                  label: Text(
                    channel.foreignAgent ? 'Снять ИА' : 'ИНОАГЕНТ',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onToggleBlock,
                  icon: Icon(Icons.block,
                      size: 16,
                      color: channel.blocked ? Colors.red : null),
                  label: Text(
                    channel.blocked ? 'Разблок.' : 'Блок.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8)),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Удалить',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
