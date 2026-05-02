import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/call_service.dart';
import '../widgets/avatar_widget.dart';

class CallScreen extends StatefulWidget {
  final CallSessionInfo session;
  final String peerName;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;

  const CallScreen({
    super.key,
    required this.session,
    required this.peerName,
    this.peerAvatarColor = 0xFF5C6BC0,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _micOn = true;
  bool _camOn = true;
  VoidCallback? _phaseListener;
  VoidCallback? _streamListener;
  VoidCallback? _remoteGenListener;

  /// В видеозвонке: true — большой кадр собеседника, false — большой свой.
  bool _mainShowsPeer = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  String _initials(String name) {
    final t = name.trim();
    if (t.isEmpty) return '?';
    return t.substring(0, 1).toUpperCase();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    if (!mounted) return;
    await _remoteRenderer.initialize();
    if (!mounted) return;

    try {
      if (widget.session.incoming) {
        await CallService.instance.acceptIncoming(widget.session);
        if (!mounted) return;
      }
      final local = await CallService.instance.getLocalStream();
      if (!mounted) return;
      _localRenderer.srcObject = local;
    } catch (e) {
      debugPrint('[CallScreen] _init error: $e');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
            content: Text('Не удалось получить доступ к микрофону/камере')),
      );
      Navigator.maybeOf(context)?.maybePop();
      return;
    }

    _bindRemoteRenderer();

    _streamListener = _bindRemoteRenderer;
    CallService.instance.remoteStreamNotifier.addListener(_streamListener!);

    _remoteGenListener = _bindRemoteRenderer;
    CallService.instance.remoteStreamGeneration.addListener(_remoteGenListener!);

    _phaseListener = () {
      if (!mounted) return;
      final phase = CallService.instance.phase.value;
      if (phase == CallPhase.failed || phase == CallPhase.ended) {
        if (phase == CallPhase.failed) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Соединение не удалось')),
          );
        }
        Navigator.maybeOf(context)?.maybePop();
      }
    };
    CallService.instance.phase.addListener(_phaseListener!);
    if (mounted) setState(() {});
  }

  void _bindRemoteRenderer() {
    final stream = CallService.instance.remoteStream;
    if (_remoteRenderer.srcObject != stream) {
      _remoteRenderer.srcObject = stream;
    } else if (stream != null) {
      // Новый трек в том же MediaStream — перепривязываем рендерер.
      _remoteRenderer.srcObject = null;
      _remoteRenderer.srcObject = stream;
    }
    if (mounted) setState(() {});
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _callTopOverlay() {
    return Positioned(
      left: 12,
      right: 12,
      top: 8,
      child: Row(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: CallService.instance.peerIsRecording,
            builder: (_, rec, __) {
              if (!rec) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
                    SizedBox(width: 6),
                    Text(
                      'Идёт запись',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const Spacer(),
          ValueListenableBuilder<bool>(
            valueListenable: CallService.instance.localRecording,
            builder: (_, rec, __) {
              if (!rec) return const SizedBox.shrink();
              return ValueListenableBuilder<Duration>(
                valueListenable: CallService.instance.recordingElapsed,
                builder: (_, recElapsed, __) {
                  return Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
                        const SizedBox(width: 6),
                        Text(
                          _formatElapsed(recElapsed),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          ValueListenableBuilder<Duration>(
            valueListenable: CallService.instance.callElapsed,
            builder: (_, elapsed, __) {
              if (elapsed == Duration.zero) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _formatElapsed(elapsed),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _recordControl() {
    return ValueListenableBuilder<bool>(
      valueListenable: CallService.instance.localRecording,
      builder: (_, rec, __) {
        return IconButton.filled(
          tooltip: rec ? 'Остановить запись' : 'Записать звонок',
          style: IconButton.styleFrom(
            backgroundColor: rec ? Colors.red.shade800 : null,
          ),
          onPressed: () async {
            await CallService.instance.setCallRecording(!rec);
            if (mounted) setState(() {});
          },
          icon: Icon(rec ? Icons.stop_circle_outlined : Icons.fiber_manual_record),
        );
      },
    );
  }

  @override
  void dispose() {
    if (_phaseListener != null) {
      CallService.instance.phase.removeListener(_phaseListener!);
      _phaseListener = null;
    }
    if (_streamListener != null) {
      CallService.instance.remoteStreamNotifier.removeListener(_streamListener!);
      _streamListener = null;
    }
    if (_remoteGenListener != null) {
      CallService.instance.remoteStreamGeneration.removeListener(_remoteGenListener!);
      _remoteGenListener = null;
    }
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _end() async {
    await CallService.instance.endCall();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.session.videoEnabled) {
      return _buildAudioCallUi(context);
    }
    return _buildVideoCallUi(context);
  }

  Widget _buildAudioCallUi(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 40),
                AvatarWidget(
                  initials: _initials(widget.peerName),
                  color: widget.peerAvatarColor,
                  emoji: widget.peerAvatarEmoji,
                  imagePath: widget.peerAvatarImagePath,
                  size: 112,
                ),
                const SizedBox(height: 18),
                Text(
                  widget.peerName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<CallPhase>(
                  valueListenable: CallService.instance.phase,
                  builder: (_, phase, __) {
                    final label = switch (phase) {
                      CallPhase.ringing when widget.session.incoming =>
                        'Входящий звонок',
                      CallPhase.ringing => 'Ждём ответа...',
                      CallPhase.connecting => 'Соединение...',
                      CallPhase.connected => 'Аудиозвонок',
                      CallPhase.failed => 'Соединение не удалось',
                      CallPhase.ended => 'Звонок завершён',
                      CallPhase.idle => 'Звонок',
                    };
                    return Text(
                      label,
                      style: const TextStyle(color: Colors.white60, fontSize: 14),
                    );
                  },
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filled(
                      onPressed: () async {
                        _micOn = !_micOn;
                        await CallService.instance.toggleMic(_micOn);
                        if (mounted) setState(() {});
                      },
                      icon: Icon(_micOn ? Icons.mic : Icons.mic_off),
                    ),
                    const SizedBox(width: 10),
                    if (!kIsWeb) _recordControl(),
                    if (!kIsWeb) const SizedBox(width: 10),
                    IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: _end,
                      icon: const Icon(Icons.call_end),
                    ),
                  ],
                ),
                const SizedBox(height: 42),
              ],
            ),
            _callTopOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCallUi(BuildContext context) {
    final hasRemote = _remoteRenderer.srcObject != null;
    final mainRemote = _mainShowsPeer;

    Widget bigTile(RTCVideoRenderer r, {bool mirror = false}) {
      final isLocal = identical(r, _localRenderer);
      final showVideo = isLocal || hasRemote;
      final child = showVideo
          ? RTCVideoView(r, mirror: mirror)
          : Center(
              child: Text(
                'Соединение с ${widget.peerName}...',
                style: const TextStyle(color: Colors.white70),
              ),
            );
      return Material(
        color: Colors.black,
        child: InkWell(
          onTap: () => setState(() => _mainShowsPeer = !_mainShowsPeer),
          child: SizedBox.expand(child: child),
        ),
      );
    }

    final bigRemote = bigTile(_remoteRenderer, mirror: false);
    final smallRemote = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: bigTile(_remoteRenderer, mirror: false),
    );
    final bigLocal = bigTile(_localRenderer, mirror: true);
    final smallLocal = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: bigTile(_localRenderer, mirror: true),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: mainRemote ? bigRemote : bigLocal,
            ),
            Positioned(
              right: 12,
              top: 12,
              width: 120,
              height: 180,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                clipBehavior: Clip.antiAlias,
                child: mainRemote ? smallLocal : smallRemote,
              ),
            ),
            _callTopOverlay(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filled(
                    onPressed: () async {
                      _micOn = !_micOn;
                      await CallService.instance.toggleMic(_micOn);
                      if (mounted) setState(() {});
                    },
                    icon: Icon(_micOn ? Icons.mic : Icons.mic_off),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    onPressed: () async {
                      _camOn = !_camOn;
                      await CallService.instance.toggleCamera(_camOn);
                      if (mounted) setState(() {});
                    },
                    icon: Icon(_camOn ? Icons.videocam : Icons.videocam_off),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    tooltip: 'Сменить камеру',
                    onPressed: _camOn
                        ? () async {
                            await CallService.instance.switchCamera();
                          }
                        : null,
                    icon: const Icon(Icons.flip_camera_ios_outlined),
                  ),
                  if (!kIsWeb) const SizedBox(width: 12),
                  if (!kIsWeb) _recordControl(),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _end,
                    icon: const Icon(Icons.call_end),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
