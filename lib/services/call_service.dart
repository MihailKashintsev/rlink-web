import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';
import 'gossip_router.dart';
import 'chat_storage_service.dart';
import 'notification_service.dart';
import 'sound_effects_service.dart';

enum CallPhase { idle, ringing, connecting, connected, ended, failed }

class CallSessionInfo {
  final String callId;
  final String peerId;
  final bool incoming;
  final bool videoEnabled;
  final bool audioEnabled;

  const CallSessionInfo({
    required this.callId,
    required this.peerId,
    required this.incoming,
    required this.videoEnabled,
    required this.audioEnabled,
  });
}

class CallService {
  CallService._();
  static final CallService instance = CallService._();

  static const _turnHost = String.fromEnvironment('TURN_HOST', defaultValue: '');
  static const _turnUser = String.fromEnvironment('TURN_USER', defaultValue: '');
  static const _turnPassword =
      String.fromEnvironment('TURN_PASSWORD', defaultValue: '');

  final _uuid = const Uuid();
  final ValueNotifier<CallSessionInfo?> incomingCall = ValueNotifier(null);
  final ValueNotifier<CallPhase> phase = ValueNotifier(CallPhase.idle);

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final Map<String, dynamic> _pendingOffers = <String, dynamic>{};
  final Map<String, List<Map<String, dynamic>>> _pendingIce =
      <String, List<Map<String, dynamic>>>{};
  Map<String, dynamic>? _lastLocalOffer;
  String? _activeCallId;
  String? _activePeerId;
  bool _videoEnabled = true;
  bool _acceptedAwaitingOffer = false;
  Timer? _connectTimeout;

  MediaStream? remoteStream;

  bool get isBusy =>
      phase.value == CallPhase.ringing ||
      phase.value == CallPhase.connecting ||
      phase.value == CallPhase.connected;

  Map<String, dynamic> _iceConfig() {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ];
    final host = _turnHost.trim();
    final user = _turnUser.trim();
    final pass = _turnPassword.trim();
    if (host.isNotEmpty && user.isNotEmpty && pass.isNotEmpty) {
      servers.addAll(<Map<String, dynamic>>[
        {
          'urls': <String>[
            'turn:$host:3478?transport=udp',
            'turn:$host:3478?transport=tcp',
          ],
          'username': user,
          'credential': pass,
        },
        {
          'urls': <String>['turns:$host:5349?transport=tcp'],
          'username': user,
          'credential': pass,
        },
      ]);
    }
    return <String, dynamic>{'iceServers': servers};
  }

  void bindSignaling() {
    GossipRouter.instance.onCallSignal = _onSignal;
  }

  Future<CallSessionInfo> startOutgoing({
    required String peerId,
    required bool video,
  }) async {
    if (isBusy) {
      throw StateError('busy');
    }
    final callId = _uuid.v4();
    _activeCallId = callId;
    _activePeerId = peerId;
    _videoEnabled = video;
    await SoundEffectsService.instance.stopIncomingRingtone();
    // Show "ringing" while waiting for callee to accept.
    // Transitions to connecting when 'accept' signal arrives.
    phase.value = CallPhase.ringing;
    await _ensurePeerConnection();
    await _ensureLocalStream();

    await _sendSignal(peerId, callId, 'invite', {
      'video': video,
      'audio': true,
    });
    await _createAndSendOffer();
    _armConnectTimeout();

    return CallSessionInfo(
      callId: callId,
      peerId: peerId,
      incoming: false,
      videoEnabled: video,
      audioEnabled: true,
    );
  }

  Future<void> acceptIncoming(CallSessionInfo session) async {
    final isIncomingRinging =
        phase.value == CallPhase.ringing && incomingCall.value?.callId == session.callId;
    if (isBusy && !isIncomingRinging && _activeCallId != session.callId) {
      throw StateError('busy');
    }
    _activeCallId = session.callId;
    _activePeerId = session.peerId;
    _videoEnabled = session.videoEnabled;
    await SoundEffectsService.instance.stopIncomingRingtone();
    phase.value = CallPhase.connecting;

    await _ensurePeerConnection();
    await _ensureLocalStream();
    await _sendSignal(session.peerId, session.callId, 'accept');
    _armConnectTimeout();

    final offer = _pendingOffers.remove(session.callId);
    if (offer is! Map<String, dynamic>) {
      // Offer can arrive after user taps "accept"; keep session pending.
      _acceptedAwaitingOffer = true;
      incomingCall.value = null;
      return;
    }
    await _applyOfferAndAnswer(session.callId, session.peerId, offer);
    incomingCall.value = null;
  }

  Future<void> _applyOfferAndAnswer(
    String callId,
    String peerId,
    Map<String, dynamic> offer,
  ) async {
    final sdp = offer['sdp'] as String?;
    final type = offer['type'] as String?;
    if (sdp != null && type != null) {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
      await _flushPendingIce(callId);
    }
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    await _sendSignal(peerId, callId, 'answer', {
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  Future<void> rejectIncoming(CallSessionInfo session) async {
    await _sendSignal(session.peerId, session.callId, 'reject');
    incomingCall.value = null;
  }

  Future<void> endCall() async {
    final peer = _activePeerId;
    final callId = _activeCallId;
    if (peer != null && callId != null) {
      await _sendSignal(peer, callId, 'end');
    }
    await _cleanup(CallPhase.ended);
  }

  Future<void> toggleMic(bool enabled) async {
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> toggleCamera(bool enabled) async {
    _videoEnabled = enabled;
    for (final t
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  Future<MediaStream?> getLocalStream() async {
    await _ensureLocalStream();
    return _localStream;
  }

  Future<void> _createAndSendOffer() async {
    final pc = _pc;
    final peerId = _activePeerId;
    final callId = _activeCallId;
    if (pc == null || peerId == null || callId == null) return;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    final payload = <String, dynamic>{
      'sdp': offer.sdp,
      'type': offer.type,
    };
    _lastLocalOffer = payload;
    await _sendSignal(peerId, callId, 'offer', payload);
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) return;
    final pc = await createPeerConnection(_iceConfig());
    _pc = pc;

    pc.onIceCandidate = (candidate) async {
      final peerId = _activePeerId;
      final callId = _activeCallId;
      if (peerId == null || callId == null || candidate.candidate == null) {
        return;
      }
      await _sendSignal(peerId, callId, 'ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteStream = event.streams.first;
        _connectTimeout?.cancel();
        phase.value = CallPhase.connected;
        unawaited(SoundEffectsService.instance.playAction(ActionSound.callConnected));
      }
    };

    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_cleanup(CallPhase.failed));
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(_cleanup(CallPhase.ended));
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectTimeout?.cancel();
        phase.value = CallPhase.connected;
        unawaited(SoundEffectsService.instance.playAction(ActionSound.callConnected));
      }
    };
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    final media = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': _videoEnabled,
    });
    _localStream = media;
    final pc = _pc;
    if (pc != null) {
      for (final track in media.getTracks()) {
        await pc.addTrack(track, media);
      }
    }
  }

  Future<void> _onSignal(
    String fromId,
    String callId,
    String signalType,
    Map<String, dynamic> payload,
  ) async {
    switch (signalType) {
      case 'invite':
        if (isBusy && _activeCallId != callId) {
          await _sendSignal(fromId, callId, 'busy');
          break;
        }
        final contact = await ChatStorageService.instance.getContact(fromId);
        final displayName = (contact?.nickname.trim().isNotEmpty ?? false)
            ? contact!.nickname.trim()
            : (fromId.length >= 8 ? '${fromId.substring(0, 8)}...' : fromId);
        final isVideo = payload['video'] == true;
        unawaited(
          NotificationService.instance.showPersonalMessage(
            peerId: fromId,
            title: displayName,
            body: isVideo ? 'Видеозвонок' : 'Аудиозвонок',
          ),
        );
        final info = CallSessionInfo(
          callId: callId,
          peerId: fromId,
          incoming: true,
          videoEnabled: isVideo,
          audioEnabled: payload['audio'] != false,
        );
        incomingCall.value = info;
        phase.value = CallPhase.ringing;
        unawaited(SoundEffectsService.instance.startIncomingRingtone());
        break;
      case 'offer':
        _pendingOffers[callId] = payload;
        if (_acceptedAwaitingOffer &&
            _activeCallId == callId &&
            _activePeerId == fromId &&
            _pc != null) {
          _acceptedAwaitingOffer = false;
          await _applyOfferAndAnswer(callId, fromId, payload);
        }
        break;
      case 'accept':
        // Callee accepted — move to connecting phase, then resend offer.
        if (_activeCallId == callId && _activePeerId == fromId) {
          phase.value = CallPhase.connecting;
          if (_lastLocalOffer != null) {
            await _sendSignal(fromId, callId, 'offer', _lastLocalOffer!);
          }
        }
        break;
      case 'answer':
        if (_pc != null) {
          final sdp = payload['sdp'] as String?;
          final type = payload['type'] as String?;
          if (sdp != null && type != null) {
            await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
            await _flushPendingIce(callId);
          }
        }
        break;
      case 'ice':
        final candidate = payload['candidate'] as String?;
        final sdpMid = payload['sdpMid'] as String?;
        final sdpMLineIndex = (payload['sdpMLineIndex'] as num?)?.toInt();
        final icePayload = <String, dynamic>{
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
        };
        final pc = _pc;
        if (pc == null) {
          _pendingIce
              .putIfAbsent(callId, () => <Map<String, dynamic>>[])
              .add(icePayload);
          break;
        }
        try {
          await _addIceCandidate(icePayload);
        } catch (_) {
          _pendingIce
              .putIfAbsent(callId, () => <Map<String, dynamic>>[])
              .add(icePayload);
        }
        break;
      case 'reject':
      case 'busy':
      case 'end':
        await _cleanup(CallPhase.ended);
        break;
    }
  }

  Future<void> _sendSignal(
    String recipientId,
    String callId,
    String signalType, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    await GossipRouter.instance.sendCallSignal(
      fromId: myId,
      recipientId: recipientId,
      callId: callId,
      signalType: signalType,
      payload: payload,
    );
  }

  Future<void> _cleanup(CallPhase endPhase) async {
    await SoundEffectsService.instance.stopIncomingRingtone();
    _connectTimeout?.cancel();
    _connectTimeout = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      await remoteStream?.dispose();
    } catch (_) {}
    remoteStream = null;
    _activeCallId = null;
    _activePeerId = null;
    _lastLocalOffer = null;
    _acceptedAwaitingOffer = false;
    _pendingOffers.clear();
    _pendingIce.clear();
    phase.value = endPhase;
  }

  void _armConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 25), () {
      if (phase.value == CallPhase.connected ||
          phase.value == CallPhase.ended) {
        return;
      }
      unawaited(_cleanup(CallPhase.failed));
    });
  }

  Future<void> _flushPendingIce(String callId) async {
    final list = _pendingIce.remove(callId);
    if (list == null || list.isEmpty) return;
    for (final c in list) {
      await _addIceCandidate(c);
    }
  }

  Future<void> _addIceCandidate(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.addCandidate(
      RTCIceCandidate(
        payload['candidate'] as String?,
        payload['sdpMid'] as String?,
        payload['sdpMLineIndex'] as int?,
      ),
    );
  }
}
