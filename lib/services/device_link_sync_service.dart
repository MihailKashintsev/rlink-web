import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_bot_constants.dart';
import '../models/chat_message.dart';
import 'app_settings.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';

/// Syncs DM history between linked primary/child devices.
class DeviceLinkSyncService {
  DeviceLinkSyncService._();
  static final DeviceLinkSyncService instance = DeviceLinkSyncService._();

  StreamSubscription<ChatMessage>? _messageSub;
  VoidCallback? _relayListener;
  VoidCallback? _settingsListener;
  bool _initialized = false;
  bool _snapshotSending = false;
  bool _snapshotRequestedThisSession = false;
  final Set<String> _suppressLocalMirrorIds = <String>{};

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    GossipRouter.instance.onDeviceDmSyncRequest = (sourceId, publicKey) {
      unawaited(_handleSnapshotRequest(sourceId, publicKey));
    };
    GossipRouter.instance.onDeviceDmSyncPacket =
        (sourceId, publicKey, kind, data, snapshot) {
      return _handleSyncPacket(
        sourceId: sourceId,
        publicKey: publicKey,
        kind: kind,
        data: data,
        snapshot: snapshot,
      );
    };

    _messageSub = ChatStorageService.instance.messageSavedStream.listen((msg) {
      unawaited(_onLocalMessageSaved(msg));
    });

    _relayListener = () {
      if (RelayService.instance.isConnected) {
        unawaited(_requestSnapshotIfNeeded());
      }
    };
    RelayService.instance.state.addListener(_relayListener!);

    _settingsListener = () {
      if (!AppSettings.instance.isDeviceLinked) {
        onUnlinked();
      }
    };
    AppSettings.instance.addListener(_settingsListener!);

    unawaited(_requestSnapshotIfNeeded());
  }

  void dispose() {
    _initialized = false;
    unawaited(_messageSub?.cancel() ?? Future<void>.value());
    _messageSub = null;
    if (_relayListener != null) {
      RelayService.instance.state.removeListener(_relayListener!);
      _relayListener = null;
    }
    if (_settingsListener != null) {
      AppSettings.instance.removeListener(_settingsListener!);
      _settingsListener = null;
    }
  }

  Future<void> onLinkedAsChild() async {
    _snapshotRequestedThisSession = false;
    await _requestSnapshotIfNeeded(force: true);
  }

  void onUnlinked() {
    _snapshotRequestedThisSession = false;
    _suppressLocalMirrorIds.clear();
  }

  Future<void> mirrorAckDelivered(String messageId) async {
    final linkedPeer = _linkedPeerKey();
    final myKey = CryptoService.instance.publicKeyHex;
    if (linkedPeer == null || myKey.isEmpty || messageId.isEmpty) return;
    try {
      await GossipRouter.instance.sendDeviceDmSync(
        publicKey: myKey,
        recipientId: linkedPeer,
        kind: 'dm_status',
        data: <String, dynamic>{
          'id': messageId,
          'st': MessageStatus.delivered.index,
        },
      );
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Failed to mirror ACK: $e');
    }
  }

  Future<void> _requestSnapshotIfNeeded({bool force = false}) async {
    final settings = AppSettings.instance;
    if (!settings.isLinkedChildDevice) return;
    if (!force && _snapshotRequestedThisSession) return;

    final linkedPeer = settings.linkedDevicePublicKey.trim();
    final myKey = CryptoService.instance.publicKeyHex;
    if (linkedPeer.isEmpty || myKey.isEmpty) return;

    if (!RelayService.instance.isConnected) {
      try {
        await RelayService.instance.connect();
      } catch (_) {}
    }
    if (!RelayService.instance.isConnected) return;

    try {
      await GossipRouter.instance.sendDeviceDmSyncRequest(
        publicKey: myKey,
        recipientId: linkedPeer,
      );
      _snapshotRequestedThisSession = true;
      debugPrint(
          '[RLINK][LinkSync] Snapshot request sent to ${linkedPeer.substring(0, 8)}');
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Failed to request snapshot: $e');
    }
  }

  Future<void> _handleSnapshotRequest(String sourceId, String publicKey) async {
    final settings = AppSettings.instance;
    if (!settings.isPrimaryDevice) return;
    if (!_isLinkedPeer(publicKey)) return;
    if (_snapshotSending) return;
    await _sendSnapshotTo(publicKey);
  }

  Future<void> _sendSnapshotTo(String recipientId) async {
    final myKey = CryptoService.instance.publicKeyHex;
    if (myKey.isEmpty) return;

    _snapshotSending = true;
    try {
      await GossipRouter.instance.sendDeviceDmSync(
        publicKey: myKey,
        recipientId: recipientId,
        kind: 'dm_reset',
        snapshot: true,
      );

      var sent = 0;
      final peerIds = await ChatStorageService.instance.getChatPeerIds();
      for (final peerId in peerIds) {
        if (peerId == kAiBotPeerId) continue;
        if (_normalizeKey(peerId) == _normalizeKey(recipientId)) continue;
        final messages =
            await ChatStorageService.instance.getAllMessages(peerId);
        for (final msg in messages) {
          await GossipRouter.instance.sendDeviceDmSync(
            publicKey: myKey,
            recipientId: recipientId,
            kind: 'dm_msg',
            data: _encodeMessage(msg),
            snapshot: true,
          );
          sent++;
          if (sent % 30 == 0) {
            await Future.delayed(const Duration(milliseconds: 20));
          }
        }
      }

      await GossipRouter.instance.sendDeviceDmSync(
        publicKey: myKey,
        recipientId: recipientId,
        kind: 'dm_done',
        data: <String, dynamic>{'count': sent},
        snapshot: true,
      );
      debugPrint('[RLINK][LinkSync] Snapshot sent, messages=$sent');
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Snapshot send failed: $e');
    } finally {
      _snapshotSending = false;
    }
  }

  Future<void> _onLocalMessageSaved(ChatMessage msg) async {
    if (_suppressLocalMirrorIds.remove(msg.id)) return;

    final linkedPeer = _linkedPeerKey();
    final myKey = CryptoService.instance.publicKeyHex;
    if (linkedPeer == null || myKey.isEmpty) return;

    if (msg.peerId == kAiBotPeerId) return;
    if (_normalizeKey(msg.peerId) == _normalizeKey(linkedPeer)) return;

    try {
      await GossipRouter.instance.sendDeviceDmSync(
        publicKey: myKey,
        recipientId: linkedPeer,
        kind: 'dm_msg',
        data: _encodeMessage(msg),
      );
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Live mirror failed: $e');
    }
  }

  Future<void> _handleSyncPacket({
    required String sourceId,
    required String publicKey,
    required String kind,
    required Map<String, dynamic> data,
    required bool snapshot,
  }) async {
    if (!_isLinkedPeer(publicKey)) return;

    switch (kind) {
      case 'dm_reset':
        await ChatStorageService.instance.deleteAllDirectMessages();
        return;
      case 'dm_msg':
        final msg = _decodeMessage(data);
        if (msg == null) return;
        _suppressLocalMirror(msg.id);
        await ChatStorageService.instance.saveMessage(msg);
        return;
      case 'dm_status':
        final msgId = data['id'] as String?;
        final statusRaw = (data['st'] as num?)?.toInt();
        if (msgId == null || statusRaw == null) return;
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId,
          _statusFromIndex(statusRaw),
        );
        return;
      case 'dm_done':
        if (snapshot && AppSettings.instance.isLinkedChildDevice) {
          debugPrint(
              '[RLINK][LinkSync] Snapshot applied from ${sourceId.substring(0, sourceId.length.clamp(0, 8))}');
        }
        return;
      default:
        return;
    }
  }

  String? _linkedPeerKey() {
    final settings = AppSettings.instance;
    if (!settings.isDeviceLinked) return null;
    final key = settings.linkedDevicePublicKey.trim();
    if (key.isEmpty) return null;
    return key;
  }

  bool _isLinkedPeer(String publicKey) {
    final linked = _linkedPeerKey();
    if (linked == null) return false;
    return _normalizeKey(linked) == _normalizeKey(publicKey);
  }

  static String _normalizeKey(String key) => key.trim().toLowerCase();

  static MessageStatus _statusFromIndex(int index) {
    final safe = index.clamp(0, MessageStatus.values.length - 1);
    return MessageStatus.values[safe];
  }

  static String _normalizedTextForMirror(ChatMessage msg) {
    if (msg.text.trim().isNotEmpty) return msg.text;
    if (msg.voicePath != null) return '🎤 Голосовое';
    if (msg.videoPath != null) return '📹 Видео';
    if (msg.filePath != null || msg.fileName != null) {
      final name = (msg.fileName ?? '').trim();
      return name.isEmpty ? '📎 Файл' : '📎 $name';
    }
    if (msg.imagePath != null) return '📷 Фото';
    return ' ';
  }

  static Map<String, dynamic> _encodeMessage(ChatMessage msg) {
    return <String, dynamic>{
      'id': msg.id,
      'p': msg.peerId,
      't': _normalizedTextForMirror(msg),
      'o': msg.isOutgoing ? 1 : 0,
      'ts': msg.timestamp.millisecondsSinceEpoch,
      'st': msg.status.index,
      if (msg.replyToMessageId != null) 'rt': msg.replyToMessageId,
      if (msg.latitude != null) 'lat': msg.latitude,
      if (msg.longitude != null) 'lng': msg.longitude,
      if (msg.forwardFromId != null) 'ffid': msg.forwardFromId,
      if (msg.forwardFromNick != null) 'ffn': msg.forwardFromNick,
      if (msg.forwardFromChannelId != null) 'ffch': msg.forwardFromChannelId,
      if (msg.invitePayloadJson != null) 'inv': msg.invitePayloadJson,
    };
  }

  static ChatMessage? _decodeMessage(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    final peerId = data['p'] as String?;
    final text = data['t'] as String?;
    final ts = (data['ts'] as num?)?.toInt();
    if (id == null ||
        id.isEmpty ||
        peerId == null ||
        peerId.isEmpty ||
        ts == null) {
      return null;
    }
    final outgoingRaw = data['o'];
    final isOutgoing = outgoingRaw == true || outgoingRaw == 1;
    final statusIndex =
        (data['st'] as num?)?.toInt() ?? MessageStatus.delivered.index;
    return ChatMessage(
      id: id,
      peerId: peerId,
      text: (text == null || text.isEmpty) ? ' ' : text,
      replyToMessageId: data['rt'] as String?,
      latitude: (data['lat'] as num?)?.toDouble(),
      longitude: (data['lng'] as num?)?.toDouble(),
      isOutgoing: isOutgoing,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      status: _statusFromIndex(statusIndex),
      forwardFromId: data['ffid'] as String?,
      forwardFromNick: data['ffn'] as String?,
      forwardFromChannelId: data['ffch'] as String?,
      invitePayloadJson: data['inv'] as String?,
    );
  }

  void _suppressLocalMirror(String messageId) {
    if (messageId.isEmpty) return;
    _suppressLocalMirrorIds.add(messageId);
    Future<void>.delayed(const Duration(seconds: 5), () {
      _suppressLocalMirrorIds.remove(messageId);
    });
  }
}
