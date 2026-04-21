import 'dart:async';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'group_service.dart';
import 'gossip_router.dart';

/// Что очистить в локальном кэше переписок.
class MessageCacheClearSpec {
  /// Личные чаты (DM).
  final bool includeDm;
  final bool includeGroups;
  final bool includeChannels;
  /// true — только вложения (фото/видео/голос/файлы), текст остаётся.
  final bool mediaOnly;
  /// null = все диалоги выбранного типа; иначе только перечисленные id.
  final Set<String>? dmPeerIds;
  final Set<String>? groupIds;
  final Set<String>? channelIds;

  const MessageCacheClearSpec({
    this.includeDm = true,
    this.includeGroups = true,
    this.includeChannels = true,
    this.mediaOnly = false,
    this.dmPeerIds,
    this.groupIds,
    this.channelIds,
  });
}

/// Очистка локальных сообщений и опциональный запрос истории у сети.
class ConversationCacheService {
  ConversationCacheService._();
  static final ConversationCacheService instance = ConversationCacheService._();

  /// Ранее: полная очистка всего. Сохранено для совместимости.
  Future<void> clearMessageCachesAndRequestHistoryResync() async {
    await applyClear(const MessageCacheClearSpec());
  }

  Future<void> applyClear(MessageCacheClearSpec spec) async {
    final myKey = CryptoService.instance.publicKeyHex;
    if (myKey.isEmpty) return;

    final clearedDmPeers = <String>{};
    if (spec.includeDm) {
      clearedDmPeers.addAll(spec.dmPeerIds?.toSet() ??
          (await ChatStorageService.instance.getChatPeerIds()).toSet());
      if (clearedDmPeers.isNotEmpty) {
        await ChatStorageService.instance.clearDirectMessages(
          peerIds: clearedDmPeers,
          mediaOnly: spec.mediaOnly,
        );
      }
    }

    final clearedGroups = <String>{};
    if (spec.includeGroups) {
      clearedGroups.addAll(spec.groupIds?.toSet() ??
          (await GroupService.instance.getGroupIds()).toSet());
      if (clearedGroups.isNotEmpty) {
        await GroupService.instance.clearGroupMessages(
          groupIds: clearedGroups,
          mediaOnly: spec.mediaOnly,
        );
      }
    }

    final clearedChannels = <String>{};
    if (spec.includeChannels) {
      final raw = spec.channelIds?.toSet() ??
          (await ChannelService.instance.getChannelIds()).toSet();
      for (final cid in raw) {
        final ch = await ChannelService.instance.getChannel(cid);
        if (ch != null && ch.adminId == myKey) continue;
        clearedChannels.add(cid);
      }
      if (clearedChannels.isNotEmpty) {
        await ChannelService.instance.clearChannelPostsAndComments(
          channelIds: clearedChannels,
          mediaOnly: spec.mediaOnly,
        );
      }
    }

    await _requestHistoryResync(
      myKey: myKey,
      channelIds: clearedChannels,
      groupIds: clearedGroups,
    );
  }

  Future<void> _requestHistoryResync({
    required String myKey,
    required Set<String> channelIds,
    required Set<String> groupIds,
  }) async {
    for (final ch in channelIds) {
      final meta = await ChannelService.instance.getChannel(ch);
      if (meta == null) continue;
      unawaited(GossipRouter.instance.sendChannelHistoryRequest(
        channelId: ch,
        requesterId: myKey,
        adminId: meta.adminId,
        sinceTs: 0,
      ));
      await Future.delayed(const Duration(milliseconds: 80));
    }
    for (final gid in groupIds) {
      unawaited(GossipRouter.instance.sendGroupHistoryRequest(
        groupId: gid,
        requesterId: myKey,
        sinceTs: 0,
      ));
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }
}
