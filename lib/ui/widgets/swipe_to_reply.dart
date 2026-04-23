import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Свайп пузыря к центру экрана (как в Telegram) — [onReply].
///
/// Входящие слева: тянем вправо. Исходящие справа: тянем влево.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.isOutgoing,
    required this.onReply,
    required this.child,
  });

  final bool isOutgoing;
  final VoidCallback onReply;
  final Widget child;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  static const double _max = 52;
  static const double _trigger = 34;
  /// Во время [dispose] у [State] поле [mounted] ещё true — без флага анимация
  /// может вызвать [setState] и сломать дерево (`_elements.contains(element)`).
  bool _tearDown = false;

  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<double>? _tween;
  VoidCallback? _tweenListener;

  @override
  void dispose() {
    _tearDown = true;
    _snap.stop();
    if (_tweenListener != null) {
      _tween?.removeListener(_tweenListener!);
      _tweenListener = null;
    }
    _tween = null;
    _snap.dispose();
    super.dispose();
  }

  void _beginSnap(double from) {
    if (_tearDown) return;
    _snap.stop();
    if (_tweenListener != null) {
      _tween?.removeListener(_tweenListener!);
      _tweenListener = null;
    }
    _tween = Tween<double>(begin: from, end: 0).animate(
      CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic),
    );
    _tweenListener = () {
      if (_tearDown || !mounted) return;
      setState(() => _dx = _tween!.value);
    };
    _tween!.addListener(_tweenListener!);
    _snap.forward(from: 0);
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_tearDown) return;
    _snap.stop();
    if (_tweenListener != null) {
      _tween?.removeListener(_tweenListener!);
      _tweenListener = null;
    }
    setState(() {
      if (widget.isOutgoing) {
        _dx = (_dx + d.delta.dx).clamp(-_max, 0);
      } else {
        _dx = (_dx + d.delta.dx).clamp(0, _max);
      }
    });
  }

  void _onEnd(DragEndDetails d) {
    if (_tearDown) return;
    final vx = d.velocity.pixelsPerSecond.dx;
    final distOk =
        widget.isOutgoing ? _dx <= -_trigger : _dx >= _trigger;
    final flickOk = widget.isOutgoing ? vx < -700 : vx > 700;
    if (distOk || flickOk) {
      HapticFeedback.lightImpact();
      widget.onReply();
    }
    _beginSnap(_dx);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = (_dx.abs() / _max).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      onHorizontalDragCancel: () {
        if (!_tearDown) _beginSnap(_dx);
      },
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Align(
            alignment: widget.isOutgoing
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Opacity(
                opacity: t * 0.9,
                child: Icon(
                  Icons.reply_rounded,
                  size: 28,
                  color: cs.primary.withValues(alpha: 0.85 + 0.15 * t),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_dx, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
