import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../utils/invite_dm_codec.dart';
import 'ble_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';

/// Отправка приглашений в канал/группу как обычное ЛС (зашифрованное при наличии X25519).
class InviteDmService {
  InviteDmService._();

  static const _uuid = Uuid();

  static Future<void> sendChannelInviteDm({
    required String targetPublicKey,
    required Map<String, dynamic> payload,
  }) =>
      _send(
        targetPublicKey: targetPublicKey,
        wireText: InviteDmCodec.encodeChannelInvite(payload),
        outgoingPreview: InviteDmCodec.channelInvitePreview(payload),
        invitePayloadJson: jsonEncode({'kind': 'channel', ...payload}),
      );

  static Future<void> sendGroupInviteDm({
    required String targetPublicKey,
    required Map<String, dynamic> payload,
  }) =>
      _send(
        targetPublicKey: targetPublicKey,
        wireText: InviteDmCodec.encodeGroupInvite(payload),
        outgoingPreview: InviteDmCodec.groupInvitePreview(payload),
        invitePayloadJson: jsonEncode({'kind': 'group', ...payload}),
      );

  static Future<void> _send({
    required String targetPublicKey,
    required String wireText,
    required String outgoingPreview,
    required String invitePayloadJson,
  }) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    final msgId = _uuid.v4();
    var x25519 = BleService.instance.getPeerX25519Key(targetPublicKey) ??
        RelayService.instance.getPeerX25519Key(targetPublicKey);

    final out = ChatMessage(
      id: msgId,
      peerId: targetPublicKey,
      text: outgoingPreview,
      invitePayloadJson: invitePayloadJson,
      isOutgoing: true,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );
    await ChatStorageService.instance.saveMessage(out);

    try {
      if (x25519 != null && x25519.isNotEmpty) {
        final enc = await CryptoService.instance.encryptMessage(
          plaintext: wireText,
          recipientX25519KeyBase64: x25519,
        );
        await GossipRouter.instance.sendEncryptedMessage(
          encrypted: enc,
          senderId: myId,
          recipientId: targetPublicKey,
          messageId: msgId,
        );
      } else {
        await GossipRouter.instance.sendRawMessage(
          text: wireText,
          senderId: myId,
          recipientId: targetPublicKey,
          messageId: msgId,
        );
      }
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
    } catch (_) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.failed,
      );
    }
  }
}
