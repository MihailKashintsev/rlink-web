import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import 'avatar_widget.dart';

// ── Peer position on radar ──────────────────────────────────────

class _PeerRadarInfo {
  final String peerId;
  final double angle;    // radians — stable position from key hash
  final double distance; // 0.0 (center) to 1.0 (edge)
  final Contact? contact;
  const _PeerRadarInfo({
    required this.peerId,
    required this.angle,
    required this.distance,
    this.contact,
  });
}

// ── Main Radar Widget ───────────────────────────────────────────

class MeshRadarWidget extends StatefulWidget {
  final void Function(String peerId, String nickname, int color,
      String emoji, String? imagePath)? onPeerTap;

  const MeshRadarWidget({super.key, this.onPeerTap});

  @override
  State<MeshRadarWidget> createState() => _MeshRadarWidgetState();
}

class _MeshRadarWidgetState extends State<MeshRadarWidget>
    with TickerProviderStateMixin {
  late final AnimationController _sweepCtrl;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _sweepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _sweepCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  List<_PeerRadarInfo> _computePositions(
      List<String> peers, List<Contact> contacts) {
    final positions = <_PeerRadarInfo>[];
    for (final peerId in peers) {
      // Stable angle from public key hash
      final hash = peerId.hashCode;
      final angle = (hash.abs() % 3600) / 3600.0 * 2 * math.pi;

      // Distance from RSSI
      final rssi = BleService.instance.getRssi(peerId);
      double distance;
      if (rssi != null) {
        // Map RSSI: -30 (very close) → 0.15, -90 (far) → 0.85
        distance = ((rssi.abs() - 30) / 60.0).clamp(0.15, 0.85);
      } else {
        // Default: middle zone with slight variation from hash
        distance = 0.35 + (hash.abs() % 100) / 250.0;
      }

      // Resolve contact
      final resolvedKey = BleService.instance.resolvePublicKey(peerId);
      Contact? contact;
      for (final c in contacts) {
        if (c.publicKeyHex == resolvedKey || c.publicKeyHex == peerId) {
          contact = c;
          break;
        }
      }

      positions.add(_PeerRadarInfo(
        peerId: peerId,
        angle: angle,
        distance: distance,
        contact: contact,
      ));
    }
    return positions;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return ValueListenableBuilder<int>(
      valueListenable: BleService.instance.peerMappingsVersion,
      builder: (_, __, ___) => ValueListenableBuilder<int>(
        valueListenable: BleService.instance.peersCount,
        builder: (_, __, ___) => ValueListenableBuilder<List<Contact>>(
          valueListenable: ChatStorageService.instance.contactsNotifier,
          builder: (_, contacts, __) {
            final peers = BleService.instance.connectedPeerIds
                .where(
                    (id) => !BleService.instance.isPeerProfilePending(id))
                .toList();
            final positions = _computePositions(peers, contacts);

            return LayoutBuilder(
              builder: (context, constraints) {
                final availW = constraints.maxWidth;
                final availH = constraints.maxHeight;
                final radarDiam =
                    math.min(availW, availH - 40).clamp(200.0, 600.0);
                final centerX = availW / 2;
                final centerY = (availH - 30) / 2;
                final radius = radarDiam / 2 - 24;

                return Stack(
                  children: [
                    // Radar background + sweep
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _sweepCtrl,
                        builder: (_, __) => CustomPaint(
                          painter: _RadarPainter(
                            sweepAngle: _sweepCtrl.value * 2 * math.pi,
                            center: Offset(centerX, centerY),
                            radius: radius,
                            accent: accent,
                          ),
                        ),
                      ),
                    ),

                    // Peer blips
                    ...positions.map((pos) {
                      final x = centerX +
                          math.cos(pos.angle) * pos.distance * radius;
                      final y = centerY +
                          math.sin(pos.angle) * pos.distance * radius;
                      return _PeerBlip(
                        key: ValueKey('blip_${pos.peerId}'),
                        position: Offset(x, y),
                        info: pos,
                        sweepCtrl: _sweepCtrl,
                        pulseCtrl: _pulseCtrl,
                        accent: accent,
                        onTap: () => _onBlipTap(pos),
                      );
                    }),

                    // Center «ME» dot
                    Positioned(
                      left: centerX - 22,
                      top: centerY - 22,
                      child: AnimatedBuilder(
                        animation: _pulseCtrl,
                        builder: (_, child) => Transform.scale(
                          scale: 1.0 + _pulseCtrl.value * 0.08,
                          child: child,
                        ),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent,
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.45),
                                blurRadius: 14,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Center(
                            child: Icon(Icons.person,
                                color: Colors.white, size: 22),
                          ),
                        ),
                      ),
                    ),

                    // Pending peers pulsing on outer ring
                    ValueListenableBuilder<Set<String>>(
                      valueListenable: BleService.instance.pendingProfiles,
                      builder: (_, pending, __) {
                        if (pending.isEmpty) return const SizedBox.shrink();
                        final pendingList = pending.toList();
                        return Stack(
                          children: List.generate(pendingList.length, (i) {
                            final angle = (i * 2 * math.pi / pendingList.length) +
                                math.pi / 4;
                            final px =
                                centerX + math.cos(angle) * radius * 0.92;
                            final py =
                                centerY + math.sin(angle) * radius * 0.92;
                            return _PendingBlip(
                              position: Offset(px, py),
                              pulseCtrl: _pulseCtrl,
                              accent: accent,
                            );
                          }),
                        );
                      },
                    ),

                    // Status label
                    Positioned(
                      bottom: 4,
                      left: 0,
                      right: 0,
                      child: Text(
                        peers.isEmpty
                            ? 'Сканирование mesh-сети...'
                            : '${peers.length} ${_plural(peers.length)} в сети',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  void _onBlipTap(_PeerRadarInfo pos) {
    final c = pos.contact;
    final btName = BleService.instance.getDeviceName(pos.peerId);
    widget.onPeerTap?.call(
      pos.peerId,
      c?.nickname ?? btName,
      c?.avatarColor ?? 0xFF607D8B,
      c?.avatarEmoji ?? '',
      c?.avatarImagePath,
    );
  }

  static String _plural(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'устройство';
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) {
      return 'устройства';
    }
    return 'устройств';
  }
}

// ── Radar background painter ────────────────────────────────────

class _RadarPainter extends CustomPainter {
  final double sweepAngle;
  final Offset center;
  final double radius;
  final Color accent;

  _RadarPainter({
    required this.sweepAngle,
    required this.center,
    required this.radius,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Concentric rings
    final ringPaint = Paint()
      ..color = accent.withValues(alpha: 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (int i = 1; i <= 3; i++) {
      canvas.drawCircle(center, radius * i / 3, ringPaint);
    }

    // Cross-hair lines
    final crossPaint = Paint()
      ..color = accent.withValues(alpha: 0.05)
      ..strokeWidth = 0.5;

    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      crossPaint,
    );
    // Diagonals
    final d = radius * 0.707;
    canvas.drawLine(
      Offset(center.dx - d, center.dy - d),
      Offset(center.dx + d, center.dy + d),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx + d, center.dy - d),
      Offset(center.dx - d, center.dy + d),
      crossPaint,
    );

    // Sweep gradient trail
    final trailAngle = math.pi / 3; // 60° trail
    canvas.save();
    canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: center, radius: radius)));

    final trailPaint = Paint()
      ..shader = ui.Gradient.sweep(
        center,
        [accent.withValues(alpha: 0.0), accent.withValues(alpha: 0.12)],
        [0.0, 1.0],
        TileMode.clamp,
        sweepAngle - trailAngle,
        sweepAngle,
      );
    canvas.drawRect(
        Rect.fromCircle(center: center, radius: radius), trailPaint);
    canvas.restore();

    // Sweep line
    final sweepEnd = Offset(
      center.dx + math.cos(sweepAngle) * radius,
      center.dy + math.sin(sweepAngle) * radius,
    );
    final sweepPaint = Paint()
      ..color = accent.withValues(alpha: 0.5)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, sweepEnd, sweepPaint);

    // Distance labels
    final labelStyle = TextStyle(
      color: accent.withValues(alpha: 0.25),
      fontSize: 9,
    );
    _drawText(canvas, '~1m',
        Offset(center.dx + 4, center.dy - radius / 3 - 12), labelStyle);
    _drawText(canvas, '~5m',
        Offset(center.dx + 4, center.dy - radius * 2 / 3 - 12), labelStyle);
    _drawText(canvas, '~10m',
        Offset(center.dx + 4, center.dy - radius - 12), labelStyle);
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      sweepAngle != old.sweepAngle || accent != old.accent;
}

// ── Peer blip (avatar + glow + label) ───────────────────────────

class _PeerBlip extends StatelessWidget {
  final Offset position;
  final _PeerRadarInfo info;
  final AnimationController sweepCtrl;
  final AnimationController pulseCtrl;
  final Color accent;
  final VoidCallback onTap;

  const _PeerBlip({
    super.key,
    required this.position,
    required this.info,
    required this.sweepCtrl,
    required this.pulseCtrl,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const double blipSize = 44.0;
    final c = info.contact;
    final btName = BleService.instance.getDeviceName(info.peerId);
    final name = c?.nickname ?? btName;
    final blipColor = Color(c?.avatarColor ?? 0xFF607D8B);

    return Positioned(
      left: position.dx - blipSize / 2,
      top: position.dy - blipSize / 2 - 8, // offset for label below
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 600),
        curve: Curves.elasticOut,
        builder: (_, scale, child) => Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: scale.clamp(0.0, 1.0),
            child: child,
          ),
        ),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedBuilder(
            animation: Listenable.merge([pulseCtrl, sweepCtrl]),
            builder: (_, __) {
              // Flash when sweep passes over this blip
              final sweepAngle = sweepCtrl.value * 2 * math.pi;
              var angleDiff =
                  ((sweepAngle - info.angle) % (2 * math.pi)).abs();
              if (angleDiff > math.pi) angleDiff = 2 * math.pi - angleDiff;
              final flash =
                  angleDiff < 0.3 ? (1.0 - angleDiff / 0.3) * 0.4 : 0.0;

              final glowAlpha =
                  0.3 + pulseCtrl.value * 0.15 + flash;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: blipSize,
                    height: blipSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: blipColor.withValues(
                              alpha: glowAlpha.clamp(0.0, 1.0)),
                          blurRadius: 8 + flash * 12,
                          spreadRadius: 1 + flash * 3,
                        ),
                      ],
                    ),
                    child: AvatarWidget(
                      initials:
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                      color: c?.avatarColor ?? 0xFF607D8B,
                      emoji: c?.avatarEmoji ?? '',
                      imagePath: c?.avatarImagePath,
                      size: blipSize,
                      isOnline: true,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      name.length > 10
                          ? '${name.substring(0, 10)}…'
                          : name,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Pending (loading profile) blip ──────────────────────────────

class _PendingBlip extends StatelessWidget {
  final Offset position;
  final AnimationController pulseCtrl;
  final Color accent;

  const _PendingBlip({
    required this.position,
    required this.pulseCtrl,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 12,
      top: position.dy - 12,
      child: AnimatedBuilder(
        animation: pulseCtrl,
        builder: (_, __) {
          final scale = 0.8 + pulseCtrl.value * 0.4;
          final alpha = 0.3 + pulseCtrl.value * 0.3;
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: alpha),
                border: Border.all(
                  color: accent.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: const Center(
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
