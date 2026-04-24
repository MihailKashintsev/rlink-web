import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../../models/contact.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/ether_service.dart';
import '../../services/gossip_router.dart';
import '../../services/name_filter.dart';
import '../../services/app_settings.dart';
import '../../services/profile_service.dart';
import 'chat_screen.dart';
import 'location_map_screen.dart';
import '../rlink_nav_routes.dart';

class EtherScreen extends StatefulWidget {
  const EtherScreen({super.key});

  @override
  State<EtherScreen> createState() => _EtherScreenState();
}

class _EtherScreenState extends State<EtherScreen> {
  final _controller = TextEditingController();
  static const _kMaxLen = 60;
  Timer? _refreshTimer;

  static const List<Color> _palette = [
    Color(0xFFFF6B6B),
    Color(0xFF4ECDC4),
    Color(0xFF45B7D1),
    Color(0xFFFF9F43),
    Color(0xFF6C5CE7),
    Color(0xFFA29BFE),
    Color(0xFFFF7675),
    Color(0xFF74B9FF),
    Color(0xFFFD79A8),
    Color(0xFF00B894),
    Color(0xFFE17055),
    Color(0xFF00CEC9),
  ];

  Color _randomColor() => _palette[math.Random().nextInt(_palette.length)];

  @override
  void initState() {
    super.initState();
    EtherService.instance.markRead();
    EtherService.instance.cleanExpired();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AppSettings.instance.etherRulesAccepted) {
        _showRulesDialog();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Checks if text contains any known name (anti-bullying filter).
  /// Uses comprehensive name dictionary + dynamic contacts.
  String? _detectName(String text) {
    return NameFilter.instance.detect(text);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || text.length > _kMaxLen) return;

    // Anti-bullying: block messages that contain any known name
    final detectedName = _detectName(text);
    if (detectedName != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Нельзя упоминать имена в Эфире — это защита от травли',
            style: TextStyle(fontSize: 13),
          ),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    final id = const Uuid().v4();
    final color = _randomColor();
    _controller.clear();

    final profile = ProfileService.instance.profile;
    final opts = EtherBroadcastOptions.instance;
    final senderId = opts.anonymous ? null : profile?.publicKeyHex;
    final senderNick = opts.anonymous ? null : profile?.nickname;

    double? lat;
    double? lng;
    if (opts.attachGeo) {
      lat = opts.customLatitude;
      lng = opts.customLongitude;
      if (lat == null || lng == null) {
        try {
          var perm = await Geolocator.checkPermission();
          if (perm == LocationPermission.denied) {
            perm = await Geolocator.requestPermission();
          }
          if (perm == LocationPermission.denied ||
              perm == LocationPermission.deniedForever) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Нет доступа к геолокации'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          } else {
            final pos = await Geolocator.getCurrentPosition();
            lat = pos.latitude;
            lng = pos.longitude;
          }
        } catch (_) {}
      }
    }

    await GossipRouter.instance.sendEtherMessage(
      text: text,
      color: color.toARGB32(),
      messageId: id,
      senderId: senderId,
      senderNick: senderNick,
      lat: lat,
      lng: lng,
    );

    EtherService.instance.addMessage(EtherMessage(
      id: id,
      text: text,
      color: color.toARGB32(),
      receivedAt: DateTime.now(),
      isOwn: true,
      senderId: senderId,
      senderNick: senderNick,
      latitude: lat,
      longitude: lng,
    ));
  }

  void _openSenderChat(String senderId, String senderNick) async {
    // Ensure contact exists before opening chat
    final contact = await ChatStorageService.instance.getContact(senderId);
    if (contact == null) {
      await ChatStorageService.instance.saveContact(Contact(
        publicKeyHex: senderId,
        nickname: senderNick,
        avatarColor: 0xFF607D8B,
        avatarEmoji: '',
        addedAt: DateTime.now(),
      ));
    }
    if (!mounted) return;
    final c = contact;
    Navigator.push(
      context,
      rlinkChatRoute(
        ChatScreen(
          peerId: senderId,
          peerNickname: c?.nickname ?? senderNick,
          peerAvatarColor: c?.avatarColor ?? 0xFF607D8B,
          peerAvatarEmoji: c?.avatarEmoji ?? '',
          peerAvatarImagePath: c?.avatarImagePath,
        ),
      ),
    );
  }

  Future<void> _showRulesDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, size: 24),
            SizedBox(width: 8),
            Text('Правила Эфира'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                  'Эфир — это общее пространство для всех рядом. Чтобы оно было безопасным, соблюдайте правила:\n'),
              Text('1. Запрещены оскорбления, мат и буллинг',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 4),
              Text('2. Запрещены упоминания имён (защита от травли)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 4),
              Text('3. Запрещены угрозы и призывы к насилию',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 4),
              Text('4. Запрещена реклама и спам',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 4),
              Text('5. Запрещён контент 18+',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 12),
              Text(
                  'Нарушения автоматически фильтруются. Сообщения исчезают через 1 час.',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              AppSettings.instance.setEtherRulesAccepted(true);
              Navigator.pop(ctx);
            },
            child: const Text('Принимаю'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      // Info banner
      ValueListenableBuilder<int>(
        valueListenable: BleService.instance.peersCount,
        builder: (_, count, __) => Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                cs.primary.withValues(alpha: 0.10),
                cs.primary.withValues(alpha: 0.04),
              ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.cell_tower, size: 14, color: cs.primary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: Text(
                  count > 0
                      ? 'Слышат $count ${_peersWord(count)} · исчезает через 1 ч'
                      : 'Никого рядом · сообщения исчезнут через 1 час',
                  key: ValueKey<int>(count),
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 0.1,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),

      // Messages
      Expanded(
        child: ValueListenableBuilder<List<EtherMessage>>(
          valueListenable: EtherService.instance.messages,
          builder: (_, msgs, __) {
            if (msgs.isEmpty) return const _EmptyEther();
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: msgs.length,
              itemBuilder: (_, i) => _AnimatedEtherCard(
                key: ValueKey(msgs[i].id),
                msg: msgs[i],
                index: i,
                onSenderTap: (sid, snick) => _openSenderChat(sid, snick),
              ),
            );
          },
        ),
      ),

      // Input
      _EtherInput(
        controller: _controller,
        maxLen: _kMaxLen,
        onSend: _send,
      ),
    ]);
  }

  String _peersWord(int n) {
    if (n % 100 >= 11 && n % 100 <= 14) return 'устройств';
    switch (n % 10) {
      case 1:
        return 'устройство';
      case 2:
      case 3:
      case 4:
        return 'устройства';
      default:
        return 'устройств';
    }
  }
}

// ── Пустое состояние с анимированным радаром ─────────────────────

class _EmptyEther extends StatefulWidget {
  const _EmptyEther();

  @override
  State<_EmptyEther> createState() => _EmptyEtherState();
}

class _EmptyEtherState extends State<_EmptyEther>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 90,
          height: 90,
          child: AnimatedBuilder(
            animation: _anim,
            builder: (_, child) => CustomPaint(
              painter: _RadarPainter(progress: _anim.value, color: cs.primary),
              child: child,
            ),
            child: Center(
              child: Icon(Icons.cell_tower, size: 36, color: cs.primary),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'В эфире тихо...',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Напиши что-нибудь — все рядом услышат',
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.4),
          ),
        ),
      ]),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _RadarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    for (int i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1.0;
      final radius = phase * maxRadius;
      final alpha = (1.0 - phase) * 0.5;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.progress != progress;
}

// ── Анимированная обертка для карточки ─────────────────────────────

class _AnimatedEtherCard extends StatefulWidget {
  final EtherMessage msg;
  final int index;
  final void Function(String, String) onSenderTap;

  const _AnimatedEtherCard({
    super.key,
    required this.msg,
    required this.index,
    required this.onSenderTap,
  });

  @override
  State<_AnimatedEtherCard> createState() => _AnimatedEtherCardState();
}

class _AnimatedEtherCardState extends State<_AnimatedEtherCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    // Stagger based on index (cap at 5 so late items don't wait too long)
    final delay = Duration(milliseconds: math.min(widget.index, 5) * 60);
    Future.delayed(delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: _EtherCard(
          msg: widget.msg,
          onSenderTap: widget.onSenderTap,
        ),
      ),
    );
  }
}

// ── Карточка сообщения ────────────────────────────────────────────

class _EtherCard extends StatelessWidget {
  final EtherMessage msg;
  final void Function(String senderId, String senderNick) onSenderTap;
  const _EtherCard({required this.msg, required this.onSenderTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = Color(msg.color);
    final isNamed = msg.senderId != null && msg.senderNick != null;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: isDark ? 0.08 : 0.05),
            cs.surfaceContainerHigh.withValues(alpha: isDark ? 0.85 : 0.95),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 4)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.text,
                  style: TextStyle(
                    fontSize: msg.filtered ? 13 : 15,
                    height: 1.4,
                    letterSpacing: 0.1,
                    fontStyle:
                        msg.filtered ? FontStyle.italic : FontStyle.normal,
                    color: msg.filtered
                        ? cs.onSurface.withValues(alpha: 0.4)
                        : cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  // Colored dot with glow
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.5),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (msg.isOwn)
                    Text(
                      'вы',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: color,
                      ),
                    )
                  else if (isNamed)
                    // Тап → открыть чат с отправителем
                    GestureDetector(
                      onTap: () => onSenderTap(msg.senderId!, msg.senderNick!),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                          msg.senderNick!,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                            color: cs.primary,
                            decoration: TextDecoration.underline,
                            decorationColor: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(Icons.arrow_forward_ios_rounded,
                            size: 9, color: cs.primary),
                      ]),
                    )
                  else
                    Text(
                      'аноним',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.3,
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  if (msg.latitude != null &&
                      msg.longitude != null &&
                      !msg.filtered) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        unawaited(
                          showLocationActionsSheet(
                            context,
                            latitude: msg.latitude!,
                            longitude: msg.longitude!,
                          ),
                        );
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.location_on_outlined,
                            size: 12,
                            color: cs.primary.withValues(alpha: 0.7),
                          ),
                          Text(
                            '${msg.latitude!.toStringAsFixed(3)}, ${msg.longitude!.toStringAsFixed(3)}',
                            style: TextStyle(
                              fontSize: 10,
                              color: cs.primary.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(Icons.access_time,
                      size: 11, color: cs.onSurface.withValues(alpha: 0.35)),
                  const SizedBox(width: 3),
                  Text(
                    _relativeTime(msg.receivedAt),
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.2,
                      color: cs.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин';
    return '${diff.inHours} ч';
  }
}

// ── Поле ввода ────────────────────────────────────────────────────

class _EtherInput extends StatefulWidget {
  final TextEditingController controller;
  final int maxLen;
  final VoidCallback onSend;

  const _EtherInput({
    required this.controller,
    required this.maxLen,
    required this.onSend,
  });

  @override
  State<_EtherInput> createState() => _EtherInputState();
}

class _EtherInputState extends State<_EtherInput>
    with SingleTickerProviderStateMixin {
  int _len = 0;
  late AnimationController _sendPulse;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _sendPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    widget.controller.addListener(() =>
        mounted ? setState(() => _len = widget.controller.text.length) : null);
  }

  @override
  void dispose() {
    _sendPulse.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    if (_len == 0 || _len > widget.maxLen) return;
    // Trigger pulse animation then send
    _sendPulse.forward(from: 0.0).then((_) {
      if (mounted) _sendPulse.reverse();
    });
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final over = _len > widget.maxLen;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          border:
              Border(top: BorderSide(color: cs.outline.withValues(alpha: 0.2))),
        ),
        child: ListenableBuilder(
          listenable: EtherBroadcastOptions.instance,
          builder: (context, _) {
            final o = EtherBroadcastOptions.instance;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  o.anonymous
                      ? 'Режим: анонимно'
                      : 'Режим: открыто · ${o.attachGeo ? (o.hasCustomLocation ? "с гео (точка на карте)" : "с гео (текущее положение)") : "без гео"}',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: widget.controller,
                        focusNode: _focusNode,
                        onTapOutside: (_) => _focusNode.unfocus(),
                        maxLines: 3,
                        minLines: 1,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: o.anonymous
                              ? 'Анонимное сообщение...'
                              : 'Сообщение от ${ProfileService.instance.profile?.nickname ?? "вас"}...',
                          hintStyle: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.4),
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_len > 0)
                    Text(
                      '${widget.maxLen - _len}',
                      style: TextStyle(
                        fontSize: 11,
                        color: over
                            ? Colors.red
                            : cs.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: over || _len == 0 ? null : _handleSend,
                    child: AnimatedBuilder(
                      animation: _sendPulse,
                      builder: (_, child) {
                        final scale = 1.0 + (_sendPulse.value * 0.15);
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: over || _len == 0
                              ? cs.onSurface.withValues(alpha: 0.15)
                              : cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.send_rounded,
                            color: cs.onPrimary, size: 20),
                      ),
                    ),
                  ),
                ]),
              ],
            );
          },
        ),
      ),
    );
  }
}
