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
  static const Duration _connectingTimeoutDuration = Duration(seconds: 50);

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
  Timer? _acceptResendTimer;
  int _acceptResendAttempts = 0;
  Timer? _offerResendTimer;
  Timer? _iceDiagTimer;
  int _localRelayCount = 0;
  int _localSrflxCount = 0;
  int _localHostCount = 0;
  int _remoteRelayCount = 0;
  int _remoteSrflxCount = 0;
  int _remoteHostCount = 0;
  DateTime _phaseSince = DateTime.now();
  static final RegExp _pubKeyHex64 = RegExp(r'^[0-9a-f]{64}$');

  MediaStream? remoteStream;
  final ValueNotifier<MediaStream?> remoteStreamNotifier = ValueNotifier(null);

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
      {'urls': 'stun:stun.nextcloud.com:443'},
    ];
    final host = _turnHost.trim();
    final user = _turnUser.trim();
    final pass = _turnPassword.trim();
    if (host.isNotEmpty && user.isNotEmpty && pass.isNotEmpty) {
      // TURN UDP и TCP — основной транспорт; TLS не добавляем (нет сертификата).
      servers.add(<String, dynamic>{
        'urls': <String>[
          'turn:$host:3478?transport=udp',
          'turn:$host:3478?transport=tcp',
        ],
        'username': user,
        'credential': pass,
      });
      debugPrint('[RLINK][Call] TURN configured: $host user=$user');
    } else {
      debugPrint('[RLINK][Call] TURN NOT configured (no dart-define). '
          'Calls may fail between NAT devices. Run with:\n'
          '  --dart-define=TURN_HOST=<host>\n'
          '  --dart-define=TURN_USER=<user>\n'
          '  --dart-define=TURN_PASSWORD=<pass>');
    }
    // iceCandidatePoolSize: пул кандидатов начинает собираться сразу при
    //   createPeerConnection, а не после setLocalDescription — заметно
    //   ускоряет старт звонка (особенно для TURN allocate).
    // bundlePolicy/rtcpMuxPolicy: один транспортный канал для всего —
    //   меньше работы NAT-у, быстрее ICE checks.
    return <String, dynamic>{
      'iceServers': servers,
      'iceCandidatePoolSize': 4,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }

  /// Сбор статистики типов ICE-кандидатов; вызывается через несколько секунд
  /// после старта «connecting» — помогает отлавливать «нет relay-кандидатов»
  /// (TURN не работает) и symmetric NAT-проблемы.
  void _logIceCandidateSummary(int localRelay, int localSrflx, int localHost,
      int remoteRelay, int remoteSrflx, int remoteHost) {
    debugPrint('[RLINK][Call] ICE candidates: '
        'local relay=$localRelay srflx=$localSrflx host=$localHost / '
        'remote relay=$remoteRelay srflx=$remoteSrflx host=$remoteHost');
    if (localRelay == 0 && _turnHost.trim().isNotEmpty) {
      debugPrint('[RLINK][Call][WARN] no local relay candidates — TURN allocate '
          'не прошёл (host=$_turnHost). Проверь UDP 3478 и порты 49160-49200.');
    }
    if (remoteRelay == 0 && remoteSrflx == 0) {
      debugPrint(
          '[RLINK][Call][WARN] нет ни одного публичного кандидата от пира — '
          'возможно его STUN не работает или ICE-сигнализация не доходит.');
    }
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
    // Keep resending invite+offer every 5 s so callee gets it even after
    // a transient relay reconnect (WS drop → silent mailbox queue).
    _startOfferResendLoop(recipientKey, callId);

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
      _startAcceptResendLoop(session.peerId, session.callId);
      incomingCall.value = null;
      return;
    }
    _stopAcceptResendLoop();
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
    // Pre-create remote stream — on iOS event.streams is often empty,
    // so we add tracks manually and avoid the null-stream bug.
    final rs = await createLocalMediaStream('remote');

    pc.onIceCandidate = (candidate) async {
      final peerId = _activePeerId;
      final callId = _activeCallId;
      if (peerId == null || callId == null || candidate.candidate == null) {
        return;
      }
      // Логируем тип кандидата для диагностики (host/srflx/relay)
      final c = candidate.candidate ?? '';
      final typ = RegExp(r'typ\s+(\S+)').firstMatch(c)?.group(1) ?? '?';
      switch (typ) {
        case 'relay':
          _localRelayCount++;
          break;
        case 'srflx':
        case 'prflx':
          _localSrflxCount++;
          break;
        case 'host':
          _localHostCount++;
          break;
      }
      debugPrint('[RLINK][Call] ICE candidate typ=$typ mid=${candidate.sdpMid}');
      await _sendSignal(peerId, callId, 'ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onTrack = (event) {
      unawaited(rs.addTrack(event.track));
      remoteStream = rs;
      remoteStreamNotifier.value = rs;
      _connectTimeout?.cancel();
      if (phase.value != CallPhase.connected) {
        _setPhase(CallPhase.connected);
        unawaited(SoundEffectsService.instance.playAction(ActionSound.callConnected));
      }
    };

    pc.onIceConnectionState = (state) {
      debugPrint('[RLINK][Call] ICE state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _connectTimeout?.cancel();
          if (phase.value != CallPhase.connected) {
            _setPhase(CallPhase.connected);
            unawaited(SoundEffectsService.instance.playAction(ActionSound.callConnected));
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          if (phase.value != CallPhase.ended && phase.value != CallPhase.failed) {
            unawaited(_cleanup(CallPhase.failed));
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          // Transient — give it a few seconds before cleaning up.
          // onConnectionState handles the definitive closure.
          break;
        default:
          break;
      }
    };

    pc.onConnectionState = (state) {
      debugPrint('[RLINK][Call] PC state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_cleanup(CallPhase.failed));
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        if (phase.value != CallPhase.ended && phase.value != CallPhase.failed) {
          unawaited(_cleanup(CallPhase.ended));
        }
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectTimeout?.cancel();
        if (phase.value != CallPhase.connected) {
          _setPhase(CallPhase.connected);
          unawaited(SoundEffectsService.instance.playAction(ActionSound.callConnected));
        }
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
        // De-duplicate: if we're already ringing for this exact call, ignore
        // re-invites (sent by caller's offer resend loop).
        if (_activeCallId == callId && phase.value == CallPhase.ringing) {
          break;
        }
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
          _stopAcceptResendLoop();
          await _applyOfferAndAnswer(callId, fromId, payload);
        }
        break;
      case 'accept':
        // Callee accepted — move to connecting phase, then resend offer.
        final callMatch = _activeCallId == callId;
        final peerMatch = _activePeerId == fromId;
        debugPrint('[RLINK][Call] accept gate: callMatch=$callMatch peerMatch=$peerMatch '
            'myCall=${_activeCallId?.substring(0, 8) ?? '-'} rxCall=${callId.substring(0, 8)} '
            'myPeer=${_activePeerId?.substring(0, 8) ?? '-'} rxPeer=${fromId.substring(0, 8)}');
        if (callMatch && peerMatch) {
          _stopOfferResendLoop(); // stop ringing resend, caller now sends offer on-demand
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
    _iceDiagTimer?.cancel();
    _iceDiagTimer = null;
    _stopAcceptResendLoop();
    _stopOfferResendLoop();
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
    remoteStreamNotifier.value = null;
    _activeCallId = null;
    _activePeerId = null;
    _lastLocalOffer = null;
    _acceptedAwaitingOffer = false;
    _pendingOffers.clear();
    _pendingIce.clear();
    _localRelayCount = 0;
    _localSrflxCount = 0;
    _localHostCount = 0;
    _remoteRelayCount = 0;
    _remoteSrflxCount = 0;
    _remoteHostCount = 0;
    _setPhase(endPhase);
  }

  void _startAcceptResendLoop(String peerId, String callId) {
    _stopAcceptResendLoop();
    _acceptResendAttempts = 0;
    _acceptResendTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!_acceptedAwaitingOffer || _activeCallId != callId || _activePeerId != peerId) {
        _stopAcceptResendLoop();
        return;
      }
      _acceptResendAttempts++;
      if (_acceptResendAttempts > 6) {
        debugPrint('[RLINK][Call] offer did not arrive after repeated accept.');
        _stopAcceptResendLoop();
        return;
      }
      debugPrint('[RLINK][Call] resend accept #$_acceptResendAttempts call=$callId');
      await _sendSignal(peerId, callId, 'accept');
    });
  }

  void _stopAcceptResendLoop() {
    _acceptResendTimer?.cancel();
    _acceptResendTimer = null;
    _acceptResendAttempts = 0;
  }

  /// Caller-side loop: resend invite+offer every 5 s while still ringing.
  /// Ensures callee gets the offer even if they reconnected to relay after
  /// the initial delivery (transient WebSocket drop → silent relay queue).
  void _startOfferResendLoop(String peerId, String callId) {
    _stopOfferResendLoop();
    _offerResendTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      if (phase.value != CallPhase.ringing || _activeCallId != callId) {
        _stopOfferResendLoop();
        return;
      }
      debugPrint('[RLINK][Call] resend invite+offer (ringing retry) call=$callId');
      await _sendSignal(peerId, callId, 'invite', {'video': _videoEnabled, 'audio': true});
      if (_lastLocalOffer != null) {
        await _sendSignal(peerId, callId, 'offer', _lastLocalOffer!);
      }
    });
  }

  void _stopOfferResendLoop() {
    _offerResendTimer?.cancel();
    _offerResendTimer = null;
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
      _logIceCandidateSummary(_localRelayCount, _localSrflxCount,
          _localHostCount, _remoteRelayCount, _remoteSrflxCount,
          _remoteHostCount);
      unawaited(_cleanup(CallPhase.failed));
    });
    // Промежуточный диаг через 8 сек — если до сих пор не connected,
    // покажем сводку кандидатов: проще понять, виноват ли TURN.
    _iceDiagTimer?.cancel();
    _iceDiagTimer = Timer(const Duration(seconds: 8), () {
      if (phase.value != CallPhase.connecting) return;
      _logIceCandidateSummary(_localRelayCount, _localSrflxCount,
          _localHostCount, _remoteRelayCount, _remoteSrflxCount,
          _remoteHostCount);
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
    final cstr = payload['candidate'] as String? ?? '';
    final typ = RegExp(r'typ\s+(\S+)').firstMatch(cstr)?.group(1) ?? '?';
    switch (typ) {
      case 'relay':
        _remoteRelayCount++;
        break;
      case 'srflx':
      case 'prflx':
        _remoteSrflxCount++;
        break;
      case 'host':
        _remoteHostCount++;
        break;
    }
    await pc.addCandidate(
      RTCIceCandidate(
        payload['candidate'] as String?,
        payload['sdpMid'] as String?,
        payload['sdpMLineIndex'] as int?,
      ),
    );
  }
}
