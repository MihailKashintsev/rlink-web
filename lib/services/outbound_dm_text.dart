import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'ble_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';

/// Текстовая отправка в личный чат (как [ChatScreen._send], без UI).
class OutboundDmText {
  OutboundDmText._();

  static final _pk = RegExp(r'^[0-9a-fA-F]{64}$');
  static const _chunkLen = 600;
  static final _uuid = const Uuid();

  static List<String> splitChunks(String text) {
    final t = text.trim();
    if (t.isEmpty) return const [];
    final parts = <String>[];
    for (var i = 0; i < t.length; i += _chunkLen) {
      final end = (i + _chunkLen) > t.length ? t.length : i + _chunkLen;
      parts.add(t.substring(i, end));
    }
    return parts;
  }

  static String _resolveTargetPeerId(String peerIdOrBle) {
    var t = peerIdOrBle.trim();
    if (_pk.hasMatch(t)) return t;
    final resolved = BleService.instance.resolvePublicKey(peerIdOrBle);
    if (_pk.hasMatch(resolved)) return resolved;
    throw StateError('Нет публичного ключа собеседника для отправки');
  }

  /// Сохраняет сообщения в БД и рассылает gossip (шифрование при наличии X25519).
  static Future<void> send({
    required String peerId,
    required String fullText,
    String? replyToMessageId,
  }) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) throw StateError('Ключи не готовы');

    final targetPeerId = _resolveTargetPeerId(peerId);
    final parts = splitChunks(fullText);
    if (parts.isEmpty) return;

    var x25519Key = BleService.instance.getPeerX25519Key(targetPeerId);
    if (x25519Key == null || x25519Key.isEmpty) {
      x25519Key = RelayService.instance.getPeerX25519Key(targetPeerId);
    }

    for (var i = 0; i < parts.length; i++) {
      final partText = parts[i];
      final isFirst = i == 0;
      final msgId = _uuid.v4();

      final msg = ChatMessage(
        id: msgId,
        peerId: targetPeerId,
        text: partText,
        replyToMessageId: isFirst ? replyToMessageId : null,
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );
      await ChatStorageService.instance.saveMessage(msg);

      if (x25519Key != null && x25519Key.isNotEmpty) {
        final encrypted = await CryptoService.instance.encryptMessage(
          plaintext: partText,
          recipientX25519KeyBase64: x25519Key,
        );
        await GossipRouter.instance.sendEncryptedMessage(
          encrypted: encrypted,
          senderId: myId,
          recipientId: targetPeerId,
          messageId: msgId,
        );
      } else {
        await GossipRouter.instance.sendRawMessage(
          text: partText,
          senderId: myId,
          recipientId: targetPeerId,
          messageId: msgId,
          replyToMessageId: isFirst ? replyToMessageId : null,
        );
      }

      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
    }
    debugPrint(
        '[RLINK][OutboundDm] sent ${parts.length} chunk(s) to ${targetPeerId.substring(0, 8)}');
  }
}
