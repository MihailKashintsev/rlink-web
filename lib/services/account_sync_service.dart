import 'dart:convert';

import 'app_settings.dart';
import 'channel_service.dart';
import 'crypto_service.dart';

/// Синхронизация аккаунта между устройствами: хэш админки + список id каналов
/// в одном зашифрованном боксе. Relay хранит только ciphertext.
class AccountSyncService {
  AccountSyncService._();

  /// Обработка admin_cfg2 после расшифровки в [GossipRouter].
  static Future<void> applyFromGossip(
    String hash,
    int rev,
    List<String> channelIds,
  ) async {
    if (hash.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      return;
    }
    final cur = AppSettings.instance.adminPasswordSyncRev;
    if (rev <= cur) return;
    final inner =
        jsonEncode({'hash': hash, 'rev': rev, 'chans': channelIds});
    final sealed = await CryptoService.instance.sealAdminPanelSync(inner);
    await AppSettings.instance.applyAdminPasswordSyncIfNewer(hash, rev, sealed);
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isNotEmpty && channelIds.isNotEmpty) {
      await ChannelService.instance.mergeSubscriptionsFromSync(myId, channelIds);
    }
  }

  /// Бокс, полученный с relay при регистрации (`account_sync_blob`).
  static Future<void> applySealedFromRelay(String sealed) async {
    final plain = await CryptoService.instance.openAdminPanelSync(sealed);
    if (plain == null) return;
    Map<String, dynamic> map;
    try {
      map = jsonDecode(plain) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final hash = map['hash'] as String?;
    final rev = (map['rev'] as num?)?.toInt() ?? 0;
    final chans =
        (map['chans'] as List?)?.cast<String>() ?? const <String>[];
    if (hash == null ||
        hash.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      return;
    }
    final curRev = AppSettings.instance.adminPasswordSyncRev;
    if (rev <= curRev) return;

    await AppSettings.instance.applyAdminPasswordSyncIfNewer(hash, rev, sealed);

    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isNotEmpty && chans.isNotEmpty) {
      await ChannelService.instance.mergeSubscriptionsFromSync(myId, chans);
    }
  }
}

