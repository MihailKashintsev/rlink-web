import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'channel_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';

/// Публикация списка каналов в gossip + на relay (зашифрованный бокс).
Future<void> publishAccountChannelSubscriptions() async {
  final myId = CryptoService.instance.publicKeyHex;
  if (myId.isEmpty) return;
  try {
    final hash = AppSettings.instance.adminPasswordHash;
    final curRev = AppSettings.instance.adminPasswordSyncRev;
    final rev = curRev + 1;
    final chans =
        await ChannelService.instance.subscribedChannelIdsForAccountSync(myId);
    final bots = AppSettings.instance.enabledBotIds;
    final inner =
        jsonEncode({'hash': hash, 'rev': rev, 'chans': chans, 'bots': bots});
    final sealed = await CryptoService.instance.sealAdminPanelSync(inner);
    await AppSettings.instance.bumpAccountSyncRevisionOnly(rev, sealed);
    await GossipRouter.instance.sendAdminConfigSecure(
      adminPasswordHash: hash,
      revision: rev,
      channelIds: chans,
      botIds: bots,
    );
    await RelayService.instance.putAccountSyncBlob(sealed);
  } catch (e) {
    debugPrint('[RLINK][AccountSync] publish: $e');
  }
}
