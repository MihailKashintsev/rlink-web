import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/call_service.dart';

class CallScreen extends StatefulWidget {
  final CallSessionInfo session;
  final String peerName;

  const CallScreen({
    super.key,
    required this.session,
    required this.peerName,
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

  @override
  void initState() {
    super.initState();
    _init();
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
        const SnackBar(content: Text('Не удалось получить доступ к микрофону/камере')),
      );
      Navigator.maybeOf(context)?.maybePop();
      return;
    }

    _remoteRenderer.srcObject = CallService.instance.remoteStream;

    _streamListener = () {
      final stream = CallService.instance.remoteStream;
      if (_remoteRenderer.srcObject != stream) {
        _remoteRenderer.srcObject = stream;
        if (mounted) setState(() {});
      }
    };
    CallService.instance.remoteStreamNotifier.addListener(_streamListener!);

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
        child: Column(
          children: [
            const SizedBox(height: 48),
            const CircleAvatar(
              radius: 52,
              backgroundColor: Colors.white12,
              child: Icon(Icons.person, size: 52, color: Colors.white70),
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
                const SizedBox(width: 14),
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
      ),
    );
  }

  Widget _buildVideoCallUi(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _remoteRenderer.srcObject != null
                  ? RTCVideoView(_remoteRenderer)
                  : Center(
                      child: Text(
                        'Соединение с ${widget.peerName}...',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
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
                child: widget.session.videoEnabled
                    ? RTCVideoView(_localRenderer, mirror: true)
                    : const ColoredBox(color: Colors.black54),
              ),
            ),
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
                  if (widget.session.videoEnabled)
                    IconButton.filled(
                      onPressed: () async {
                        _camOn = !_camOn;
                        await CallService.instance.toggleCamera(_camOn);
                        if (mounted) setState(() {});
                      },
                      icon: Icon(_camOn ? Icons.videocam : Icons.videocam_off),
                    ),
                  const SizedBox(width: 12),
                  if (widget.session.videoEnabled)
                    IconButton.filled(
                      tooltip: 'Сменить камеру',
                      onPressed: _camOn
                          ? () async {
                              await CallService.instance.switchCamera();
                            }
                          : null,
                      icon: const Icon(Icons.flip_camera_ios_outlined),
                    ),
                  if (widget.session.videoEnabled) const SizedBox(width: 12),
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
