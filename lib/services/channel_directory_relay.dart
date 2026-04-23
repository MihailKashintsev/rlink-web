import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/channel.dart';
import 'app_settings.dart';
import 'crypto_service.dart';
import 'relay_service.dart';

/// Публикация и приём снимка публичных каналов с relay (подпись админа Ed25519).
class ChannelDirectoryRelay {
  ChannelDirectoryRelay._();

  static String _canonicalPayloadJson(Map<String, dynamic> m) {
    final keys = m.keys.toList()..sort();
    final sorted = <String, dynamic>{for (final k in keys) k: m[k]};
    return jsonEncode(sorted);
  }

  static Map<String, dynamic> _payloadMap(Channel ch, int updatedAtMs) {
    if (!ch.isPublic) {
      return {
        'adminId': ch.adminId,
        'channelId': ch.id,
        'isPublic': false,
        'updatedAt': updatedAtMs,
      };
    }
    return {
      'adminId': ch.adminId,
      'avatarColor': ch.avatarColor,
      'avatarEmoji': ch.avatarEmoji,
      'channelId': ch.id,
      'commentsEnabled': ch.commentsEnabled,
      'createdAt': ch.createdAt,
      'description': ch.description,
      'driveBackup': ch.driveBackupEnabled,
      'driveBackupRev': ch.driveBackupRev,
      'isPublic': true,
      'linkAdminIds': ch.linkAdminIds,
      'moderatorIds': ch.moderatorIds,
      'name': ch.name,
      'signStaffPosts': ch.signStaffPosts,
      'staffLabels': ch.staffLabels,
      'subscriberIds':
          ch.subscriberIds.isNotEmpty ? ch.subscriberIds : <String>[ch.adminId],
      'universalCode': ch.universalCode,
      'updatedAt': updatedAtMs,
      'username': ch.username,
      'verified': ch.verified,
      'verifiedBy': ch.verifiedBy,
    };
  }

  /// Публикует запись каталога, если текущий пользователь — админ канала и relay подключён.
  static Future<void> publishIfAdmin(Channel ch) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty || ch.adminId != myId) return;
    if (!RelayService.instance.isConnected) return;
    if (AppSettings.instance.connectionMode < 1) return;

    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    final m = _payloadMap(ch, updatedAt);
    final payload = _canonicalPayloadJson(m);
    try {
      final sig = await CryptoService.instance.signUtf8Message(payload);
      await RelayService.instance.putChannelDirectory(
        payload: payload,
        signatureHex: sig,
      );
    } catch (e, st) {
      debugPrint('[RLINK][ChDir] publish failed: $e\n$st');
    }
  }
}
