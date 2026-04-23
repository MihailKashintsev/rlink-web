import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Как в Telegram: короткое нажатие переключает голос ↔ видеоквадратик;
/// удержание — запись, отпускание — отправка; вверх — закрепить; в закрепе — отправка/корзина сверху.
class TelegramMediaRecordButton extends StatefulWidget {
  final bool isSending;
  final bool isRecording;
  final bool isHoldVideoStarting;
  final ColorScheme colorScheme;
  final VoidCallback onVoiceHoldStart;
  final Future<void> Function() onVideoHoldStart;
  final Future<void> Function() onHoldReleaseSend;
  final Future<void> Function() onHoldCancelDiscard;
  /// Вызывается при свайпе вверх в закреп (и для голоса, и для видео).
  final void Function(bool locked)? onHoldLockChanged;
  /// Пауза/продолжение записи видео только в закреплённом режиме.
  final Future<void> Function()? onLockedVideoPauseToggle;
  final ValueListenable<bool>? lockedVideoPausedListenable;

  const TelegramMediaRecordButton({
    super.key,
    required this.isSending,
    required this.isRecording,
    required this.isHoldVideoStarting,
    required this.colorScheme,
    required this.onVoiceHoldStart,
    required this.onVideoHoldStart,
    required this.onHoldReleaseSend,
    required this.onHoldCancelDiscard,
    this.onHoldLockChanged,
    this.onLockedVideoPauseToggle,
    this.lockedVideoPausedListenable,
  });

  @override
  State<TelegramMediaRecordButton> createState() =>
      _TelegramMediaRecordButtonState();
}

class _TelegramMediaRecordButtonState extends State<TelegramMediaRecordButton> {
  static const _holdMs = 280;
  static const _lockDy = -64.0;

  bool _videoMode = false;
  bool _holdActivated = false;
  bool _locked = false;
  Timer? _holdTimer;
  Offset _armDownGlobal = Offset.zero;

  OverlayEntry? _gestureShield;
  OverlayEntry? _lockHud;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _removeGestureShield();
    _removeLockHud();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TelegramMediaRecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRecording && !widget.isRecording) {
      _locked = false;
      _holdActivated = false;
      _holdTimer?.cancel();
      _removeGestureShield();
      _removeLockHud();
    }
  }

  void _removeGestureShield() {
    _gestureShield?.remove();
    _gestureShield = null;
  }

  void _removeLockHud() {
    _lockHud?.remove();
    _lockHud = null;
  }

  void _insertGestureShield() {
    if (_gestureShield != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _gestureShield = OverlayEntry(
      builder: (ctx) {
        return Material(
          type: MaterialType.transparency,
          child: SizedBox.expand(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerMove: _onGlobalMove,
              onPointerUp: _onGlobalUp,
              onPointerCancel: _onGlobalUp,
            ),
          ),
        );
      },
    );
    overlay.insert(_gestureShield!);
  }

  void _showLockHud() {
    if (_lockHud != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final cs = widget.colorScheme;
    _lockHud = OverlayEntry(
      builder: (ctx) {
        Widget? pauseBtn;
        if (_videoMode &&
            widget.onLockedVideoPauseToggle != null &&
            widget.lockedVideoPausedListenable != null) {
          pauseBtn = ValueListenableBuilder<bool>(
            valueListenable: widget.lockedVideoPausedListenable!,
            builder: (_, paused, __) {
              return IconButton(
                tooltip: paused ? 'Продолжить' : 'Пауза',
                icon: Icon(
                  paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  color: cs.onSurface,
                ),
                onPressed: () => unawaited(widget.onLockedVideoPauseToggle!()),
              );
            },
          );
        }
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(28),
                color: cs.surfaceContainerHigh,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _videoMode ? Icons.videocam_rounded : Icons.mic_rounded,
                        size: 22,
                        color: cs.onSurface,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _videoMode ? 'Видео' : 'Голосовое',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (pauseBtn != null) pauseBtn,
                      IconButton(
                        tooltip: 'Отправить',
                        icon: Icon(Icons.send_rounded, color: cs.primary),
                        onPressed: () => unawaited(_onLockedSend()),
                      ),
                      IconButton(
                        tooltip: 'Удалить',
                        icon: Icon(Icons.delete_outline, color: cs.error),
                        onPressed: () => unawaited(_onLockedCancel()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_lockHud!);
  }

  Future<void> _onLockedSend() async {
    await widget.onHoldReleaseSend();
    if (!mounted) return;
    _removeLockHud();
    setState(() {
      _locked = false;
      _holdActivated = false;
    });
  }

  Future<void> _onLockedCancel() async {
    await widget.onHoldCancelDiscard();
    if (!mounted) return;
    _removeLockHud();
    setState(() {
      _locked = false;
      _holdActivated = false;
    });
  }

  void _onHoldTimerFire() {
    if (!mounted || widget.isSending) return;
    _holdActivated = true;
    _insertGestureShield();
    if (_videoMode) {
      unawaited(widget.onVideoHoldStart());
    } else {
      widget.onVoiceHoldStart();
    }
  }

  void _onButtonPointerDown(PointerDownEvent e) {
    if (widget.isSending || widget.isHoldVideoStarting) return;
    if (widget.isRecording && _locked) return;

    _armDownGlobal = e.position;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: _holdMs), _onHoldTimerFire);
  }

  void _onButtonPointerUp(PointerUpEvent e) => _onButtonShortTapEnd();

  void _onButtonShortTapEnd() {
    _holdTimer?.cancel();
    if (!_holdActivated) {
      if (widget.isRecording || widget.isHoldVideoStarting) return;
      setState(() => _videoMode = !_videoMode);
    }
  }

  void _onGlobalMove(PointerMoveEvent e) {
    if (!_holdActivated || _locked || !widget.isRecording) return;
    final dy = e.position.dy - _armDownGlobal.dy;
    if (dy < _lockDy) {
      HapticFeedback.mediumImpact();
      setState(() => _locked = true);
      widget.onHoldLockChanged?.call(true);
      _removeGestureShield();
      _showLockHud();
    }
  }

  void _onGlobalUp(PointerEvent e) {
    _holdTimer?.cancel();
    if (!_holdActivated) {
      _removeGestureShield();
      return;
    }
    if (_locked) {
      _removeGestureShield();
      return;
    }
    unawaited(_completeHoldOnRelease());
  }

  Future<void> _completeHoldOnRelease() async {
    if (widget.isHoldVideoStarting) {
      for (var i = 0; i < 125; i++) {
        await Future.delayed(const Duration(milliseconds: 40));
        if (!mounted) return;
        if (!widget.isHoldVideoStarting) break;
      }
    }
    if (!mounted) return;
    if (widget.isHoldVideoStarting) {
      await widget.onHoldCancelDiscard();
      _removeGestureShield();
      return;
    }
    if (!widget.isRecording) {
      _removeGestureShield();
      return;
    }
    await widget.onHoldReleaseSend();
    if (mounted) _removeGestureShield();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;
    final busy = widget.isHoldVideoStarting;

    return Tooltip(
      message: _videoMode
          ? 'Короткое нажатие — голос; удерживайте для видеокружка'
          : 'Короткое нажатие — видео; удерживайте для голоса',
      child: Listener(
        onPointerDown: _onButtonPointerDown,
        onPointerUp: _onButtonPointerUp,
        onPointerCancel: (_) => _onButtonShortTapEnd(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: widget.isRecording ? Colors.redAccent : cs.primary,
            shape: BoxShape.circle,
          ),
          child: busy
              ? Padding(
                  padding: const EdgeInsets.all(11),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onPrimary,
                  ),
                )
              : Icon(
                  widget.isRecording
                      ? Icons.fiber_manual_record
                      : (_videoMode
                          ? Icons.videocam_rounded
                          : Icons.mic_rounded),
                  color: cs.onPrimary,
                  size: 22,
                ),
        ),
      ),
    );
  }
}
