import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'crypto_service.dart';
import 'gossip_router.dart';
import 'chat_storage_service.dart';
import 'notification_service.dart';
import 'relay_service.dart';
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
  static const Duration _ringingTimeoutDuration = Duration(seconds: 60);
  static const Duration _connectingTimeoutDuration = Duration(seconds: 35);

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
  DateTime _phaseSince = DateTime.now();
  static final RegExp _pubKeyHex64 = RegExp(r'^[0-9a-f]{64}$');

  MediaStream? remoteStream;

  bool get isBusy =>
      phase.value == CallPhase.ringing ||
      phase.value == CallPhase.connecting ||
      phase.value == CallPhase.connected;

  void _setPhase(CallPhase next) {
    phase.value = next;
    _phaseSince = DateTime.now();
  }

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
    // Fallback TURNs keep call setup reliable when self-hosted TURN is
    // temporarily unreachable/misconfigured in production.
    servers.addAll(<Map<String, dynamic>>[
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turns:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ]);
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
    final recipientKey = _resolveRecipientKey(peerId);
    if (recipientKey == null) {
      throw StateError('invalid_recipient');
    }
    if (!RelayService.instance.isConnected) {
      throw StateError('peer_offline');
    }
    final callId = _uuid.v4();
    _activeCallId = callId;
    _activePeerId = recipientKey;
    _videoEnabled = video;
    await SoundEffectsService.instance.stopIncomingRingtone();
    // Show "ringing" while waiting for callee to accept.
    // Transitions to connecting when 'accept' signal arrives.
    _setPhase(CallPhase.ringing);
    await _ensurePeerConnection();
    await _ensureLocalStream();

    await _sendSignal(recipientKey, callId, 'invite', {
      'video': _videoEnabled,
      'audio': true,
    });
    await _createAndSendOffer();
    _armRingingTimeout();

    return CallSessionInfo(
      callId: callId,
      peerId: peerId,
      incoming: false,
      videoEnabled: _videoEnabled,
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
    _setPhase(CallPhase.connecting);

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
        _setPhase(CallPhase.connected);
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
        _setPhase(CallPhase.connected);
        unawaited(SoundEffectsService.instance.playAction(ActionSound.callConnected));
      }
    };
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    try {
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
      return;
    } catch (e) {
      debugPrint('[RLINK][Call] getUserMedia primary failed: $e');
    }

    if (_videoEnabled) {
      // iOS devices can fail or crash during camera bootstrap on some plugin/device
      // combinations. Fallback to audio-only instead of aborting the call flow.
      try {
        final media = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        _videoEnabled = false;
        _localStream = media;
        final pc = _pc;
        if (pc != null) {
          for (final track in media.getTracks()) {
            await pc.addTrack(track, media);
          }
        }
        debugPrint('[RLINK][Call] Fallback to audio-only stream.');
        return;
      } catch (e) {
        debugPrint('[RLINK][Call] getUserMedia audio fallback failed: $e');
      }
    }

    throw StateError('media_init_failed');
  }

  Future<void> _onSignal(
    String fromId,
    String callId,
    String signalType,
    Map<String, dynamic> payload,
  ) async {
    final f8 = fromId.length >= 8 ? fromId.substring(0, 8) : fromId;
    debugPrint('[RLINK][Call][RX] $signalType call=$callId from=$f8');
    switch (signalType) {
      case 'invite':
        if (isBusy && _activeCallId != callId) {
          final staleBusy = (phase.value == CallPhase.ringing ||
                  phase.value == CallPhase.connecting) &&
              DateTime.now().difference(_phaseSince) > const Duration(seconds: 70);
          if (staleBusy) {
            debugPrint(
              '[RLINK][Call] dropping stale busy state: call=${_activeCallId ?? '-'} phase=${phase.value}',
            );
            await _cleanup(CallPhase.idle);
          }
        }
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
        _setPhase(CallPhase.ringing);
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
          _setPhase(CallPhase.connecting);
          _armConnectTimeout();
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
            if (phase.value == CallPhase.connecting) {
              _armConnectTimeout();
            }
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
          if (phase.value == CallPhase.connecting) {
            _armConnectTimeout();
          }
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
    final r8 = recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    debugPrint('[RLINK][Call][TX] $signalType call=$callId to=$r8');
    await GossipRouter.instance.sendCallSignal(
      fromId: myId,
      recipientId: recipientId,
      callId: callId,
      signalType: signalType,
      payload: payload,
    );
  }

  String? _resolveRecipientKey(String peerId) {
    final trimmed = peerId.trim().toLowerCase();
    if (_pubKeyHex64.hasMatch(trimmed)) return trimmed;
    if (trimmed.length >= 8) {
      final byPrefix = RelayService.instance.findPeerByPrefix(trimmed);
      if (byPrefix != null) {
        final key = byPrefix.trim().toLowerCase();
        if (_pubKeyHex64.hasMatch(key)) return key;
      }
    }
    return null;
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
    _setPhase(endPhase);
  }

  void _armConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(_connectingTimeoutDuration, () {
      if (phase.value == CallPhase.connected ||
          phase.value == CallPhase.ended) {
        return;
      }
      debugPrint(
        '[RLINK][Call] connect timeout: call=${_activeCallId ?? '-'} phase=${phase.value}',
      );
      unawaited(_cleanup(CallPhase.failed));
    });
  }

  void _armRingingTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(_ringingTimeoutDuration, () {
      if (phase.value != CallPhase.ringing) return;
      debugPrint(
        '[RLINK][Call] ringing timeout: call=${_activeCallId ?? '-'} phase=${phase.value}',
      );
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
