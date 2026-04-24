import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'app_settings.dart';
import 'ble_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'peer_key_directory.dart';
import 'relay_service.dart';

/// OutboxService — гарантированная доставка исходящих личных сообщений.
///
/// Идея:
/// - Сообщение считается доставленным, когда приходит ACK (status=delivered).
/// - До этого момента (sending/sent/failed) оно периодически переотправляется
///   с тем же messageId (дедуп на стороне получателя по primary key).
/// - Переотправки триггерятся таймером + событиями появления сети/пира.
class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  final Set<String> _inflight = <String>{};

  VoidCallback? _relayListener;
  VoidCallback? _presenceListener;
  VoidCallback? _bleListener;

  /// How often to retry sending undelivered messages.
  static const _tick = Duration(seconds: 7);

  Future<void> init() async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _pump());

    // Trigger immediate attempts when transport availability changes.
    _relayListener = () => _pump();
    _presenceListener = () => _pump();
    _bleListener = () => _pump();
    RelayService.instance.state.addListener(_relayListener!);
    RelayService.instance.presenceVersion.addListener(_presenceListener!);
    BleService.instance.peersCount.addListener(_bleListener!);

    // First run on startup (after DB is ready).
    unawaited(_pump());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_relayListener != null) {
      RelayService.instance.state.removeListener(_relayListener!);
    }
    if (_presenceListener != null) {
      RelayService.instance.presenceVersion.removeListener(_presenceListener!);
    }
    if (_bleListener != null) {
      BleService.instance.peersCount.removeListener(_bleListener!);
    }
  }

  Future<void> _pump() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      // If transport is completely unavailable, skip quickly.
      final hasRelay = RelayService.instance.isConnected;
      final mode = AppSettings.instance.connectionMode;
      final allowBle = mode != 1; // 1 = internet-only mode disables BLE mesh

      final pending = await ChatStorageService.instance.getUndeliveredOutgoingMessages();
      if (pending.isEmpty) return;

      for (final msg in pending) {
        if (_disposed) return;
        if (_inflight.contains(msg.id)) continue;

        final peerId = msg.peerId;
        final canTry =
            hasRelay || (allowBle && BleService.instance.isPeerConnected(peerId));
        if (!canTry) continue;

        _inflight.add(msg.id);
        unawaited(_resendOne(msg).whenComplete(() => _inflight.remove(msg.id)));
      }
    } catch (e) {
      debugPrint('[RLINK][Outbox] Pump error: $e');
    } finally {
      _running = false;
    }
  }

  Future<void> _resendOne(ChatMessage msg) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    if (msg.isOutgoing != true) return;
    if (msg.status == MessageStatus.delivered) return;
    // Only text messages here. Media is handled by MediaUploadQueue / img_chunk.
    if (msg.imagePath != null ||
        msg.videoPath != null ||
        msg.voicePath != null ||
        msg.filePath != null) {
      return;
    }
    if (msg.text.trim().isEmpty) return;

    try {
      // Mark as sending (UI can show spinner).
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.sending,
      );

      // Use the latest X25519 key known in unified directory.
      final x25519Key = PeerKeyDirectory.instance.getX25519(msg.peerId);

      // IMPORTANT: use the SAME messageId so receiver dedups.
      if (x25519Key != null && x25519Key.isNotEmpty) {
        final encrypted = await CryptoService.instance.encryptMessage(
          plaintext: msg.text,
          recipientX25519KeyBase64: x25519Key,
        );
        await GossipRouter.instance.sendEncryptedMessage(
          encrypted: encrypted,
          senderId: myId,
          recipientId: msg.peerId,
          messageId: msg.id,
          latitude: msg.latitude,
          longitude: msg.longitude,
          replyToMessageId: msg.replyToMessageId,
          forwardFromId: msg.forwardFromId,
          forwardFromNick: msg.forwardFromNick,
          forwardFromChannelId: msg.forwardFromChannelId,
        );
      } else {
        await GossipRouter.instance.sendRawMessage(
          text: msg.text,
          senderId: myId,
          recipientId: msg.peerId,
          messageId: msg.id,
          replyToMessageId: msg.replyToMessageId,
          latitude: msg.latitude,
          longitude: msg.longitude,
          forwardFromId: msg.forwardFromId,
          forwardFromNick: msg.forwardFromNick,
          forwardFromChannelId: msg.forwardFromChannelId,
        );
      }

      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.sent,
      );
    } catch (e) {
      debugPrint('[RLINK][Outbox] Resend failed msg=${msg.id}: $e');
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.failed,
      );
    }
  }
}

