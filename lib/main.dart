import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'models/channel.dart';
import 'models/chat_message.dart';
import 'utils/reaction_limit.dart';
import 'utils/invite_dm_codec.dart';
import 'models/contact.dart';
import 'models/group.dart';
import 'models/user_profile.dart';
import 'models/shared_collab.dart';
import 'services/app_settings.dart';
import 'services/chat_inbox_service.dart';
import 'services/channel_service.dart';
import 'services/channel_backup_service.dart';
import 'services/channel_directory_relay.dart';
import 'services/ether_service.dart';
import 'services/ble_service.dart';
import 'services/browser_cache_service.dart';
import 'services/block_service.dart';
import 'services/chat_storage_service.dart';
import 'services/group_service.dart';
import 'services/crypto_service.dart';
import 'services/gossip_router.dart';
import 'services/image_service.dart';
import 'services/sticker_collection_service.dart';
import 'services/name_filter.dart';
import 'services/profile_service.dart';
import 'services/broadcast_outbox_service.dart';
import 'services/media_upload_queue.dart';
import 'services/notification_service.dart';
import 'services/story_service.dart';
import 'services/relay_service.dart';
import 'services/device_link_sync_service.dart';
import 'services/account_sync_service.dart';
import 'services/scheduled_dm_service.dart';
import 'services/outbox_service.dart';
import 'services/typing_service.dart';
import 'services/voice_service.dart';
import 'services/update_service.dart';
import 'services/connection_transport.dart';
import 'services/app_icon_service.dart';
import 'services/desktop_tray_service.dart';
import 'services/packet_transport.dart';
import 'services/rlink_deep_link_service.dart';
import 'services/runtime_platform.dart';
import 'services/web_storage_bootstrap.dart';
import 'app_route_observer.dart';
import 'ui/screens/chat_list_screen.dart';
import 'ui/widgets/audio_queue_mini_player.dart';
import 'ui/screens/onboarding_screen.dart';

const _kBleChannel = MethodChannel('com.rendergames.rlink/ble');

/// iOS Dynamic Island: активен режим «отправка крупного медиа» (не затирать BLE-состояние).
bool _iosMediaLiveActivityActive = false;

/// Последний обработанный connectionMode для Live Activity (не реагировать на другие настройки).
int _iosLiveActivityLastConnectionMode = -1;

final incomingMessageController = StreamController<IncomingMessage>.broadcast();
final navigatorKey = GlobalKey<NavigatorState>();
final PacketTransport packetTransport = DefaultPacketTransport();
bool _relayChannelRepublishInFlight = false;
int _lastRelayChannelRepublishAtMs = 0;

/// Broadcast my avatar to all peers (callable from anywhere).
/// Сбрасывает Flutter-кэш картинок для конкретного файла, чтобы при перезаписи
/// файла (аватар/баннер с тем же именем) UI показывал актуальную версию,
/// а не закешированный bitmap.
void _evictImageCache(String filePath) {
  try {
    final f = File(filePath);
    PaintingBinding.instance.imageCache.evict(FileImage(f));
  } catch (_) {}
}

Future<void> _restoreAdminPasswordFromSealedIfNeeded() async {
  final sealed = AppSettings.instance.adminPasswordSealedBox;
  if (sealed == null || sealed.isEmpty) return;
  final plain = await CryptoService.instance.openAdminPanelSync(sealed);
  if (plain == null) return;
  try {
    final m = jsonDecode(plain) as Map<String, dynamic>;
    final h = m['hash'] as String?;
    final r = (m['rev'] as num?)?.toInt() ?? 0;
    if (h == null) return;
    await AppSettings.instance.applyAdminPasswordSyncIfNewer(h, r, sealed);
  } catch (_) {}
}

Future<void> broadcastMyAvatar() async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final imagePath =
      ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
  if (imagePath != null) {
    await _broadcastAvatar(myProfile.publicKeyHex, imagePath);
  }
}

/// Broadcast my banner to all peers (callable from anywhere).
Future<void> broadcastMyBanner() async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final bannerPath =
      ImageService.instance.resolveStoredPath(myProfile.bannerImagePath);
  if (bannerPath != null) {
    await _broadcastBanner(myProfile.publicKeyHex, bannerPath);
  }
}

/// Рассылка «музыки профиля» контактам (relay + BLE).
Future<void> broadcastMyProfileMusic() async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final musicPath =
      ImageService.instance.resolveStoredPath(myProfile.profileMusicPath);
  if (musicPath != null && File(musicPath).existsSync()) {
    await _broadcastProfileMusic(myProfile.publicKeyHex, musicPath);
  }
}

Future<void> _broadcastProfileMusic(
    String myPublicKey, String musicPath) async {
  try {
    await Future.delayed(const Duration(milliseconds: 900));
    final bytes = await File(musicPath).readAsBytes();
    if (RelayService.instance.isConnected) {
      final compressed = ImageService.instance.compress(bytes);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final msgId = 'profile_music_${myPublicKey.substring(0, 16)}_$ts';
      final contacts = await ChatStorageService.instance.getContacts();
      for (final c in contacts) {
        try {
          await RelayService.instance.sendBlob(
            recipientKey: c.publicKeyHex,
            fromId: myPublicKey,
            msgId: msgId,
            compressedData: compressed,
          );
        } catch (_) {}
      }
      debugPrint(
          '[RLINK][Music] Relay profile music → ${contacts.length} contacts');
    }
    if (AppSettings.instance.connectionMode != 1) {
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final bleMsgId =
          'profile_music_${myPublicKey.substring(0, 16)}_${const Uuid().v4().substring(0, 8)}';
      await GossipRouter.instance.sendImgMeta(
        msgId: bleMsgId,
        totalChunks: chunks.length,
        fromId: myPublicKey,
        isAvatar: false,
      );
      await Future.delayed(const Duration(milliseconds: 200));
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: bleMsgId,
          index: i,
          base64Data: chunks[i],
          fromId: myPublicKey,
        );
        if (i % 5 == 4) await Future.delayed(const Duration(milliseconds: 30));
      }
      debugPrint('[RLINK][Music] BLE profile music ${chunks.length} chunks');
    }
  } catch (e) {
    debugPrint('[RLINK][Music] broadcast failed: $e');
  }
}

/// Повторная отправка всех исходящих сообщений, которые застряли в статусе
/// sending/failed (нет соединения). Вызывается при переподключении relay.
/// Порядок сохранён: сортируем по времени создания.
bool _outboxFlushing = false;
Future<void> flushOutbox() async {
  if (_outboxFlushing) return;
  _outboxFlushing = true;
  try {
    final pending =
        await ChatStorageService.instance.getPendingOutgoingMessages();
    if (pending.isEmpty) return;
    debugPrint('[RLINK][Outbox] Flushing ${pending.length} pending messages');
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    for (final m in pending) {
      if (!RelayService.instance.isConnected) break;
      // Только текстовые сообщения — медиа требуют отдельной повторной загрузки.
      if (m.imagePath != null ||
          m.videoPath != null ||
          m.voicePath != null ||
          m.filePath != null) {
        continue;
      }
      try {
        final x = RelayService.instance.getPeerX25519Key(m.peerId) ??
            BleService.instance.getPeerX25519Key(m.peerId);
        if (x != null && x.isNotEmpty) {
          final enc = await CryptoService.instance.encryptMessage(
            plaintext: m.text,
            recipientX25519KeyBase64: x,
          );
          await GossipRouter.instance.sendEncryptedMessage(
            encrypted: enc,
            senderId: myId,
            recipientId: m.peerId,
            messageId: m.id,
            latitude: m.latitude,
            longitude: m.longitude,
            replyToMessageId: m.replyToMessageId,
            forwardFromId: m.forwardFromId,
            forwardFromNick: m.forwardFromNick,
            forwardFromChannelId: m.forwardFromChannelId,
          );
        } else {
          await GossipRouter.instance.sendRawMessage(
            text: m.text,
            senderId: myId,
            recipientId: m.peerId,
            messageId: m.id,
            replyToMessageId: m.replyToMessageId,
            latitude: m.latitude,
            longitude: m.longitude,
            forwardFromId: m.forwardFromId,
            forwardFromNick: m.forwardFromNick,
            forwardFromChannelId: m.forwardFromChannelId,
          );
        }
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          m.id,
          MessageStatus.sent,
        );
        // Небольшая пауза между сообщениями — не душим канал.
        await Future.delayed(const Duration(milliseconds: 150));
      } catch (e) {
        debugPrint('[RLINK][Outbox] Retry failed for ${m.id}: $e');
        // Оставляем статус failed — следующий реконнект попробует снова.
      }
    }
  } finally {
    _outboxFlushing = false;
  }
}

/// "Бумшшшш" — vibration pattern for incoming pair request.
Future<void> boomVibration() async {
  HapticFeedback.heavyImpact();
  await Future.delayed(const Duration(milliseconds: 100));
  HapticFeedback.heavyImpact();
  await Future.delayed(const Duration(milliseconds: 60));
  HapticFeedback.heavyImpact();
  await Future.delayed(const Duration(milliseconds: 150));
  HapticFeedback.mediumImpact();
  await Future.delayed(const Duration(milliseconds: 100));
  HapticFeedback.mediumImpact();
  await Future.delayed(const Duration(milliseconds: 80));
  HapticFeedback.lightImpact();
}

/// Deterministic celebration vibration from a seed — same on both devices.
Future<void> celebrationVibration(int seed) async {
  final rng = seed.abs();
  // 8-beat pattern determined by seed bits
  for (var i = 0; i < 8; i++) {
    final bit = (rng >> i) & 3;
    switch (bit) {
      case 0:
        HapticFeedback.lightImpact();
      case 1:
        HapticFeedback.mediumImpact();
      case 2:
        HapticFeedback.heavyImpact();
      default:
        HapticFeedback.selectionClick();
    }
    await Future.delayed(Duration(milliseconds: 80 + (bit * 30)));
  }
}

/// Generate deterministic emoji list from two public keys — identical on both devices.
List<String> generatePairEmojis(String keyA, String keyB) {
  // Sort keys so both sides get same result regardless of order
  final sorted = [keyA, keyB]..sort();
  final combined = '${sorted[0]}${sorted[1]}';
  // Use hash bytes to pick emojis
  final allEmojis = [
    '🎉',
    '🎊',
    '🥳',
    '🎈',
    '🎁',
    '✨',
    '💫',
    '🌟',
    '⭐',
    '🔥',
    '💥',
    '🎆',
    '🎇',
    '🌈',
    '🦄',
    '🐉',
    '🚀',
    '🛸',
    '👾',
    '🤖',
    '💜',
    '💙',
    '💚',
    '💛',
    '🧡',
    '❤️',
    '🤍',
    '🖤',
    '💎',
    '👑',
    '🎵',
    '🎶',
    '🎸',
    '🥁',
    '🎺',
    '🎻',
    '🎹',
    '🎤',
    '🎧',
    '🪩',
    '🦋',
    '🌸',
    '🌺',
    '🌻',
    '🍀',
    '🌴',
    '🌙',
    '☀️',
    '🪐',
    '🌍',
    '🐱',
    '🐶',
    '🦊',
    '🐼',
    '🐨',
    '🦁',
    '🐯',
    '🦈',
    '🐙',
    '🦑',
    '🍕',
    '🍩',
    '🍪',
    '🧁',
    '🎂',
    '🍰',
    '🍫',
    '🍬',
    '🍭',
    '🧃',
  ];
  final emojis = <String>[];
  for (var i = 0; i < 20; i++) {
    // Use characters from combined key hash as index
    final charCode = combined.codeUnitAt(i % combined.length) +
        combined.codeUnitAt((i * 7 + 3) % combined.length);
    emojis.add(allEmojis[charCode % allEmojis.length]);
  }
  return emojis;
}

/// Seed for deterministic vibration from two keys.
int pairVibrationSeed(String keyA, String keyB) {
  final sorted = [keyA, keyB]..sort();
  var hash = 0;
  for (var i = 0; i < 16; i++) {
    hash = (hash * 31 +
            sorted[0].codeUnitAt(i % sorted[0].length) +
            sorted[1].codeUnitAt(i % sorted[1].length)) &
        0x7FFFFFFF;
  }
  return hash;
}

class IncomingMessage {
  final String fromId; // Ed25519 public key отправителя
  final String text;
  final DateTime timestamp;
  final String msgId; // pre-generated ID для дедупликации
  const IncomingMessage({
    required this.fromId,
    required this.text,
    required this.timestamp,
    required this.msgId,
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  VoiceService.instance.configureNavigator(navigatorKey);
  if (RuntimePlatform.isDesktopWindows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  // В release-сборке полностью глушим debugPrint — на iOS он в противном случае
  // бьёт по производительности (лог в stderr через native bridge).
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // UI: Google Sans; на Android — ещё Noto Color Emoji (ближе к «яблочному» виду).
  try {
    final pending = <dynamic>[GoogleFonts.googleSans()];
    if (RuntimePlatform.isAndroid) pending.add(GoogleFonts.notoColorEmoji());
    await GoogleFonts.pendingFonts(pending);
  } catch (_) {}
  runApp(const ProviderScope(child: RlinkApp()));
}

Future<void> initServices() async {
  // Bootstrap only forwarding early; do NOT reset receive handlers here.
  // Full GossipRouter.init with all callbacks is configured later in init.
  GossipRouter.instance.ensureForward(
    onForward: (packet) async => packetTransport.forward(packet),
    myKey: CryptoService.instance.publicKeyHex,
  );
  debugPrint('[RLINK][Init] GossipRouter forward bootstrap installed');
  try {
    await initWebStorageIfNeeded();
    await BrowserCacheService.instance.init();
    // Запрашиваем все необходимые разрешения при первом запуске
    if (RuntimePlatform.isAndroid) {
      await [
        Permission.camera,
        Permission.microphone,
        Permission.location,
        Permission.locationWhenInUse,
        Permission.photos,
        Permission.storage,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.notification,
      ].request();
    } else if (RuntimePlatform.isIos) {
      await [
        Permission.camera,
        Permission.microphone,
        Permission.location,
        Permission.locationWhenInUse,
        Permission.photos,
        Permission.bluetooth,
        Permission.notification,
      ].request();
    }

    await AppSettings.instance.init();
    await ChatInboxService.instance.init();
    EtherService.instance.init();
    await ImageService.instance
        .init(); // Must be before ProfileService (path resolution)
    await StickerCollectionService.instance.ensureInitialized();
    await CryptoService.instance.init();
    await _restoreAdminPasswordFromSealedIfNeeded();
    await ProfileService.instance.init();
    await ChatStorageService.instance.init();
    await ChannelService.instance.init();
    await GroupService.instance.init();
    if (AppSettings.instance.isLinkedChildDevice) {
      await ChatStorageService.instance.deleteAllDirectMessages();
      await GroupService.instance.resetAll();
      await ChannelService.instance.resetAll();
      EtherService.instance.messages.value = const [];
      EtherService.instance.unreadCount.value = 0;
    }
    await StoryService.instance.init();
    await MediaUploadQueue.instance.init();
    await MediaUploadQueue.instance.cleanUp();
    await OutboxService.instance.init();
    await BroadcastOutboxService.instance.init();
    ScheduledDmService.instance.start();
    await NotificationService.instance.init();
    unawaited(NotificationService.instance.requestPermissions());

    // Restore X25519 keys from contacts DB (survive app restarts)
    try {
      final savedContacts = await ChatStorageService.instance.getContacts();
      for (final c in savedContacts) {
        if (c.x25519Key != null && c.x25519Key!.isNotEmpty) {
          BleService.instance
              .registerPeerX25519Key(c.publicKeyHex, c.x25519Key!);
        }
      }
      debugPrint(
          '[RLINK][Init] Loaded ${savedContacts.where((c) => c.x25519Key != null && c.x25519Key!.isNotEmpty).length} X25519 keys from DB');
    } catch (e) {
      debugPrint('[RLINK][Init] Failed to load X25519 keys: $e');
    }

    // Populate ether name filter with known contacts + own name
    _updateEtherNameFilter();

    GossipRouter.instance.init(
      myKey: CryptoService.instance.publicKeyHex,
      onMessage: (fromId, encrypted, messageId, replyToMessageId,
          {double? latitude,
          double? longitude,
          String? forwardFromId,
          String? forwardFromNick,
          String? forwardFromChannelId}) async {
        debugPrint(
            '[Main] onMessage fromId=${fromId.substring(0, 16)} ephemeral=${encrypted.ephemeralPublicKey.isEmpty ? "empty" : "set"}');

        // Заблокированный отправитель — молча выкидываем сообщение.
        if (BlockService.instance.isBlocked(fromId)) {
          debugPrint(
              '[Block] Dropped text from blocked ${fromId.substring(0, 8)}');
          return;
        }

        final String text;
        if (encrypted.ephemeralPublicKey.isEmpty) {
          // raw (plaintext) message — cipherText contains the actual text
          if (encrypted.cipherText.isEmpty) return;
          text = encrypted.cipherText;
        } else {
          // encrypted msg — validate all fields before decrypting
          if (encrypted.nonce.isEmpty ||
              encrypted.cipherText.isEmpty ||
              encrypted.mac.isEmpty) {
            debugPrint(
                '[RLINK][Main] Dropping malformed encrypted message (missing fields)');
            return;
          }
          final plaintext =
              await CryptoService.instance.decryptMessage(encrypted);
          if (plaintext == null) {
            debugPrint(
                '[RLINK][Main] Decryption failed! from=${fromId.substring(0, 16)} msgId=$messageId');
            debugPrint(
                '[RLINK][Main] Trying fallback: x25519 key present=${BleService.instance.getPeerX25519Key(fromId) != null}');
            return;
          }
          text = plaintext;
        }

        final now = DateTime.now();
        final msgId = messageId;

        final chInv = InviteDmCodec.tryDecodeChannelInvite(text);
        if (chInv != null) {
          final channelId = chInv['channelId'] as String?;
          final channelName = chInv['channelName'] as String?;
          final adminId = chInv['adminId'] as String?;
          final inviterId = chInv['inviterId'] as String?;
          final inviterNick = chInv['inviterNick'] as String?;
          if (channelId != null &&
              channelName != null &&
              adminId != null &&
              inviterId != null &&
              inviterNick != null) {
            ChannelService.instance.addChannelInvite(ChannelInvite(
              channelId: channelId,
              channelName: channelName,
              adminId: adminId,
              inviterId: inviterId,
              inviterNick: inviterNick,
              avatarColor: chInv['avatarColor'] as int? ?? 0xFF42A5F5,
              avatarEmoji: chInv['avatarEmoji'] as String? ?? '📢',
              description: chInv['description'] as String?,
              createdAt: chInv['createdAt'] as int? ??
                  DateTime.now().millisecondsSinceEpoch,
            ));
            final preview = InviteDmCodec.channelInvitePreview(chInv);
            final inviteJson = jsonEncode({'kind': 'channel', ...chInv});
            await ChatStorageService.instance.saveMessage(ChatMessage(
              id: msgId,
              peerId: fromId,
              text: preview,
              invitePayloadJson: inviteJson,
              replyToMessageId: replyToMessageId,
              latitude: latitude,
              longitude: longitude,
              isOutgoing: false,
              timestamp: now,
              status: MessageStatus.delivered,
              forwardFromId: forwardFromId,
              forwardFromNick: forwardFromNick,
              forwardFromChannelId: forwardFromChannelId,
            ));
            await GossipRouter.instance.sendAck(
              messageId: msgId,
              senderId: CryptoService.instance.publicKeyHex,
              recipientId: fromId,
            );
            if (AppSettings.instance.notificationsEnabled) {
              try {
                final contact =
                    await ChatStorageService.instance.getContact(fromId);
                final senderName =
                    contact?.nickname ?? '${fromId.substring(0, 8)}…';
                await NotificationService.instance.showPersonalMessage(
                  peerId: fromId,
                  title: senderName,
                  body: preview.length > 60
                      ? '${preview.substring(0, 60)}…'
                      : preview,
                );
              } catch (_) {}
            }
            incomingMessageController.add(IncomingMessage(
              fromId: fromId,
              text: preview,
              timestamp: now,
              msgId: msgId,
            ));
            return;
          }
        }

        final grInv = InviteDmCodec.tryDecodeGroupInvite(text);
        if (grInv != null) {
          final groupId = grInv['groupId'] as String?;
          final groupName = grInv['groupName'] as String?;
          final invId = grInv['inviterId'] as String?;
          final invNick = grInv['inviterNick'] as String?;
          final creatorId = grInv['creatorId'] as String?;
          final rawMembers = grInv['memberIds'];
          if (groupId != null &&
              groupName != null &&
              invId != null &&
              invNick != null &&
              creatorId != null &&
              rawMembers is List) {
            final memberIds = rawMembers.cast<String>();
            GroupService.instance.addInvite(GroupInvite(
              groupId: groupId,
              groupName: groupName,
              inviterId: invId,
              inviterNick: invNick,
              creatorId: creatorId,
              memberIds: memberIds,
              avatarColor: grInv['avatarColor'] as int? ?? 0xFF5C6BC0,
              avatarEmoji: grInv['avatarEmoji'] as String? ?? '👥',
              createdAt: grInv['createdAt'] as int? ??
                  DateTime.now().millisecondsSinceEpoch,
            ));
            final preview = InviteDmCodec.groupInvitePreview(grInv);
            final inviteJson = jsonEncode({'kind': 'group', ...grInv});
            await ChatStorageService.instance.saveMessage(ChatMessage(
              id: msgId,
              peerId: fromId,
              text: preview,
              invitePayloadJson: inviteJson,
              replyToMessageId: replyToMessageId,
              latitude: latitude,
              longitude: longitude,
              isOutgoing: false,
              timestamp: now,
              status: MessageStatus.delivered,
              forwardFromId: forwardFromId,
              forwardFromNick: forwardFromNick,
              forwardFromChannelId: forwardFromChannelId,
            ));
            await GossipRouter.instance.sendAck(
              messageId: msgId,
              senderId: CryptoService.instance.publicKeyHex,
              recipientId: fromId,
            );
            if (AppSettings.instance.notificationsEnabled) {
              try {
                final contact =
                    await ChatStorageService.instance.getContact(fromId);
                final senderName =
                    contact?.nickname ?? '${fromId.substring(0, 8)}…';
                await NotificationService.instance.showPersonalMessage(
                  peerId: fromId,
                  title: senderName,
                  body: preview.length > 60
                      ? '${preview.substring(0, 60)}…'
                      : preview,
                );
              } catch (_) {}
            }
            incomingMessageController.add(IncomingMessage(
              fromId: fromId,
              text: preview,
              timestamp: now,
              msgId: msgId,
            ));
            return;
          }
        }

        // Сохраняем сообщение в БД (peerId = fromId = public key).
        // Контакт НЕ создаётся автоматически — только через pair_req/pair_acc.
        // Web exception: without BLE pairing flow, unknown relay peers would stay
        // invisible in contacts/chat list; create a lightweight placeholder.
        if (RuntimePlatform.isWeb) {
          final existing = await ChatStorageService.instance.getContact(fromId);
          if (existing == null) {
            await ChatStorageService.instance.saveContact(
              Contact(
                publicKeyHex: fromId,
                nickname: '${fromId.substring(0, 8)}...',
                avatarColor: 0xFF607D8B,
                avatarEmoji: '',
                addedAt: DateTime.now(),
              ),
            );
          }
        }
        await ChatStorageService.instance.saveMessage(ChatMessage(
          id: msgId,
          peerId: fromId,
          text: text,
          replyToMessageId: replyToMessageId,
          latitude: latitude,
          longitude: longitude,
          isOutgoing: false,
          timestamp: now,
          status: MessageStatus.delivered,
          forwardFromId: forwardFromId,
          forwardFromNick: forwardFromNick,
          forwardFromChannelId: forwardFromChannelId,
        ));

        // Notify sender that we have stored the message.
        await GossipRouter.instance.sendAck(
          messageId: msgId,
          senderId: CryptoService.instance.publicKeyHex,
          recipientId: fromId,
        );

        // Local notification for incoming messages (Android + iOS)
        if (AppSettings.instance.notificationsEnabled) {
          try {
            final contact =
                await ChatStorageService.instance.getContact(fromId);
            final senderName =
                contact?.nickname ?? '${fromId.substring(0, 8)}…';
            final preview =
                text.length > 60 ? '${text.substring(0, 60)}…' : text;
            // Локальные уведомления только через NotificationService (threadId на iOS),
            // без дублирующего нативного showNotification — иначе двойной badge/двойной тост.
            await NotificationService.instance.showPersonalMessage(
              peerId: fromId,
              title: senderName,
              body: preview,
            );
          } catch (_) {}
        }

        debugPrint(
            '[Main] Adding to stream: fromId=${fromId.substring(0, 16)}');
        incomingMessageController.add(IncomingMessage(
          fromId: fromId,
          text: text,
          timestamp: now,
          msgId: msgId,
        ));
      },
      onAck: (fromId, messageId) async {
        // fromId reserved for protocol symmetry; keep referenced to satisfy lints.
        if (fromId.isEmpty) return;
        await ChatStorageService.instance.updateMessageStatus(
          messageId,
          MessageStatus.delivered,
        );
        unawaited(DeviceLinkSyncService.instance.mirrorAckDelivered(messageId));
      },
      onForward: (packet) async => packetTransport.forward(packet),
      onEdit: (fromId, messageId, newText) async {
        final existing =
            await ChatStorageService.instance.getMessageById(messageId);
        var merged = newText;
        if (existing != null) {
          if (SharedTodoPayload.tryDecode(existing.text) != null &&
              SharedTodoPayload.tryDecode(newText) != null) {
            merged = SharedTodoPayload.mergeRemote(existing.text, newText);
          } else if (SharedCalendarPayload.tryDecode(existing.text) != null &&
              SharedCalendarPayload.tryDecode(newText) != null) {
            merged = SharedCalendarPayload.mergeRemote(existing.text, newText);
          }
        }
        await ChatStorageService.instance.editMessage(messageId, merged);
      },
      onDelete: (fromId, messageId) async {
        await ChatStorageService.instance.deleteMessage(messageId);
      },
      onReact: (fromId, messageId, emoji) async {
        await ChatStorageService.instance
            .toggleReaction(messageId, emoji, fromId);
      },
      onImgMetaReceived: (String fromId,
          String msgId,
          int totalChunks,
          bool isAvatar,
          bool isVoice,
          bool isVideo,
          bool isSquare,
          bool isFile,
          bool isSticker,
          String? fileName,
          bool viewOnce,
          {String? forwardFromId,
          String? forwardFromNick,
          String? forwardFromChannelId}) {
        ImageService.instance.initAssembly(
          msgId,
          totalChunks,
          isAvatar: isAvatar,
          isVoice: isVoice,
          fromId: fromId,
          isVideo: isVideo,
          isSquare: isSquare,
          isFile: isFile,
          isSticker: isSticker,
          fileName: fileName,
          viewOnce: viewOnce,
          forwardFromId: forwardFromId,
          forwardFromNick: forwardFromNick,
          forwardFromChannelId: forwardFromChannelId,
        );
      },
      onEther: (id, text, color, senderId, senderNick,
          {double? lat, double? lng}) {
        debugPrint(
            '[RLINK][Main] onEther: text=${text.substring(0, text.length.clamp(0, 20))} sender=$senderNick');
        EtherService.instance.addMessage(EtherMessage(
          id: id,
          text: text,
          color: color,
          receivedAt: DateTime.now(),
          senderId: senderId,
          senderNick: senderNick,
          latitude: lat,
          longitude: lng,
        ));
      },
      onStory: (storyId, authorId, text, bgColor, textX, textY, textSize) {
        debugPrint(
            '[RLINK][Main] onStory: author=${authorId.substring(0, 16)} text=${text.substring(0, text.length.clamp(0, 20))}');
        StoryService.instance.addStory(StoryItem(
          id: storyId,
          authorId: authorId,
          text: text,
          bgColor: bgColor,
          createdAt: DateTime.now(),
          textX: textX,
          textY: textY,
          textSize: textSize,
        ));
      },
      onPairReq:
          (bleId, publicKey, nick, username, color, emoji, x25519Key, tags) {
        // Игнорируем pair-запросы от заблокированных.
        if (BlockService.instance.isBlocked(publicKey)) {
          debugPrint(
              '[Block] Dropped pair_req from blocked ${publicKey.substring(0, 8)}');
          return;
        }
        debugPrint('[RLINK][Main] Pair request from $nick ($bleId)');
        // Store x25519 key and username
        if (x25519Key.isNotEmpty) {
          BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
          unawaited(ChatStorageService.instance
              .updateContactX25519Key(publicKey, x25519Key));
        }
        if (username.isNotEmpty) {
          RelayService.instance.registerPeerUsername(publicKey, username);
        }
        final info = <String, dynamic>{
          'sourceId': bleId,
          'publicKey': publicKey,
          'nick': nick,
          'username': username,
          'color': color,
          'emoji': emoji,
          'x25519Key': x25519Key,
          'tags': tags,
        };
        BleService.instance.addPairRequest(bleId, info);
        // Бумшшшш! + открываем полноэкранный баннер
        boomVibration();
        // Retry mechanism — Navigator context may be null during transitions
        void tryShowScreen(int attempt) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = navigatorKey.currentContext;
            if (ctx != null) {
              try {
                showPairRequestScreen(ctx, bleId, info);
              } catch (e) {
                debugPrint('[RLINK][Main] showPairRequestScreen error: $e');
              }
            } else if (attempt < 5) {
              debugPrint(
                  '[RLINK][Main] Navigator ctx null, retry ${attempt + 1}/5');
              Future.delayed(const Duration(milliseconds: 300),
                  () => tryShowScreen(attempt + 1));
            } else {
              debugPrint(
                  '[RLINK][Main] Could not show pair screen after 5 retries');
            }
          });
        }

        tryShowScreen(0);
      },
      onPairAcc: (bleId, publicKey, nick, username, color, emoji, x25519Key,
          tags) async {
        debugPrint('[RLINK][Main] Pair accepted by $nick ($bleId)');
        BleService.instance.removePairRequest(bleId);
        // Register peer key — always register, even if bleId isn't recognized as direct.
        // pair_acc only comes from directly connected devices (TTL=1).
        BleService.instance.registerPeerKey(bleId, publicKey);
        // Map ALL unmapped BLE IDs (both central & peripheral roles) to this peer.
        // After pair exchange there's only one physical device, so any unmapped ID is it.
        BleService.instance.registerPeerKeyForAllRoles(publicKey);
        if (x25519Key.isNotEmpty) {
          BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
          unawaited(ChatStorageService.instance
              .updateContactX25519Key(publicKey, x25519Key));
        }
        if (username.isNotEmpty) {
          RelayService.instance.registerPeerUsername(publicKey, username);
        }
        BleService.instance.setExchangeState(publicKey, 3); // complete
        // Force-clear all pending entries for this device
        BleService.instance.clearPendingForPublicKey(publicKey);
        try {
          // Preserve existing contact if present, but prefer the received nick
          // unless the existing nickname was manually set (not an auto-generated hex stub).
          final existing =
              await ChatStorageService.instance.getContact(publicKey);
          final isStub = existing != null &&
              RegExp(r'^[0-9a-fA-F]{8}\.\.\.').hasMatch(existing.nickname);
          await ChatStorageService.instance.saveContact(Contact(
            publicKeyHex: publicKey,
            nickname: (existing != null && !isStub) ? existing.nickname : nick,
            username:
                username.isNotEmpty ? username : (existing?.username ?? ''),
            avatarColor: color,
            avatarEmoji: emoji,
            avatarImagePath: existing?.avatarImagePath,
            x25519Key: x25519Key.isNotEmpty ? x25519Key : existing?.x25519Key,
            addedAt: existing?.addedAt ?? DateTime.now(),
            tags: tags.isNotEmpty ? tags : (existing?.tags ?? const []),
            bannerImagePath: existing?.bannerImagePath,
            profileMusicPath: existing?.profileMusicPath,
            statusEmoji: existing?.statusEmoji ?? '',
          ));
          unawaited(_updateEtherNameFilter());
        } catch (_) {}
        // Send our full profile (profile + avatar + banner) directly to the peer
        final myProfile = ProfileService.instance.profile;
        if (myProfile != null) {
          // Directed relay send (guaranteed delivery) — ждём, чтобы аватар
          // и баннер ушли ДО показа экрана празднования. Иначе у получателя
          // успевает сохраниться только метадата профиля (эмодзи/тег) без
          // картинок.
          await _sendFullProfileToPeer(publicKey);
          // Also broadcast via gossip for BLE peers
          await GossipRouter.instance.broadcastProfile(
            id: myProfile.publicKeyHex,
            nick: myProfile.nickname,
            username: myProfile.username,
            color: myProfile.avatarColor,
            emoji: myProfile.avatarEmoji,
            x25519Key: CryptoService.instance.x25519PublicKeyBase64,
            tags: myProfile.tags,
            statusEmoji: myProfile.statusEmoji,
          );
          // Show celebration screen on sender side
          final myKey = CryptoService.instance.publicKeyHex;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = navigatorKey.currentContext;
            if (ctx != null) {
              showBoomCelebration(ctx, nick, myKey, publicKey);
            }
          });
        }
      },
      onTyping: (fromId, activity) {
        TypingService.instance.update(fromId, activity);
      },
      onImgChunkReceived:
          (fromId, msgId, totalChunks, index, base64Data) async {
        ImageService.instance.receiveChunk(
          msgId: msgId,
          totalChunks: totalChunks,
          index: index,
          base64Data: base64Data,
        );
        if (!ImageService.instance.isComplete(msgId)) return;

        // Dedup: if blob already delivered this media, skip chunk assembly
        if (ImageService.instance.wasAlreadyCompleted(msgId)) {
          ImageService.instance.cancelAssembly(msgId);
          debugPrint(
              '[RLINK][Chunks] msgId=$msgId already completed via blob, skipping');
          return;
        }

        final isAvatar = ImageService.instance.isAvatarAssembly(msgId);
        final isVoice = ImageService.instance.isVoiceAssembly(msgId);
        final isVideo = ImageService.instance.isVideoAssembly(msgId);
        final isSquare = ImageService.instance.isSquareAssembly(msgId);
        final isFile = ImageService.instance.isFileAssembly(msgId);
        final fileName = ImageService.instance.assemblyFileName(msgId);
        final vo = ImageService.instance.isViewOnceAssembly(msgId);
        final ffId = ImageService.instance.assemblyForwardFromId(msgId);
        final ffNick = ImageService.instance.assemblyForwardFromNick(msgId);
        final ffCh = ImageService.instance.assemblyForwardFromChannelId(msgId);
        final isBanner = msgId.startsWith('banner_');
        final senderKey = ImageService.instance.assemblyFromId(msgId).isNotEmpty
            ? ImageService.instance.assemblyFromId(msgId)
            : fromId;

        final skippedBySettings =
            await _handleIncomingMediaWhenAutoDownloadDisabled(
          fromId: senderKey,
          msgId: msgId,
          isAvatar: isAvatar,
          isVoice: isVoice,
          isVideo: isVideo,
          isSquare: isSquare,
          isFile: isFile,
          viewOnce: vo,
          fileName: fileName,
          forwardFromId: ffId,
          forwardFromNick: ffNick,
          forwardFromChannelId: ffCh,
        );
        if (skippedBySettings) {
          ImageService.instance.cancelAssembly(msgId);
          return;
        }

        if (isBanner) {
          // Banner image via BLE chunks — save as contact banner
          final path = await ImageService.instance.assembleAndSave(
            msgId,
            forContactKey: '${senderKey}_banner',
          );
          if (path != null) {
            ImageService.instance.markCompleted(msgId);
            _evictImageCache(path);
            final existing =
                await ChatStorageService.instance.getContact(senderKey);
            if (existing != null) {
              await ChatStorageService.instance.saveContact(existing.copyWith(
                  bannerImagePath: path, setBannerImagePath: true));
              debugPrint(
                  '[RLINK][Banner] Saved BLE banner for ${senderKey.substring(0, 8)}');
            }
          }
        } else if (msgId.startsWith('profile_music_')) {
          final path = await ImageService.instance
              .assembleAndSaveProfileMusic(msgId, senderKey);
          if (path != null) {
            ImageService.instance.markCompleted(msgId);
            final existing =
                await ChatStorageService.instance.getContact(senderKey);
            if (existing != null) {
              await ChatStorageService.instance.saveContact(existing.copyWith(
                  profileMusicPath: path, setProfileMusicPath: true));
              debugPrint(
                  '[RLINK][Music] Saved BLE profile music for ${senderKey.substring(0, 8)}');
            }
          }
        } else if (msgId.startsWith('chbn_')) {
          final compact = msgId.substring('chbn_'.length);
          final path = await ImageService.instance.assembleAndSave(msgId);
          if (path != null) {
            ImageService.instance.markCompleted(msgId);
            _evictImageCache(path);
            await ChannelService.instance
                .applyChannelBannerFromNetwork(compact, path);
          }
        } else if (msgId.startsWith('chav_')) {
          final compact = msgId.substring('chav_'.length);
          final path = await ImageService.instance.assembleAndSave(msgId);
          if (path != null) {
            ImageService.instance.markCompleted(msgId);
            _evictImageCache(path);
            await ChannelService.instance
                .applyChannelAvatarFromNetwork(compact, path);
          }
        } else if (isAvatar) {
          final path = await ImageService.instance.assembleAndSave(
            msgId,
            forContactKey: senderKey,
          );
          if (path != null) {
            ImageService.instance.markCompleted(msgId);
            _evictImageCache(path);
            await ChatStorageService.instance
                .updateContactAvatarImage(senderKey, path);
          }
        } else if (isVoice) {
          final path = await ImageService.instance.assembleAndSaveVoice(msgId);
          if (path == null) return;
          ImageService.instance.markCompleted(msgId);
          if (await ChannelService.instance.getPost(msgId) != null) {
            await ChannelService.instance.applyAssembledPostMedia(
              postId: msgId,
              voicePath: path,
            );
            return;
          }
          if (await ChannelService.instance.getComment(msgId) != null) {
            await ChannelService.instance.applyAssembledCommentMedia(
              commentId: msgId,
              voicePath: path,
            );
            return;
          }
          final msg = ChatMessage(
            id: msgId,
            peerId: senderKey,
            text: '🎤 Голосовое',
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
            voicePath: path,
            viewOnce: vo,
            forwardFromId: ffId,
            forwardFromNick: ffNick,
            forwardFromChannelId: ffCh,
          );
          await ChatStorageService.instance.saveMessage(msg);
          incomingMessageController.add(IncomingMessage(
            fromId: senderKey,
            text: '🎤 Голосовое',
            timestamp: msg.timestamp,
            msgId: msgId,
          ));
          final myK = CryptoService.instance.publicKeyHex;
          if (myK.isNotEmpty) {
            unawaited(GossipRouter.instance.sendAck(
                messageId: msgId, senderId: myK, recipientId: senderKey));
          }
        } else if (isFile) {
          final origName = fileName;
          final path = await ImageService.instance.assembleAndSaveFile(msgId);
          if (path == null) return;
          ImageService.instance.markCompleted(msgId);
          if (await ChannelService.instance.getPost(msgId) != null) {
            final sz = await File(path).length();
            await ChannelService.instance.applyAssembledPostMedia(
              postId: msgId,
              filePath: path,
              fileName: origName,
              fileSize: sz,
            );
            return;
          }
          if (await ChannelService.instance.getComment(msgId) != null) {
            final sz = await File(path).length();
            await ChannelService.instance.applyAssembledCommentMedia(
              commentId: msgId,
              filePath: path,
              fileName: origName,
              fileSize: sz,
            );
            return;
          }
          final fileLabel = '📎 ${origName ?? 'Файл'}';
          final fileBytes = await File(path).length();
          final msg = ChatMessage(
            id: msgId,
            peerId: senderKey,
            text: fileLabel,
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
            filePath: path,
            fileName: origName,
            fileSize: fileBytes,
            viewOnce: vo,
            forwardFromId: ffId,
            forwardFromNick: ffNick,
            forwardFromChannelId: ffCh,
          );
          await ChatStorageService.instance.saveMessage(msg);
          incomingMessageController.add(IncomingMessage(
            fromId: senderKey,
            text: fileLabel,
            timestamp: msg.timestamp,
            msgId: msgId,
          ));
          final myK2 = CryptoService.instance.publicKeyHex;
          if (myK2.isNotEmpty) {
            unawaited(GossipRouter.instance.sendAck(
                messageId: msgId, senderId: myK2, recipientId: senderKey));
          }
        } else if (isVideo) {
          final path = await ImageService.instance
              .assembleAndSaveVideo(msgId, isSquare: isSquare);
          if (path == null) return;
          ImageService.instance.markCompleted(msgId);
          if (await ChannelService.instance.getPost(msgId) != null) {
            await ChannelService.instance.applyAssembledPostMedia(
              postId: msgId,
              videoPath: path,
            );
            return;
          }
          if (await ChannelService.instance.getComment(msgId) != null) {
            await ChannelService.instance.applyAssembledCommentMedia(
              commentId: msgId,
              videoPath: path,
            );
            return;
          }
          if (await GroupService.instance.getMessage(msgId) != null) {
            await GroupService.instance.applyAssembledVideo(msgId, path);
            return;
          }
          final label = isSquare ? '⬛ Видео' : '📹 Видео';
          final msg = ChatMessage(
            id: msgId,
            peerId: senderKey,
            text: label,
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
            videoPath: path,
            viewOnce: vo,
            forwardFromId: ffId,
            forwardFromNick: ffNick,
            forwardFromChannelId: ffCh,
          );
          await ChatStorageService.instance.saveMessage(msg);
          incomingMessageController.add(IncomingMessage(
            fromId: senderKey,
            text: label,
            timestamp: msg.timestamp,
            msgId: msgId,
          ));
          final myK3 = CryptoService.instance.publicKeyHex;
          if (myK3.isNotEmpty) {
            unawaited(GossipRouter.instance.sendAck(
                messageId: msgId, senderId: myK3, recipientId: senderKey));
          }
        } else {
          final path = await ImageService.instance.assembleAndSave(msgId);
          if (path == null) return;
          ImageService.instance.markCompleted(msgId);

          if (await ChannelService.instance.getPost(msgId) != null) {
            await ChannelService.instance.applyAssembledPostMedia(
              postId: msgId,
              imagePath: path,
            );
            return;
          }
          if (await ChannelService.instance.getComment(msgId) != null) {
            await ChannelService.instance.applyAssembledCommentMedia(
              commentId: msgId,
              imagePath: path,
            );
            return;
          }
          if (await GroupService.instance.getMessage(msgId) != null) {
            await GroupService.instance.applyAssembledImage(msgId, path);
            return;
          }

          // Check if this image belongs to a story (msgId == storyId)
          final existingStory = StoryService.instance.findStory(msgId);
          if (existingStory != null) {
            existingStory.imagePath = path;
            StoryService.instance.notifyUpdate();
            debugPrint(
                '[RLINK][Main] Story image received for ${msgId.substring(0, 8)}');
            return;
          }

          // Story gossip packet may arrive after image chunks — cache the image
          // so addStory() can attach it when the story packet arrives.
          // Also proceed to save as a chat message (dedup: if it IS a story image
          // StoryService.addStory will pick it up from the pending cache).
          StoryService.instance.cachePendingImage(msgId, path);

          final msg = ChatMessage(
            id: msgId,
            peerId: senderKey,
            text: '',
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
            imagePath: path,
            viewOnce: vo,
            forwardFromId: ffId,
            forwardFromNick: ffNick,
            forwardFromChannelId: ffCh,
          );
          await ChatStorageService.instance.saveMessage(msg);
          incomingMessageController.add(IncomingMessage(
            fromId: senderKey,
            text: '',
            timestamp: msg.timestamp,
            msgId: msgId,
          ));
          final myK4 = CryptoService.instance.publicKeyHex;
          if (myK4.isNotEmpty) {
            unawaited(GossipRouter.instance.sendAck(
                messageId: msgId, senderId: myK4, recipientId: senderKey));
          }
        }
      },
      // bleId — BLE device ID источника пакета (для маппинга)
      // publicKey — Ed25519 ключ из payload профиля
      // x25519Key — X25519 ключ base64 для E2E шифрования (пустая строка у старых версий)
      onProfile: (bleId, publicKey, nick, username, color, emoji, x25519Key,
          tags, statusEmojiPayload) async {
        // В Internet-only режиме игнорируем BLE профили — не нужны маппинги
        final mode = AppSettings.instance.connectionMode;
        // Регистрируем маппинг BLE ID → publicKey ТОЛЬКО для прямых пиров и НЕ в Internet-only.
        final isDirect = BleService.instance.isDirectBleId(bleId);
        if (isDirect && mode != 1) {
          BleService.instance.registerPeerKey(bleId, publicKey);
        }
        // X25519 ключ сохраняем для любого профиля (прямого или пересланного).
        if (x25519Key.isNotEmpty) {
          BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
          unawaited(ChatStorageService.instance
              .updateContactX25519Key(publicKey, x25519Key));
        }
        // Запоминаем username в relay-кеше для поиска
        if (username.isNotEmpty) {
          RelayService.instance.registerPeerUsername(publicKey, username);
        }

        // Контакт сохраняем в БД при любом профиле (прямом или пересланном).
        // finally гарантирует markProfileReceived даже при ошибке БД.
        try {
          final existing =
              await ChatStorageService.instance.getContact(publicKey);
          String resolvedStatus(Contact? ex, Contact? oldC) {
            if (statusEmojiPayload != null) {
              return UserProfile.normalizeStatusEmoji(statusEmojiPayload);
            }
            return ex?.statusEmoji ?? oldC?.statusEmoji ?? '';
          }

          // Ищем ник-дубликат или стаб-контакт:
          // Кейс 1: сообщение пришло раньше профиля → стаб (key=X, nick="X1234...").
          // Кейс 2: смена ключа (переустановка) — профиль может прийти через gossip.
          // Кейс 3: контакт создан под BLE UUID до обмена профилями.
          Contact? oldContact;
          final allContactsForDedup =
              await ChatStorageService.instance.getContacts();

          // Сначала ищем стаб-контакт (ник выглядит как hex-префикс ключа)
          final hexStubRe = RegExp(r'^[0-9a-fA-F]{6,}');
          try {
            oldContact = allContactsForDedup.firstWhere(
              (c) =>
                  c.publicKeyHex != publicKey &&
                  (c.nickname == nick || // ник совпадает — ротация ключа
                      (hexStubRe.hasMatch(c.nickname.replaceAll('...', '')) &&
                          publicKey.startsWith(c.nickname.replaceAll(
                              '...', ''))) // стаб с hex-префиксом нашего ключа
                  ),
            );
          } catch (_) {
            oldContact = null;
          }

          // Дополнительно: если для прямого пира есть BLE UUID-контакт — удалить/перенести
          if (isDirect && oldContact == null) {
            try {
              oldContact = allContactsForDedup.firstWhere(
                (c) =>
                    c.publicKeyHex != publicKey &&
                    c.publicKeyHex == bleId, // контакт создан под BLE UUID
              );
            } catch (_) {
              oldContact = null;
            }
          }

          if (existing == null) {
            if (oldContact != null) {
              // Стаб или смена ключа: переносим историю и удаляем старый
              debugPrint('[Profile] Merging stub/rotated contact for $nick: '
                  '${oldContact.publicKeyHex.substring(0, 8)} → ${publicKey.substring(0, 8)}');
              await ChatStorageService.instance
                  .migrateMessages(oldContact.publicKeyHex, publicKey);
              await ChatStorageService.instance.saveContact(Contact(
                publicKeyHex: publicKey,
                nickname: nick,
                username: username.isNotEmpty ? username : oldContact.username,
                avatarColor: color,
                avatarEmoji: emoji,
                avatarImagePath: oldContact.avatarImagePath,
                addedAt: oldContact.addedAt,
                tags: tags.isNotEmpty ? tags : oldContact.tags,
                bannerImagePath: oldContact.bannerImagePath,
                statusEmoji: resolvedStatus(null, oldContact),
              ));
              await ChatStorageService.instance
                  .deleteContact(oldContact.publicKeyHex);
            } else {
              // No existing contact and no stub — skip auto-creation.
              // Contacts are only created via explicit user action (pair_acc / Add button).
              debugPrint(
                  '[Profile] Skipped auto-save for unknown peer: $nick (key: ${publicKey.substring(0, 8)}...) isDirect=$isDirect');
            }
          } else {
            // Обновляем существующий контакт
            await ChatStorageService.instance.updateContact(Contact(
              publicKeyHex: publicKey,
              nickname: nick,
              username: username.isNotEmpty ? username : existing.username,
              avatarColor: color,
              avatarEmoji: emoji,
              avatarImagePath: existing.avatarImagePath,
              x25519Key: existing.x25519Key,
              addedAt: existing.addedAt,
              tags: tags.isNotEmpty ? tags : existing.tags,
              bannerImagePath: existing.bannerImagePath,
              profileMusicPath: existing.profileMusicPath,
              statusEmoji: resolvedStatus(existing, null),
            ));
            // Если нашли ник-дубликат или стаб с другим ключом — переносим историю и удаляем
            if (oldContact != null) {
              debugPrint('[Profile] Removing duplicate/stub for $nick: '
                  '${oldContact.publicKeyHex.substring(0, 8)} (kept ${publicKey.substring(0, 8)})');
              await ChatStorageService.instance
                  .migrateMessages(oldContact.publicKeyHex, publicKey);
              await ChatStorageService.instance
                  .deleteContact(oldContact.publicKeyHex);
            } else {
              debugPrint(
                  '[Profile] Updated contact: $nick (key: ${publicKey.substring(0, 8)}...) direct=$isDirect');
            }
          }

          // Post-merge cleanup (Android fix): scan message threads for stub peer IDs
          // that look like a hex prefix of this public key but have no contact entry.
          // This handles the case where messages arrived before the profile and were
          // stored under a short hex stub ID that the contact dedup above missed.
          final stubRe = RegExp(r'^[0-9a-fA-F]+$');
          final allPeerIds = await ChatStorageService.instance.getChatPeerIds();
          for (final pid in allPeerIds) {
            if (pid == publicKey) continue;
            // Normalise: strip trailing "..." if present
            final cleanPid =
                pid.endsWith('...') ? pid.replaceAll('...', '') : pid;
            // Only migrate if pid looks like a short hex stub (6–16 chars)
            // that is a prefix of the incoming public key.
            if (cleanPid.length >= 6 &&
                cleanPid.length <= 16 &&
                stubRe.hasMatch(cleanPid) &&
                publicKey.toLowerCase().startsWith(cleanPid.toLowerCase())) {
              debugPrint(
                  '[Profile] Migrating stub message thread $pid → ${publicKey.substring(0, 8)}');
              await ChatStorageService.instance.migrateMessages(pid, publicKey);
              final stubContact =
                  await ChatStorageService.instance.getContact(pid);
              if (stubContact != null) {
                await ChatStorageService.instance.deleteContact(pid);
              }
            }
          }

          // BLE UUID thread migration: if the user sent messages before profile
          // exchange, those messages are stored under the BLE device UUID (not
          // the public key). Migrate them so they merge into a single thread.
          if (isDirect && bleId != publicKey && allPeerIds.contains(bleId)) {
            debugPrint(
                '[Profile] Migrating BLE UUID thread $bleId → ${publicKey.substring(0, 8)}');
            await ChatStorageService.instance.migrateMessages(bleId, publicKey);
            final bleContact =
                await ChatStorageService.instance.getContact(bleId);
            if (bleContact != null) {
              await ChatStorageService.instance.deleteContact(bleId);
            }
          }
        } catch (e) {
          debugPrint('[Profile] DB error saving contact: $e');
        } finally {
          // Убираем лоадер для прямого пира
          if (isDirect) {
            BleService.instance.markProfileReceived(bleId);
          }
          // Очищаем все pending-записи для этого публичного ключа (обе стороны BLE)
          BleService.instance.clearPendingForPublicKey(publicKey);
          // Update ether anti-bullying filter with new contact
          unawaited(_updateEtherNameFilter());
        }

        // Если мы получили профиль от контакта (прямое соединение) —
        // отправляем наш аватар в ответ (на случай если первая отправка потерялась).
        if (isDirect) {
          final myProfile = ProfileService.instance.profile;
          if (myProfile != null) {
            final avatarPath = ImageService.instance
                .resolveStoredPath(myProfile.avatarImagePath);
            if (avatarPath != null) {
              unawaited(_broadcastAvatar(myProfile.publicKeyHex, avatarPath));
            }
          }
        }
      },
    );

    GossipRouter.instance.onDeviceLinkRequest = (_, publicKey, nick, username) {
      if (BlockService.instance.isBlocked(publicKey)) return;
      final me = ProfileService.instance.profile;
      if (me == null) return;
      if (publicKey.toLowerCase() == me.publicKeyHex.toLowerCase()) {
        // Ignore own reflected request packets from mesh/relay.
        return;
      }

      Future<void> sendAck(bool accepted) async {
        await GossipRouter.instance.sendDeviceLinkAck(
          publicKey: me.publicKeyHex,
          nick: me.nickname,
          recipientId: publicKey,
          accepted: accepted,
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ctx = navigatorKey.currentContext;
        if (ctx == null) {
          await sendAck(false);
          return;
        }
        final settings = AppSettings.instance;
        final alreadyLinked = settings.isDeviceLinked;
        final linkedToSame =
            settings.linkedDevicePublicKey.toLowerCase() == publicKey;
        if ((alreadyLinked && !linkedToSame) || settings.isPrimaryDevice) {
          await sendAck(false);
          if (ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(
                content: Text('Связка уже активна на этом устройстве'),
              ),
            );
          }
          return;
        }
        final requesterTitle = nick.isEmpty ? publicKey.substring(0, 8) : nick;
        final invitePayload = jsonEncode({
          'kind': 'device_link',
          'publicKey': publicKey,
          'nick': nick,
          'username': username,
        });
        await ChatStorageService.instance.saveMessage(
          ChatMessage(
            id: const Uuid().v4(),
            peerId: publicKey,
            text:
                '$requesterTitle хочет привязать это устройство как дочернее',
            invitePayloadJson: invitePayload,
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
          ),
        );
        incomingMessageController.add(
          IncomingMessage(
            fromId: publicKey,
            text: 'Запрос на связку устройств',
            timestamp: DateTime.now(),
            msgId: const Uuid().v4(),
          ),
        );
        if (AppSettings.instance.notificationsEnabled) {
          await NotificationService.instance.showPersonalMessage(
            peerId: publicKey,
            title: requesterTitle,
            body: 'Запрос на связку устройств',
          );
        }
      });
    };

    GossipRouter.instance.onDeviceLinkAck =
        (_, publicKey, nick, accepted) async {
      final ctx = navigatorKey.currentContext;
      if (!accepted) {
        if (ctx != null && ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
              content: Text('Запрос связки отклонён на другом устройстве'),
            ),
          );
        }
        return;
      }
      await AppSettings.instance.linkAsPrimaryDevice(
        devicePublicKey: publicKey,
        deviceNickname: nick,
      );
      await applyConnectionTransport();
      if (ctx != null && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('Связка устройств активирована'),
          ),
        );
      }
    };

    GossipRouter.instance.onDeviceUnlink = (_, publicKey) {
      unawaited(() async {
        final settings = AppSettings.instance;
        if (!settings.isDeviceLinked) return;
        if (settings.linkedDevicePublicKey.toLowerCase() != publicKey) return;
        await settings.unlinkDevice();
        DeviceLinkSyncService.instance.onUnlinked();
        await applyConnectionTransport();
        final ctx = navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
              content: Text('Связка устройств была снята на другом устройстве'),
            ),
          );
        }
      }());
    };

    await DeviceLinkSyncService.instance.init();

    // ── Channel/Group packet handlers ──────────────────────────────
    GossipRouter.instance.onChannelMeta = (payload) {
      unawaited(ChannelService.instance.applyChannelMetaFromPayload(payload));
    };
    GossipRouter.instance.onChannelBackupKey =
        (p) => ChannelBackupService.instance.onKeyPacket(p);
    GossipRouter.instance.onChannelBackupMeta =
        (p) => ChannelBackupService.instance.onMetaPacket(p);
    GossipRouter.instance.onChannelBackupChunk =
        (p) => ChannelBackupService.instance.onChunkPacket(p);
    GossipRouter.instance.onChannelPost = (payload) async {
      final channelId = payload['channelId'] as String?;
      final postId = payload['postId'] as String?;
      final authorId = payload['authorId'] as String?;
      if (channelId == null || postId == null || authorId == null) return;

      final tsOriginal = payload['ts'] as int?;
      final reactionsJson = payload['rx'] as String?;
      final pj = payload['pj'] as String?;
      Map<String, List<String>> reactions = const {};
      if (reactionsJson != null && reactionsJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(reactionsJson) as Map<String, dynamic>;
          reactions =
              decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
        } catch (_) {}
      }

      final existing = await ChannelService.instance.getPost(postId);
      final slRaw = payload['sl'] as String?;
      final staffLabel =
          slRaw != null && slRaw.trim().isNotEmpty ? slRaw.trim() : null;

      if (existing != null) {
        if (reactions.isNotEmpty) {
          final merged = <String, List<String>>{};
          existing.reactions
              .forEach((k, v) => merged[k] = List<String>.from(v));
          reactions.forEach((k, v) {
            final set = <String>{...(merged[k] ?? const []), ...v};
            merged[k] = set.toList();
          });
          await ChannelService.instance
              .updatePostReactions(postId, clampReactionsMapPerUser(merged));
        }
        if (pj != null && pj.isNotEmpty) {
          await ChannelService.instance.mergeIncomingPostPoll(postId, pj);
        }
        if (staffLabel != null && staffLabel != existing.staffLabel) {
          await ChannelService.instance
              .updatePostStaffLabel(postId, staffLabel);
        }
        return;
      }

      await ChannelService.instance.savePost(ChannelPost(
        id: postId,
        channelId: channelId,
        authorId: authorId,
        text: payload['text'] as String? ?? '',
        timestamp: tsOriginal ?? DateTime.now().millisecondsSinceEpoch,
        reactions: clampReactionsMapPerUser(reactions),
        pollJson: (pj != null && pj.isNotEmpty) ? pj : null,
        staffLabel: staffLabel,
        isSticker: (payload['stk'] as bool?) ?? false,
      ));
      await ChannelService.instance.flushPendingMediaForPost(postId);

      final myKey = CryptoService.instance.publicKeyHex;
      if (authorId != myKey) {
        final ch = await ChannelService.instance.getChannel(channelId);
        // Уведомляем только подписчиков (это их канал).
        if (ch != null &&
            (ch.subscriberIds.contains(myKey) ||
                ch.moderatorIds.contains(myKey) ||
                ch.linkAdminIds.contains(myKey) ||
                ch.adminId == myKey)) {
          final preview = (payload['text'] as String? ?? '').isEmpty
              ? 'Новый пост'
              : (payload['text'] as String).length > 80
                  ? '${(payload['text'] as String).substring(0, 80)}…'
                  : (payload['text'] as String);
          await NotificationService.instance.showChannelPost(
            channelId: channelId,
            title: ch.name,
            body: preview,
          );
        }
      }
    };
    GossipRouter.instance.onChannelPostView = (postId, viewerId) {
      unawaited(ChannelService.instance
          .recordPostView(postId, viewerId, rebroadcast: false));
    };
    GossipRouter.instance.onChannelDeletePost = (payload) {
      final postId = payload['postId'] as String?;
      if (postId != null) {
        ChannelService.instance.deletePost(postId);
      }
    };
    GossipRouter.instance.onChannelSubscribe = (payload) {
      final channelId = payload['channelId'] as String?;
      final userId = payload['userId'] as String?;
      final unsub = payload['unsubscribe'] as bool? ?? false;
      if (channelId == null || userId == null) return;
      if (unsub) {
        ChannelService.instance.removeSubscriber(channelId, userId);
      } else {
        unawaited(() async {
          await ChannelService.instance.subscribe(channelId, userId);
          await ChannelService.instance
              .maybeRebroadcastChannelVisualsAfterRemoteSubscribe(channelId);
        }());
      }
    };
    GossipRouter.instance.onChannelInvite = (payload) {
      final channelId = payload['channelId'] as String?;
      final channelName = payload['channelName'] as String?;
      final adminId = payload['adminId'] as String?;
      final inviterId = payload['inviterId'] as String?;
      final inviterNick = payload['inviterNick'] as String?;
      if (channelId == null ||
          channelName == null ||
          adminId == null ||
          inviterId == null ||
          inviterNick == null) {
        return;
      }
      debugPrint('[RLINK] Channel invite: $channelName from $inviterNick');
      ChannelService.instance.addChannelInvite(ChannelInvite(
        channelId: channelId,
        channelName: channelName,
        adminId: adminId,
        inviterId: inviterId,
        inviterNick: inviterNick,
        avatarColor: payload['avatarColor'] as int? ?? 0xFF42A5F5,
        avatarEmoji: payload['avatarEmoji'] as String? ?? '📢',
        description: payload['description'] as String?,
        createdAt: payload['createdAt'] as int? ??
            DateTime.now().millisecondsSinceEpoch,
      ));
    };
    GossipRouter.instance.onChannelHistoryReq = (payload) async {
      final channelId = payload['channelId'] as String?;
      final requesterId = payload['requesterId'] as String?;
      final sinceTs = (payload['sinceTs'] as int?) ?? 0;
      if (channelId == null || requesterId == null) return;
      final me = CryptoService.instance.publicKeyHex;
      if (me.isEmpty || me == requesterId) return;
      // Отвечают все подписчики (а не только админ), чтобы построить P2P-сеть
      // распространения истории канала.
      final ch = await ChannelService.instance.getChannel(channelId);
      if (ch == null) return;
      final amSubscriber = ch.subscriberIds.contains(me) ||
          ch.moderatorIds.contains(me) ||
          ch.linkAdminIds.contains(me) ||
          ch.adminId == me;
      if (!amSubscriber) return;
      // Рандомная задержка 300-2500 мс, чтобы несколько подписчиков не отвечали
      // одновременно и не флудили канал (мягкий thundering-herd avoidance).
      final jitter = 300 + (DateTime.now().microsecondsSinceEpoch % 2200);
      await Future.delayed(Duration(milliseconds: jitter));

      final posts =
          await ChannelService.instance.getPostsNewerThan(channelId, sinceTs);
      for (final post in posts) {
        final rx = post.reactions.isEmpty ? null : jsonEncode(post.reactions);
        await GossipRouter.instance.sendChannelPost(
          channelId: channelId,
          postId: post.id,
          authorId: post.authorId,
          text: post.text,
          timestamp: post.timestamp,
          reactionsJson: rx,
          hasImage: post.imagePath != null,
          hasVideo: post.videoPath != null,
          hasVoice: post.voicePath != null,
          hasFile: post.filePath != null,
          isSticker: post.isSticker,
          fileName: post.fileName,
          pollJson: post.pollJson,
          staffLabel: post.staffLabel,
        );
        await ChannelService.instance.forwardChannelPostMediaIfPresent(post);
        // А также его комментарии.
        for (final c in post.comments) {
          final crx = c.reactions.isEmpty ? null : jsonEncode(c.reactions);
          await GossipRouter.instance.sendChannelComment(
            postId: post.id,
            commentId: c.id,
            authorId: c.authorId,
            text: c.text.trim().isEmpty ? ' ' : c.text,
            timestamp: c.timestamp,
            reactionsJson: crx,
            hasImage: c.imagePath != null,
            hasVideo: c.videoPath != null,
            hasVoice: c.voicePath != null,
            hasFile: c.filePath != null,
            fileName: c.fileName,
          );
          await ChannelService.instance
              .forwardChannelCommentMediaIfPresent(c, c.authorId);
          await Future.delayed(const Duration(milliseconds: 40));
        }
        await Future.delayed(const Duration(milliseconds: 60));
      }
      debugPrint('[RLINK][Channel] Replied to history request for $channelId'
          ' with ${posts.length} posts');
    };
    GossipRouter.instance.onChannelComment = (payload) async {
      final postId = payload['postId'] as String?;
      final commentId = payload['commentId'] as String?;
      final authorId = payload['authorId'] as String?;
      final text = payload['text'] as String? ?? '';
      if (postId == null || commentId == null || authorId == null) return;
      final hasMedia = payload['img'] == true ||
          payload['vid'] == true ||
          payload['voice'] == true ||
          payload['file'] == true;
      if (text.trim().isEmpty && !hasMedia) return;
      final tsOriginal = payload['ts'] as int?;
      final rxJson = payload['rx'] as String?;
      Map<String, List<String>> reactions = const {};
      if (rxJson != null && rxJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(rxJson) as Map<String, dynamic>;
          reactions =
              decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
        } catch (_) {}
      }
      final existing = await ChannelService.instance.getComment(commentId);
      if (existing != null) {
        if (reactions.isNotEmpty) {
          final merged = <String, List<String>>{};
          existing.reactions
              .forEach((k, v) => merged[k] = List<String>.from(v));
          reactions.forEach((k, v) {
            final set = <String>{...(merged[k] ?? const []), ...v};
            merged[k] = set.toList();
          });
          await ChannelService.instance.updateCommentReactions(
              commentId, clampReactionsMapPerUser(merged));
        }
        return;
      }
      await ChannelService.instance.saveComment(ChannelComment(
        id: commentId,
        postId: postId,
        authorId: authorId,
        text: text.trim().isEmpty ? ' ' : text,
        timestamp: tsOriginal ?? DateTime.now().millisecondsSinceEpoch,
        reactions: clampReactionsMapPerUser(reactions),
      ));
      await ChannelService.instance.flushPendingMediaForComment(commentId);
    };
    GossipRouter.instance.onChannelCommentDelete = (payload) async {
      final channelId = payload['channelId'] as String?;
      final commentId = payload['commentId'] as String?;
      final byUserId = payload['by'] as String?;
      if (channelId == null || commentId == null || byUserId == null) return;
      final comment = await ChannelService.instance.getComment(commentId);
      if (comment == null) return;
      final ch = await ChannelService.instance.getChannel(channelId);
      if (ch == null) return;
      if (byUserId != comment.authorId && byUserId != ch.adminId) return;
      await ChannelService.instance.deleteCommentById(commentId);
    };
    // Универсальный обработчик реакций для историй/постов/комментов/групп.
    GossipRouter.instance.onReactionExt = (payload) async {
      final kind = payload['kind'] as String?;
      final targetId = payload['targetId'] as String?;
      final emoji = payload['emoji'] as String?;
      final from = payload['from'] as String?;
      if (kind == null || targetId == null || emoji == null || from == null) {
        return;
      }
      switch (kind) {
        case 'story':
          StoryService.instance.applyIncomingReaction(targetId, emoji, from);
          break;
        case 'channel_post':
          await ChannelService.instance
              .togglePostReaction(targetId, emoji, from);
          break;
        case 'channel_comment':
          await ChannelService.instance
              .toggleCommentReaction(targetId, emoji, from);
          break;
        case 'group_message':
          await GroupService.instance
              .toggleMessageReaction(targetId, emoji, from);
          break;
      }
    };
    // Удаляет историю при получении story_del от автора
    GossipRouter.instance.onStoryDelete = (storyId, authorId) {
      debugPrint(
          '[RLINK][Stories] story_del: $storyId from ${authorId.substring(0, authorId.length.clamp(0, 8))}');
      StoryService.instance.deleteStory(storyId, authorId);
    };

    // Регистрирует просмотр истории (приходит от зрителя, обрабатывается у автора)
    GossipRouter.instance.onStoryView = (storyId, viewerId) {
      debugPrint(
          '[RLINK][Stories] story_view: $storyId from ${viewerId.substring(0, viewerId.length.clamp(0, 8))}');
      StoryService.instance.addViewer(storyId, viewerId);
    };

    // Отвечает на story_req: переотправляет свои активные истории и их картинки
    GossipRouter.instance.onStoryRequest = (fromId) async {
      final myKey = CryptoService.instance.publicKeyHex;
      if (myKey.isEmpty) return;
      final myStories = StoryService.instance.storiesFor(myKey);
      if (myStories.isEmpty) return;
      debugPrint(
          '[RLINK][Stories] story_req from ${fromId.substring(0, 8)}, re-sending ${myStories.length} stories');
      for (final story in myStories) {
        try {
          await GossipRouter.instance.sendStory(
            storyId: story.id,
            authorId: story.authorId,
            text: story.text,
            bgColor: story.bgColor,
            textX: story.textX,
            textY: story.textY,
            textSize: story.textSize,
          );
          // Re-send image to the requester via relay
          if (story.imagePath != null && RelayService.instance.isConnected) {
            final file = File(story.imagePath!);
            if (file.existsSync()) {
              final bytes = await file.readAsBytes();
              final compressed = ImageService.instance.compress(bytes);
              await RelayService.instance.sendBlob(
                recipientKey: fromId,
                fromId: myKey,
                msgId: 'story_${story.id}',
                compressedData: compressed,
              );
            }
          }
        } catch (e) {
          debugPrint('[RLINK][Stories] Re-send story failed: $e');
        }
        await Future.delayed(const Duration(milliseconds: 150));
      }
    };

    // Синхронизация пароля админки (устаревший plaintext hash в gossip — только для старых клиентов).
    GossipRouter.instance.onAdminConfig = (payload) async {
      final hash = payload['hash'] as String?;
      if (hash == null || hash.isEmpty) return;
      final rev = DateTime.now().millisecondsSinceEpoch;
      final inner = jsonEncode({'hash': hash, 'rev': rev});
      final sealed = await CryptoService.instance.sealAdminPanelSync(inner);
      await AppSettings.instance
          .applyAdminPasswordSyncIfNewer(hash, rev, sealed);
      debugPrint('[RLINK][Admin] Admin password updated from legacy admin_cfg');
    };
    GossipRouter.instance.onAdminConfigSecure = (hash, rev, chans) async {
      await AccountSyncService.applyFromGossip(hash, rev, chans);
      debugPrint(
          '[RLINK][Admin] Account sync from admin_cfg2 (rev=$rev, chans=${chans.length})');
    };
    GossipRouter.instance.onPollVote = (payload) async {
      final kind = payload['k'] as String?;
      final tid = payload['t'] as String?;
      final voter = payload['v'] as String?;
      final rawC = payload['c'];
      if (kind == null || tid == null || voter == null) return;
      final choices = <int>[];
      if (rawC is List) {
        for (final e in rawC) {
          choices.add((e as num).toInt());
        }
      }
      if (choices.isEmpty) return;
      if (kind == 'channel_post') {
        await ChannelService.instance.applyPollVote(tid, voter, choices);
      } else if (kind == 'group_message') {
        await GroupService.instance.applyPollVote(tid, voter, choices);
      }
    };

    GossipRouter.instance.onGroupMessage = (payload) async {
      final groupId = payload['groupId'] as String?;
      final senderId = payload['senderId'] as String?;
      final text = payload['text'] as String? ?? '';
      final messageId = payload['messageId'] as String?;
      final lat = (payload['lat'] as num?)?.toDouble();
      final lng = (payload['lng'] as num?)?.toDouble();
      final pj = payload['pj'] as String?;
      if (groupId == null || senderId == null || messageId == null) return;
      final hasMedia = payload['img'] == true ||
          payload['vid'] == true ||
          payload['file'] == true;
      if (text.isEmpty && (pj == null || pj.isEmpty) && !hasMedia) return;
      final myKey = CryptoService.instance.publicKeyHex;
      final tsOriginal = payload['ts'] as int?;
      final rxJson = payload['rx'] as String?;
      Map<String, List<String>> reactions = const {};
      if (rxJson != null && rxJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(rxJson) as Map<String, dynamic>;
          reactions =
              decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
        } catch (_) {}
      }

      final existing = await GroupService.instance.getMessage(messageId);
      if (existing != null) {
        // Только мержим реакции при синхронизации истории.
        if (reactions.isNotEmpty) {
          final merged = <String, List<String>>{};
          existing.reactions
              .forEach((k, v) => merged[k] = List<String>.from(v));
          reactions.forEach((k, v) {
            final set = <String>{...(merged[k] ?? const []), ...v};
            merged[k] = set.toList();
          });
          final mergedClamped = clampReactionsMapPerUser(merged);
          // Применяем через toggleMessageReaction не получится — записываем сырой JSON.
          // (saveMessage с ConflictAlgorithm.ignore не перезапишет, потому пишем напрямую.)
          // Но более аккуратно: используем существующий publisher:
          for (final entry in mergedClamped.entries) {
            for (final uid in entry.value) {
              if ((existing.reactions[entry.key] ?? const []).contains(uid)) {
                continue;
              }
              await GroupService.instance
                  .toggleMessageReaction(messageId, entry.key, uid);
            }
          }
        }
        if (pj != null && pj.isNotEmpty) {
          await GroupService.instance.mergeIncomingMessagePoll(messageId, pj);
        }
        if (text.isNotEmpty) {
          final exTodo = SharedTodoPayload.tryDecode(existing.text);
          final nwTodo = SharedTodoPayload.tryDecode(text);
          if (exTodo != null && nwTodo != null) {
            final merged = SharedTodoPayload.mergeRemote(existing.text, text);
            if (merged != existing.text) {
              await GroupService.instance.updateMessageText(messageId, merged);
            }
          } else if (SharedCalendarPayload.isPayload(text)) {
            final merged =
                SharedCalendarPayload.mergeRemote(existing.text, text);
            if (merged != existing.text) {
              await GroupService.instance.updateMessageText(messageId, merged);
            }
          }
        }
        return;
      }

      await GroupService.instance.saveMessage(GroupMessage(
        id: messageId,
        groupId: groupId,
        senderId: senderId,
        text: text,
        latitude: lat,
        longitude: lng,
        isOutgoing: senderId == myKey,
        timestamp: tsOriginal ?? DateTime.now().millisecondsSinceEpoch,
        reactions: clampReactionsMapPerUser(reactions),
        pollJson: (pj != null && pj.isNotEmpty) ? pj : null,
        forwardFromId: payload['ffid'] as String?,
        forwardFromNick: payload['ffn'] as String?,
      ));

      if (senderId != myKey) {
        final g = await GroupService.instance.getGroup(groupId);
        final contact = await ChatStorageService.instance.getContact(senderId);
        final author = contact?.nickname ??
            '${senderId.substring(0, senderId.length.clamp(0, 8))}…';
        final preview = text.isEmpty
            ? 'Опрос'
            : (text.length > 60 ? '${text.substring(0, 60)}…' : text);
        await NotificationService.instance.showGroupMessage(
          groupId: groupId,
          title: g?.name ?? 'Группа',
          body: '$author: $preview',
        );
      }
    };
    GossipRouter.instance.onGroupHistoryReq = (payload) async {
      final groupId = payload['groupId'] as String?;
      final requesterId = payload['requesterId'] as String?;
      final sinceTs = (payload['sinceTs'] as int?) ?? 0;
      if (groupId == null || requesterId == null) return;
      final me = CryptoService.instance.publicKeyHex;
      if (me.isEmpty || me == requesterId) return;
      final g = await GroupService.instance.getGroup(groupId);
      if (g == null) return;
      // Отвечают только действующие участники группы.
      if (!g.memberIds.contains(me) && g.creatorId != me) return;
      // Jitter, чтобы не флудить одновременно.
      final jitter = 300 + (DateTime.now().microsecondsSinceEpoch % 2200);
      await Future.delayed(Duration(milliseconds: jitter));

      final msgs = await GroupService.instance.getMessages(groupId, limit: 80);
      for (final m in msgs) {
        if (m.timestamp <= sinceTs) continue;
        final rx = m.reactions.isEmpty ? null : jsonEncode(m.reactions);
        await GossipRouter.instance.sendGroupMessage(
          groupId: groupId,
          senderId: m.senderId,
          text: m.text,
          messageId: m.id,
          timestamp: m.timestamp,
          latitude: m.latitude,
          longitude: m.longitude,
          reactionsJson: rx,
          hasImage: m.imagePath != null,
          hasVideo: m.videoPath != null,
          pollJson: m.pollJson,
          forwardFromId: m.forwardFromId,
          forwardFromNick: m.forwardFromNick,
        );
        await Future.delayed(const Duration(milliseconds: 60));
      }
      debugPrint('[RLINK][Group] Replied to history request for $groupId'
          ' with ${msgs.length} messages');
    };

    GossipRouter.instance.onDmPin = (payload) async {
      final mid = payload['mid'] as String?;
      final from = payload['from'] as String?;
      final add = payload['a'] as bool? ?? true;
      final rid8 = payload['r'] as String?;
      final myKey = CryptoService.instance.publicKeyHex;
      if (mid == null || from == null || myKey.isEmpty) return;
      if (rid8 != null && !myKey.startsWith(rid8)) return;
      final m = await ChatStorageService.instance.getMessageById(mid);
      if (m == null || m.peerId != from) return;
      if (add) {
        await ChatStorageService.instance.pinDmMessage(from, mid);
      } else {
        await ChatStorageService.instance.unpinDmMessage(from, mid);
      }
    };

    GossipRouter.instance.onGroupInvite = (payload) {
      final groupId = payload['groupId'] as String?;
      final groupName = payload['groupName'] as String?;
      final inviterId = payload['inviterId'] as String?;
      final inviterNick = payload['inviterNick'] as String?;
      final creatorId = payload['creatorId'] as String?;
      final memberIds =
          (payload['memberIds'] as List<dynamic>?)?.cast<String>() ?? [];
      if (groupId == null ||
          groupName == null ||
          inviterId == null ||
          inviterNick == null ||
          creatorId == null) {
        return;
      }
      debugPrint('[RLINK] Group invite: $groupName from $inviterNick');
      GroupService.instance.addInvite(GroupInvite(
        groupId: groupId,
        groupName: groupName,
        inviterId: inviterId,
        inviterNick: inviterNick,
        creatorId: creatorId,
        memberIds: memberIds,
        avatarColor: payload['avatarColor'] as int? ?? 0xFF5C6BC0,
        avatarEmoji: payload['avatarEmoji'] as String? ?? '👥',
        createdAt: payload['createdAt'] as int? ??
            DateTime.now().millisecondsSinceEpoch,
      ));
    };
    GossipRouter.instance.onGroupAccept = (payload) {
      final groupId = payload['groupId'] as String?;
      final accepterId = payload['accepterId'] as String?;
      if (groupId == null || accepterId == null) return;
      GroupService.instance.addMember(groupId, accepterId);
    };
    GossipRouter.instance.onVerifyRequest = (payload) {
      final channelId = payload['channelId'] as String?;
      final channelName = payload['channelName'] as String?;
      final adminId = payload['adminId'] as String?;
      if (channelId == null || channelName == null || adminId == null) return;
      debugPrint('[RLINK] Verification request: $channelName');
      ChannelService.instance.addVerificationRequest(VerificationRequest(
        channelId: channelId,
        channelName: channelName,
        adminId: adminId,
        subscriberCount: payload['subCount'] as int? ?? 0,
        avatarEmoji: payload['emoji'] as String? ?? '📢',
        description: payload['desc'] as String?,
        requestedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    };
    GossipRouter.instance.onVerifyApproval = (payload) {
      final channelId = payload['channelId'] as String?;
      final verifiedBy = payload['verifiedBy'] as String?;
      if (channelId == null || verifiedBy == null) return;
      debugPrint('[RLINK] Channel verified: $channelId by $verifiedBy');
      ChannelService.instance.verifyChannel(channelId, verifiedBy);
    };
    GossipRouter.instance.onChannelForeignAgent = (payload) {
      final channelId = payload['channelId'] as String?;
      final value = payload['value'] as bool? ?? true;
      if (channelId == null) return;
      debugPrint('[RLINK] Channel $channelId foreign agent = $value');
      ChannelService.instance
          .applyAdminAction(channelId: channelId, foreignAgent: value);
    };
    GossipRouter.instance.onChannelBlock = (payload) {
      final channelId = payload['channelId'] as String?;
      final value = payload['value'] as bool? ?? true;
      if (channelId == null) return;
      debugPrint('[RLINK] Channel $channelId blocked = $value');
      ChannelService.instance
          .applyAdminAction(channelId: channelId, blocked: value);
    };
    GossipRouter.instance.onChannelAdminDelete = (payload) {
      final channelId = payload['channelId'] as String?;
      if (channelId == null) return;
      final uc = payload['uc'] as String?;
      debugPrint('[RLINK] Channel $channelId deleted by admin');
      ChannelService.instance.applyAdminAction(
        channelId: channelId,
        delete: true,
        universalCode: uc,
      );
    };

    // При подключении BLE-пира — автоматически рассылаем свой профиль.
    // Это позволяет контактам обновить наш ник/аватар без ручного переприглашения.
    // Пакет 'profile' с TTL≥1 — не показывает диалог, только обновляет контакт.
    BleService.instance.onPeerConnected = (peerId) async {
      debugPrint(
          '[BLE] Peer connected: $peerId — broadcasting profile + requesting stories');
      final myProfile = ProfileService.instance.profile;
      if (myProfile != null) {
        await GossipRouter.instance.broadcastProfile(
          id: myProfile.publicKeyHex,
          nick: myProfile.nickname,
          username: myProfile.username,
          color: myProfile.avatarColor,
          emoji: myProfile.avatarEmoji,
          x25519Key: CryptoService.instance.x25519PublicKeyBase64,
          tags: myProfile.tags,
          statusEmoji: myProfile.statusEmoji,
        );
      }
      // Request stories from newly connected BLE peer
      final myKey = CryptoService.instance.publicKeyHex;
      if (myKey.isNotEmpty) {
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            await GossipRouter.instance.sendStoryRequest(fromId: myKey);
          } catch (_) {}
        });
      }
    };

    // Relay: колбэки регистрируем всегда — чтобы смена режима без перезапуска работала.
    RelayService.instance.onBlobReceived = _onBlobReceived;
    RelayService.instance.onPeerOnline = _onRelayPeerOnline;
    RelayService.instance.onAccountSyncBlob =
        (sealed) => unawaited(AccountSyncService.applySealedFromRelay(sealed));
    RelayService.instance.onChannelDirectorySnapshot = (entries) => unawaited(
          ChannelService.instance.applyRelayChannelDirectoryEntries(entries),
        );
    RelayService.instance.state.addListener(() {
      if (RelayService.instance.isConnected) {
        Future.delayed(const Duration(seconds: 2), _sendProfileToOnlinePeers);
        Future.delayed(
            const Duration(milliseconds: 2400), _republishOwnChannelsToRelay);
        Future.delayed(const Duration(seconds: 3), flushOutbox);
        Future.delayed(const Duration(seconds: 4), _requestStoriesFromPeers);
        Future.delayed(
            const Duration(seconds: 5), MediaUploadQueue.instance.processQueue);
      }
    });

    await applyConnectionTransport();
    unawaited(AppIconService.setVariant(AppSettings.instance.appIconVariant));

    // Dynamic Island: только BLE-счётчик (режимы 0 и 2) или крупная отправка медиа.
    if (RuntimePlatform.isIos) {
      MediaUploadQueue.instance.onLiveActivityMediaProgress =
          _onLiveActivityMediaProgress;
      _iosLiveActivityLastConnectionMode = AppSettings.instance.connectionMode;
      AppSettings.instance.addListener(_iosOnSettingsForLiveActivity);
      if (AppSettings.instance.connectionMode != 1) {
        unawaited(_startLiveActivity());
      }
      BleService.instance.peersCount
          .addListener(_iosLiveActivityBleDataChanged);
    }

    _bindGossipFallbackHandlersIfMissing();

    // Проверка обновлений: публичный репозиторий релизов → мобильные на rendergames.online/rlink
    unawaited(_checkUpdate());
  } catch (e, st) {
    debugPrint('[RLINK][main] Init error: $e\n$st');
    _bindGossipFallbackHandlersIfMissing();
  }
}

void _bindGossipFallbackHandlersIfMissing() {
  if (GossipRouter.instance.onEtherReceived == null) {
    GossipRouter.instance.onEtherReceived =
        (id, text, color, senderId, senderNick, {double? lat, double? lng}) {
      debugPrint('[RLINK][Fallback] Bind onEther');
      EtherService.instance.addMessage(EtherMessage(
        id: id,
        text: text,
        color: color,
        receivedAt: DateTime.now(),
        senderId: senderId,
        senderNick: senderNick,
        latitude: lat,
        longitude: lng,
      ));
    };
  }

  if (GossipRouter.instance.onPairRequest == null) {
    GossipRouter.instance.onPairRequest =
        (bleId, publicKey, nick, username, color, emoji, x25519Key, tags) {
      debugPrint('[RLINK][Fallback] Bind onPairReq from $nick');
      final info = <String, dynamic>{
        'sourceId': bleId,
        'publicKey': publicKey,
        'nick': nick,
        'username': username,
        'color': color,
        'emoji': emoji,
        'x25519Key': x25519Key,
        'tags': tags,
      };
      BleService.instance.addPairRequest(bleId, info);
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        try {
          showPairRequestScreen(ctx, bleId, info);
        } catch (_) {}
      }
    };
  }

  if (GossipRouter.instance.onMessageReceived == null) {
    GossipRouter.instance.onMessageReceived = (fromId, encrypted, messageId,
        replyToMessageId,
        {double? latitude,
        double? longitude,
        String? forwardFromId,
        String? forwardFromNick,
        String? forwardFromChannelId}) async {
      debugPrint('[RLINK][Fallback] Bind onMessage from ${fromId.substring(0, fromId.length.clamp(0, 8))}');
      final String text;
      if (encrypted.ephemeralPublicKey.isEmpty) {
        if (encrypted.cipherText.isEmpty) return;
        text = encrypted.cipherText;
      } else {
        final plaintext = await CryptoService.instance.decryptMessage(encrypted);
        if (plaintext == null || plaintext.isEmpty) return;
        text = plaintext;
      }
      final now = DateTime.now();
      await ChatStorageService.instance.saveMessage(ChatMessage(
        id: messageId,
        peerId: fromId,
        text: text,
        replyToMessageId: replyToMessageId,
        latitude: latitude,
        longitude: longitude,
        isOutgoing: false,
        timestamp: now,
        status: MessageStatus.delivered,
        forwardFromId: forwardFromId,
        forwardFromNick: forwardFromNick,
        forwardFromChannelId: forwardFromChannelId,
      ));
      incomingMessageController.add(IncomingMessage(
        fromId: fromId,
        text: text,
        timestamp: now,
        msgId: messageId,
      ));
    };
  }
}

/// Updates the ether anti-bullying name filter with current contacts + own name.
Future<void> _updateEtherNameFilter() async {
  try {
    final names = <String>{};
    final contacts = await ChatStorageService.instance.getContacts();
    for (final c in contacts) {
      if (c.nickname.isNotEmpty) names.add(c.nickname);
    }
    final myProfile = ProfileService.instance.profile;
    if (myProfile != null) names.add(myProfile.nickname);
    NameFilter.instance.updateDynamicNames(names);
  } catch (_) {}
}

/// Send our profile DIRECTLY to a specific peer via relay (not broadcast).
/// This ensures the profile reaches the peer even if relay doesn't support broadcast.
Future<void> _sendProfileDirectToPeer(String peerKey) async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null || !RelayService.instance.isConnected) return;

  final packet = GossipPacket(
    id: const Uuid().v4(),
    type: 'profile',
    ttl: 1,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    payload: <String, dynamic>{
      'id': myProfile.publicKeyHex,
      'nick': myProfile.nickname,
      if (myProfile.username.isNotEmpty) 'u': myProfile.username,
      'color': myProfile.avatarColor,
      'emoji': myProfile.avatarEmoji,
      'x': CryptoService.instance.x25519PublicKeyBase64,
      if (myProfile.tags.isNotEmpty) 'tags': myProfile.tags,
      'st': myProfile.statusEmoji,
    },
  );
  try {
    await RelayService.instance.sendPacket(packet, recipientKey: peerKey);
    debugPrint(
        '[RLINK][Profile] Sent DIRECTED profile to ${peerKey.substring(0, 8)}');
  } catch (e) {
    debugPrint('[RLINK][Profile] Direct profile send failed: $e');
  }
}

/// Send profile + avatar + banner to a specific peer via relay.
Future<void> _sendFullProfileToPeer(String peerKey) async {
  await _sendProfileDirectToPeer(peerKey);

  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;

  // Send avatar blob
  final imagePath =
      ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
  if (imagePath != null && File(imagePath).existsSync()) {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final bytes = await File(imagePath).readAsBytes();
      final compressed = ImageService.instance.compress(bytes);
      // Уникальный msgId на каждую отправку (обход дедупа приёмника).
      final ts = DateTime.now().millisecondsSinceEpoch;
      final msgId = 'avatar_${myProfile.publicKeyHex.substring(0, 16)}_$ts';
      await RelayService.instance.sendBlob(
        recipientKey: peerKey,
        fromId: myProfile.publicKeyHex,
        msgId: msgId,
        compressedData: compressed,
        isSquare: true,
      );
      debugPrint(
          '[RLINK][Avatar] Sent avatar blob to ${peerKey.substring(0, 8)}');
    } catch (e) {
      debugPrint(
          '[RLINK][Avatar] Avatar blob to ${peerKey.substring(0, 8)} failed: $e');
    }
  }

  // Send banner blob
  final bannerPath =
      ImageService.instance.resolveStoredPath(myProfile.bannerImagePath);
  if (bannerPath != null && File(bannerPath).existsSync()) {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final bytes = await File(bannerPath).readAsBytes();
      final compressed = ImageService.instance.compress(bytes);
      // Уникальный msgId на каждую отправку, иначе дедуп на приёмнике
      // (wasAlreadyCompleted) молча отбрасывает все последующие обновления баннера.
      final ts = DateTime.now().millisecondsSinceEpoch;
      final msgId = 'banner_${myProfile.publicKeyHex.substring(0, 16)}_$ts';
      await RelayService.instance.sendBlob(
        recipientKey: peerKey,
        fromId: myProfile.publicKeyHex,
        msgId: msgId,
        compressedData: compressed,
      );
      debugPrint(
          '[RLINK][Banner] Sent banner blob to ${peerKey.substring(0, 8)}');
    } catch (e) {
      debugPrint(
          '[RLINK][Banner] Banner blob to ${peerKey.substring(0, 8)} failed: $e');
    }
  }

  final musicPath =
      ImageService.instance.resolveStoredPath(myProfile.profileMusicPath);
  if (musicPath != null && File(musicPath).existsSync()) {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final bytes = await File(musicPath).readAsBytes();
      final compressed = ImageService.instance.compress(bytes);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final msgId =
          'profile_music_${myProfile.publicKeyHex.substring(0, 16)}_$ts';
      await RelayService.instance.sendBlob(
        recipientKey: peerKey,
        fromId: myProfile.publicKeyHex,
        msgId: msgId,
        compressedData: compressed,
      );
      debugPrint(
          '[RLINK][Music] Sent profile music blob to ${peerKey.substring(0, 8)}');
    } catch (e) {
      debugPrint(
          '[RLINK][Music] Music blob to ${peerKey.substring(0, 8)} failed: $e');
    }
  }
}

/// Send profile to ALL contacts after a profile edit.
///
/// Uses every available transport so updates reach contacts regardless of
/// whether they're online via BLE, WiFi-Direct or the internet relay:
///   • Relay → direct per-contact unicast (instant for online peers).
///   • Gossip broadcast → reaches BLE/mesh peers and gets re-broadcast to
///     other contacts via TTL forwarding (works even with relay offline).
///   • Avatar/banner blob re-broadcast for full visual sync.
Future<void> sendProfileToAllContacts() async {
  final myProfile = ProfileService.instance.profile;
  final myKey = CryptoService.instance.publicKeyHex;
  if (myProfile == null || myKey.isEmpty) return;

  // 1) Relay unicast (fast path for online contacts).
  if (RelayService.instance.isConnected) {
    final contacts = await ChatStorageService.instance.getContacts();
    for (final c in contacts) {
      unawaited(_sendFullProfileToPeer(c.publicKeyHex));
    }
    debugPrint('[RLINK][Profile] Relay-pushed to ${contacts.length} contacts');
  }

  // 2) Gossip broadcast (BLE / WiFi-Direct mesh).
  try {
    await GossipRouter.instance.broadcastProfile(
      id: myKey,
      nick: myProfile.nickname,
      username: myProfile.username,
      color: myProfile.avatarColor,
      emoji: myProfile.avatarEmoji,
      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
      tags: myProfile.tags,
      statusEmoji: myProfile.statusEmoji,
    );
    debugPrint('[RLINK][Profile] Gossip-broadcast profile');
  } catch (e) {
    debugPrint('[RLINK][Profile] Gossip broadcast failed: $e');
  }

  // 3) Re-broadcast avatar + banner so visuals refresh everywhere.
  if (myProfile.avatarImagePath != null &&
      myProfile.avatarImagePath!.isNotEmpty) {
    unawaited(_broadcastAvatar(myKey, myProfile.avatarImagePath!));
  }
  if (myProfile.bannerImagePath != null &&
      myProfile.bannerImagePath!.isNotEmpty) {
    unawaited(broadcastMyBanner());
  }
  if (myProfile.profileMusicPath != null &&
      myProfile.profileMusicPath!.isNotEmpty) {
    unawaited(broadcastMyProfileMusic());
  }
}

/// Request active stories from all connected peers (called on relay connect / BLE peer connect).
Future<void> _requestStoriesFromPeers() async {
  final myKey = CryptoService.instance.publicKeyHex;
  if (myKey.isEmpty) return;
  try {
    await GossipRouter.instance.sendStoryRequest(fromId: myKey);
    debugPrint('[RLINK][Stories] Sent story_req broadcast');
  } catch (e) {
    debugPrint('[RLINK][Stories] story_req failed: $e');
  }
}

/// Send profile to ALL known online peers via relay (on connect).
Future<void> _sendProfileToOnlinePeers() async {
  if (!RelayService.instance.isConnected) return;
  final peers = RelayService.instance.knownOnlinePeers;
  for (final p in peers) {
    unawaited(_sendProfileDirectToPeer(p.publicKey));
  }
  if (peers.isNotEmpty) {
    debugPrint('[RLINK][Profile] Sent profile to ${peers.length} online peers');
  }
}

/// На reconnect к relay перепубликует каталог каналов текущего владельца.
/// Нужен для случаев, когда канал создавался/обновлялся офлайн: без этого
/// запись в серверном snapshot может отсутствовать до следующего ручного edit.
Future<void> _republishOwnChannelsToRelay() async {
  if (_relayChannelRepublishInFlight) return;
  if (!RelayService.instance.isConnected) return;
  if (AppSettings.instance.connectionMode < 1) return;

  final nowMs = DateTime.now().millisecondsSinceEpoch;
  if (nowMs - _lastRelayChannelRepublishAtMs < 15000) return;
  _lastRelayChannelRepublishAtMs = nowMs;

  final myId = CryptoService.instance.publicKeyHex;
  if (myId.isEmpty) return;

  _relayChannelRepublishInFlight = true;
  try {
    final all = await ChannelService.instance.getChannels();
    final mine = all.where((c) => c.adminId == myId).toList();
    if (mine.isEmpty) return;

    var sent = 0;
    for (final ch in mine) {
      if (!RelayService.instance.isConnected) break;
      await ChannelDirectoryRelay.publishIfAdmin(ch);
      sent++;
      // Небольшая пауза: не забиваем put rate-limit при пачке каналов.
      await Future<void>.delayed(const Duration(milliseconds: 45));
    }
    debugPrint(
        '[RLINK][ChDir] Republished $sent own channels on relay connect');
  } catch (e, st) {
    debugPrint('[RLINK][ChDir] republish on connect failed: $e\n$st');
  } finally {
    _relayChannelRepublishInFlight = false;
  }
}

/// When a relay peer comes online, send our profile + avatar + banner.
void _onRelayPeerOnline(String peerPublicKey) {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  unawaited(_sendFullProfileToPeer(peerPublicKey));
}

/// Отправляет аватар-изображение по BLE + relay (fire-and-forget).
Future<void> _broadcastAvatar(String myPublicKey, String imagePath) async {
  try {
    // Wait for profile packets and BLE stack to settle after pair exchange.
    await Future.delayed(const Duration(milliseconds: 1500));
    // Resolve potentially stale iOS sandbox path
    final resolvedPath = ImageService.instance.resolveStoredPath(imagePath);
    if (resolvedPath == null || !File(resolvedPath).existsSync()) {
      debugPrint('[RLINK][Avatar] File not found: $imagePath → $resolvedPath');
      return;
    }
    final bytes = await File(resolvedPath).readAsBytes();

    // Relay blob path — send to all contacts (instant delivery)
    if (RelayService.instance.isConnected) {
      try {
        final compressed = ImageService.instance.compress(bytes);
        // Уникальный msgId — иначе приёмник дедупит по wasAlreadyCompleted.
        final ts = DateTime.now().millisecondsSinceEpoch;
        final blobMsgId = 'avatar_${myPublicKey.substring(0, 16)}_$ts';
        final contacts = await ChatStorageService.instance.getContacts();
        for (final c in contacts) {
          try {
            await RelayService.instance.sendBlob(
              recipientKey: c.publicKeyHex,
              fromId: myPublicKey,
              msgId: blobMsgId,
              compressedData: compressed,
              isSquare: true,
            );
          } catch (_) {}
        }
        debugPrint(
            '[RLINK][Avatar] Sent relay blob to ${contacts.length} contacts');
      } catch (e) {
        debugPrint('[RLINK][Avatar] Relay blob failed: $e');
      }
    }

    // BLE chunk path — only in modes that use BLE (0=BLE only, 2=Both)
    if (AppSettings.instance.connectionMode != 1) {
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      debugPrint(
          '[RLINK][Avatar] Starting BLE broadcast: ${chunks.length} chunks, ${bytes.length} bytes');
      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: myPublicKey,
        isAvatar: true,
      );
      await Future.delayed(const Duration(milliseconds: 200));
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: myPublicKey,
        );
        if (i % 5 == 4) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }
      debugPrint('[RLINK][Avatar] Sent ${chunks.length} chunks via BLE');
    }
  } catch (e) {
    debugPrint('[RLINK][Avatar] Send failed: $e');
  }
}

/// Отправляет баннер профиля по BLE+relay после обмена контактами.
Future<void> _broadcastBanner(String myPublicKey, String bannerPath) async {
  try {
    // Небольшая пауза, чтобы не забивать канал если сразу после аватара.
    await Future.delayed(const Duration(milliseconds: 800));
    final resolvedPath = ImageService.instance.resolveStoredPath(bannerPath);
    if (resolvedPath == null || !File(resolvedPath).existsSync()) return;
    final bytes = await File(resolvedPath).readAsBytes();
    // Relay path — instant delivery
    if (RelayService.instance.isConnected) {
      final compressed = ImageService.instance.compress(bytes);
      // Уникальный msgId — обход дедупа приёмника.
      final ts = DateTime.now().millisecondsSinceEpoch;
      final msgId = 'banner_${myPublicKey.substring(0, 16)}_$ts';
      // Relay: send to all online contacts
      final contacts = await ChatStorageService.instance.getContacts();
      for (final c in contacts) {
        try {
          await RelayService.instance.sendBlob(
            recipientKey: c.publicKeyHex,
            fromId: myPublicKey,
            msgId: msgId,
            compressedData: compressed,
            isSquare: true,
          );
        } catch (_) {}
      }
      debugPrint(
          '[RLINK][Banner] Sent banner via relay to ${contacts.length} contacts');
    }
    // BLE chunks — only in modes that use BLE (0=BLE only, 2=Both)
    if (AppSettings.instance.connectionMode != 1) {
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final bleMsgId =
          'banner_${myPublicKey.substring(0, 16)}_${const Uuid().v4().substring(0, 8)}';
      await GossipRouter.instance.sendImgMeta(
        msgId: bleMsgId,
        totalChunks: chunks.length,
        fromId: myPublicKey,
        isAvatar: false,
      );
      await Future.delayed(const Duration(milliseconds: 200));
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: bleMsgId,
          index: i,
          base64Data: chunks[i],
          fromId: myPublicKey,
        );
        if (i % 5 == 4) await Future.delayed(const Duration(milliseconds: 30));
      }
      debugPrint('[RLINK][Banner] Sent banner via BLE chunks');
    }
  } catch (e) {
    debugPrint('[RLINK][Banner] Send failed: $e');
  }
}

// ── Dynamic Island / Live Activity ───────────────────────────────

/// Converts best RSSI across all peers to signal level 0-3.
int _bestSignalLevel() {
  int bestRssi = -100;
  for (final peerId in BleService.instance.connectedPeerIds) {
    final rssi = BleService.instance.getRssi(peerId);
    if (rssi != null && rssi > bestRssi) bestRssi = rssi;
  }
  if (bestRssi >= -55) return 3; // strong
  if (bestRssi >= -75) return 2; // medium
  if (bestRssi >= -90) return 1; // weak
  return 0; // none
}

bool _isServiceMediaByMsgId(
  String msgId, {
  required bool isAvatar,
}) {
  if (isAvatar) return true;
  return msgId.startsWith('banner_') ||
      msgId.startsWith('profile_music_') ||
      msgId.startsWith('story_') ||
      msgId.startsWith('story_vid_') ||
      msgId.startsWith('chbn_') ||
      msgId.startsWith('chav_');
}

String _placeholderLabelForIncomingMedia({
  required bool isVoice,
  required bool isVideo,
  required bool isSquare,
  required bool isFile,
  String? fileName,
}) {
  if (isVoice) return '🎤 Голосовое';
  if (isFile) {
    return '📎 ${fileName?.trim().isNotEmpty == true ? fileName!.trim() : 'Файл'}';
  }
  if (isVideo) return isSquare ? '⬛ Видео' : '📹 Видео';
  return '';
}

Future<bool> _isKnownChannelOrGroupMedia(String msgId) async {
  final post = await ChannelService.instance.getPost(msgId);
  if (post != null) return true;
  final comment = await ChannelService.instance.getComment(msgId);
  if (comment != null) return true;
  final group = await GroupService.instance.getMessage(msgId);
  if (group != null) return true;
  return false;
}

Future<bool> _handleIncomingMediaWhenAutoDownloadDisabled({
  required String fromId,
  required String msgId,
  required bool isAvatar,
  required bool isVoice,
  required bool isVideo,
  required bool isSquare,
  required bool isFile,
  required bool viewOnce,
  String? fileName,
  String? forwardFromId,
  String? forwardFromNick,
  String? forwardFromChannelId,
}) async {
  if (AppSettings.instance.autoDownloadMedia) return false;
  if (_isServiceMediaByMsgId(msgId, isAvatar: isAvatar)) return false;

  if (await _isKnownChannelOrGroupMedia(msgId)) {
    return false;
  }
  // Небольшая пауза: channel/group метадата может прийти чуть позже img_meta/blob.
  await Future<void>.delayed(const Duration(milliseconds: 450));
  if (await _isKnownChannelOrGroupMedia(msgId)) {
    return false;
  }

  final label = _placeholderLabelForIncomingMedia(
    isVoice: isVoice,
    isVideo: isVideo,
    isSquare: isSquare,
    isFile: isFile,
    fileName: fileName,
  );

  final existing = await ChatStorageService.instance.getMessageById(msgId);
  if (existing == null) {
    final now = DateTime.now();
    final placeholder = ChatMessage(
      id: msgId,
      peerId: fromId,
      text: label,
      isOutgoing: false,
      timestamp: now,
      status: MessageStatus.delivered,
      viewOnce: viewOnce,
      forwardFromId: forwardFromId,
      forwardFromNick: forwardFromNick,
      forwardFromChannelId: forwardFromChannelId,
    );
    await ChatStorageService.instance.saveMessage(placeholder);
    incomingMessageController.add(IncomingMessage(
      fromId: fromId,
      text: label,
      timestamp: now,
      msgId: msgId,
    ));
  }

  final myKey = CryptoService.instance.publicKeyHex;
  if (myKey.isNotEmpty) {
    unawaited(GossipRouter.instance.sendAck(
      messageId: msgId,
      senderId: myKey,
      recipientId: fromId,
    ));
  }
  debugPrint(
      '[RLINK][Media] Auto-download disabled, keeping placeholder: $msgId');
  return true;
}

/// Handle blob received from relay — reassemble into a file and save message
void _onBlobReceived(
    String fromId,
    String msgId,
    Uint8List data,
    bool isVoice,
    bool isVideo,
    bool isSquare,
    bool isFile,
    bool isSticker,
    String? fileName,
    bool viewOnce) async {
  debugPrint(
      '[RLINK][Blob] Received ${data.length} bytes from ${fromId.substring(0, 8)} msgId=$msgId voice=$isVoice video=$isVideo file=$isFile');

  // Заблокированный отправитель — молча выкидываем blob.
  if (BlockService.instance.isBlocked(fromId)) {
    debugPrint('[Block] Dropped blob from blocked ${fromId.substring(0, 8)}');
    return;
  }

  // Dedup: if this msgId was already assembled via gossip chunks, skip
  if (ImageService.instance.wasAlreadyCompleted(msgId)) {
    debugPrint(
        '[RLINK][Blob] msgId=$msgId already completed via chunks, skipping');
    return;
  }

  // Handle avatar blob — save as contact avatar, not a chat message
  if (msgId.startsWith('avatar_')) {
    try {
      final decompressed = ImageService.instance.decompress(data);
      final avatarPath = await ImageService.instance.saveContactAvatar(
        fromId,
        decompressed,
      );
      // Файл перезаписан с тем же путём — сбрасываем кэш Flutter,
      // иначе UI продолжит показывать старую картинку.
      _evictImageCache(avatarPath);
      await ChatStorageService.instance
          .updateContactAvatarImage(fromId, avatarPath);
      debugPrint(
          '[RLINK][Avatar] Saved relay avatar for ${fromId.substring(0, 8)} → $avatarPath');
    } catch (e) {
      debugPrint('[RLINK][Avatar] Failed to save relay avatar: $e');
    }
    return;
  }

  // Handle banner blob — save as contact banner image
  if (msgId.startsWith('banner_')) {
    try {
      final decompressed = ImageService.instance.decompress(data);
      // Use dedicated saveBannerImage to avoid overwriting avatar (different filename prefix).
      final bannerPath =
          await ImageService.instance.saveBannerImage(fromId, decompressed);
      _evictImageCache(bannerPath);
      final existing = await ChatStorageService.instance.getContact(fromId);
      if (existing != null) {
        // saveContact fires contactsNotifier, so UI auto-refreshes.
        await ChatStorageService.instance.saveContact(existing.copyWith(
            bannerImagePath: bannerPath, setBannerImagePath: true));
        debugPrint(
            '[RLINK][Banner] Saved relay banner for ${fromId.substring(0, 8)} → $bannerPath');
      }
    } catch (e) {
      debugPrint('[RLINK][Banner] Failed to save relay banner: $e');
    }
    return;
  }

  if (msgId.startsWith('profile_music_')) {
    try {
      final decompressed = ImageService.instance.decompress(data);
      final musicPath =
          await ImageService.instance.saveProfileMusic(fromId, decompressed);
      final existing = await ChatStorageService.instance.getContact(fromId);
      if (existing != null) {
        await ChatStorageService.instance.saveContact(existing.copyWith(
            profileMusicPath: musicPath, setProfileMusicPath: true));
        debugPrint(
            '[RLINK][Music] Saved profile music for ${fromId.substring(0, 8)}');
      }
    } catch (e) {
      debugPrint('[RLINK][Music] Failed to save profile music: $e');
    }
    return;
  }

  // Handle story VIDEO blob — msgId format: 'story_vid_<storyId>'
  if (msgId.startsWith('story_vid_')) {
    try {
      final storyId = msgId.substring('story_vid_'.length);
      final decompressed = ImageService.instance.decompress(data);
      final videoPath =
          await ImageService.instance.saveStoryVideo(storyId, decompressed);
      final story = StoryService.instance.findStory(storyId);
      if (story != null) {
        story.videoPath = videoPath;
        StoryService.instance.notifyUpdate();
        debugPrint(
            '[RLINK][Story] Attached relay video to story ${storyId.substring(0, storyId.length.clamp(0, 8))}');
      } else {
        // История ещё не пришла — кэшируем видео и прикрепим при появлении.
        StoryService.instance.cachePendingVideo(storyId, videoPath);
        debugPrint(
            '[RLINK][Story] Cached pending video for ${storyId.substring(0, storyId.length.clamp(0, 8))}');
      }
    } catch (e) {
      debugPrint('[RLINK][Story] Failed to save relay story video: $e');
    }
    return;
  }

  // Handle story blob — attach image to the matching story.
  // msgId format: 'story_<storyId>'
  if (msgId.startsWith('story_')) {
    try {
      final storyId = msgId.substring('story_'.length);
      final decompressed = ImageService.instance.decompress(data);
      final imagePath = await ImageService.instance.saveContactAvatar(
        'story_$storyId',
        decompressed,
      );
      final story = StoryService.instance.findStory(storyId);
      if (story != null) {
        story.imagePath = imagePath;
        StoryService.instance.notifyUpdate();
        debugPrint(
            '[RLINK][Story] Attached relay image to story ${storyId.substring(0, 8)}');
      } else {
        // История ещё не пришла — кэшируем картинку и прикрепим при появлении.
        StoryService.instance.cachePendingImage(storyId, imagePath);
        debugPrint(
            '[RLINK][Story] Cached pending image for ${storyId.substring(0, 8)}');
      }
    } catch (e) {
      debugPrint('[RLINK][Story] Failed to save relay story image: $e');
    }
    return;
  }

  final skippedBySettings = await _handleIncomingMediaWhenAutoDownloadDisabled(
    fromId: fromId,
    msgId: msgId,
    isAvatar: false,
    isVoice: isVoice,
    isVideo: isVideo,
    isSquare: isSquare,
    isFile: isFile,
    viewOnce: viewOnce,
    fileName: fileName,
  );
  if (skippedBySettings) return;

  // Feed directly to ImageService as if all chunks arrived at once
  ImageService.instance.initAssembly(
    msgId,
    1,
    isAvatar: false,
    isVoice: isVoice,
    fromId: fromId,
    isVideo: isVideo,
    isSquare: isSquare,
    isFile: isFile,
    isSticker: isSticker,
    fileName: fileName,
    viewOnce: viewOnce,
  );
  ImageService.instance.receiveBlobData(msgId: msgId, compressedData: data);

  if (!ImageService.instance.isComplete(msgId)) {
    debugPrint('[RLINK][Blob] Assembly not complete for $msgId — unexpected');
    return;
  }

  final senderKey = fromId;

  final myKey = CryptoService.instance.publicKeyHex;

  if (isVoice) {
    final path = await ImageService.instance.assembleAndSaveVoice(msgId);
    if (path == null) {
      debugPrint('[RLINK][Blob] Voice assemble failed');
      return;
    }
    ImageService.instance.markCompleted(msgId);
    if (await ChannelService.instance.getPost(msgId) != null) {
      await ChannelService.instance.applyAssembledPostMedia(
        postId: msgId,
        voicePath: path,
      );
      return;
    }
    if (await ChannelService.instance.getComment(msgId) != null) {
      await ChannelService.instance.applyAssembledCommentMedia(
        commentId: msgId,
        voicePath: path,
      );
      return;
    }

    final msg = ChatMessage(
      id: msgId,
      peerId: senderKey,
      text: '🎤 Голосовое',
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      voicePath: path,
      viewOnce: viewOnce,
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: '🎤 Голосовое',
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance
          .sendAck(messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] Voice saved: $path');
  } else if (isFile) {
    final origName = fileName ?? ImageService.instance.assemblyFileName(msgId);
    final path = await ImageService.instance.assembleAndSaveFile(msgId);
    if (path == null) {
      debugPrint('[RLINK][Blob] File assemble failed');
      return;
    }
    ImageService.instance.markCompleted(msgId);
    if (await ChannelService.instance.getPost(msgId) != null) {
      final fileBytes = await File(path).length();
      await ChannelService.instance.applyAssembledPostMedia(
        postId: msgId,
        filePath: path,
        fileName: origName,
        fileSize: fileBytes,
      );
      return;
    }
    if (await ChannelService.instance.getComment(msgId) != null) {
      final fileBytes = await File(path).length();
      await ChannelService.instance.applyAssembledCommentMedia(
        commentId: msgId,
        filePath: path,
        fileName: origName,
        fileSize: fileBytes,
      );
      return;
    }

    final fileLabel = '📎 ${origName ?? 'Файл'}';
    final fileBytes = await File(path).length();
    final msg = ChatMessage(
      id: msgId,
      peerId: senderKey,
      text: fileLabel,
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      filePath: path,
      fileName: origName,
      fileSize: fileBytes,
      viewOnce: viewOnce,
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: fileLabel,
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance
          .sendAck(messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] File saved: $path ($origName)');
  } else if (isVideo) {
    final path = await ImageService.instance
        .assembleAndSaveVideo(msgId, isSquare: isSquare);
    if (path == null) {
      debugPrint('[RLINK][Blob] Video assemble failed');
      return;
    }
    ImageService.instance.markCompleted(msgId);
    if (await ChannelService.instance.getPost(msgId) != null) {
      await ChannelService.instance.applyAssembledPostMedia(
        postId: msgId,
        videoPath: path,
      );
      return;
    }
    if (await ChannelService.instance.getComment(msgId) != null) {
      await ChannelService.instance.applyAssembledCommentMedia(
        commentId: msgId,
        videoPath: path,
      );
      return;
    }

    final label = isSquare ? '⬛ Видео' : '📹 Видео';
    final msg = ChatMessage(
      id: msgId,
      peerId: senderKey,
      text: label,
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      videoPath: path,
      viewOnce: viewOnce,
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: label,
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance
          .sendAck(messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] Video saved: $path (square=$isSquare)');
  } else {
    // Image
    final path = await ImageService.instance.assembleAndSave(msgId);
    if (path == null) {
      debugPrint('[RLINK][Blob] Image assemble failed');
      return;
    }
    ImageService.instance.markCompleted(msgId);

    if (await ChannelService.instance.getPost(msgId) != null) {
      await ChannelService.instance.applyAssembledPostMedia(
        postId: msgId,
        imagePath: path,
      );
      return;
    }
    if (await ChannelService.instance.getComment(msgId) != null) {
      await ChannelService.instance.applyAssembledCommentMedia(
        commentId: msgId,
        imagePath: path,
      );
      return;
    }

    // Check if this image belongs to a story
    final existingStory = StoryService.instance.findStory(msgId);
    if (existingStory != null) {
      existingStory.imagePath = path;
      StoryService.instance.notifyUpdate();
      debugPrint(
          '[RLINK][Blob] Story image received for ${msgId.substring(0, 8)}');
      return;
    }

    final msg = ChatMessage(
      id: msgId,
      peerId: senderKey,
      text: '',
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      imagePath: path,
      viewOnce: viewOnce,
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: '',
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance
          .sendAck(messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] Image saved: $path');
  }
}

Future<void> _startLiveActivity() async {
  if (!RuntimePlatform.isIos) return;
  if (AppSettings.instance.connectionMode == 1) return;
  try {
    await _kBleChannel.invokeMethod('startLiveActivity', {
      'peers': BleService.instance.peersCount.value,
      'sender': '',
      'message': '',
      'signal': _bestSignalLevel(),
      'uiMode': 0,
      'mediaProgress': 0.0,
      'mediaLabel': '',
    });
    debugPrint('[RLINK][LiveActivity] Started');
  } catch (e) {
    debugPrint('[RLINK][LiveActivity] Start failed: $e');
  }
}

void _iosLiveActivityBleDataChanged() {
  if (!RuntimePlatform.isIos) return;
  if (_iosMediaLiveActivityActive) return;
  if (AppSettings.instance.connectionMode == 1) return;
  _updateLiveActivity();
}

void _iosOnSettingsForLiveActivity() {
  if (!RuntimePlatform.isIos) return;
  if (_iosMediaLiveActivityActive) return;
  final mode = AppSettings.instance.connectionMode;
  if (mode == _iosLiveActivityLastConnectionMode) return;
  _iosLiveActivityLastConnectionMode = mode;
  if (mode == 1) {
    try {
      _kBleChannel.invokeMethod('stopLiveActivity');
    } catch (_) {}
  } else {
    unawaited(_startLiveActivity());
  }
}

void _onLiveActivityMediaProgress(String label, double progress) {
  if (!RuntimePlatform.isIos) return;
  try {
    if (progress >= 1.0) {
      _iosMediaLiveActivityActive = false;
      if (AppSettings.instance.connectionMode == 1) {
        _kBleChannel.invokeMethod('stopLiveActivity');
      } else {
        _updateLiveActivity();
      }
      return;
    }
    _iosMediaLiveActivityActive = true;
    final p = progress.clamp(0.0, 1.0);
    _kBleChannel.invokeMethod('updateLiveActivity', {
      'uiMode': 1,
      'mediaProgress': p,
      'mediaLabel': label,
      'peers': 0,
      'sender': 'Отправка',
      'message': '${(p * 100).round()}%',
      'signal': 0,
    });
  } catch (e) {
    debugPrint('[RLINK][LiveActivity] media progress: $e');
  }
}

void _updateLiveActivity() {
  if (!RuntimePlatform.isIos) return;
  if (_iosMediaLiveActivityActive) return;
  if (AppSettings.instance.connectionMode == 1) return;
  final blePeers = BleService.instance.peersCount.value;
  try {
    _kBleChannel.invokeMethod('updateLiveActivity', {
      'peers': blePeers,
      'sender': '',
      'message': '',
      'signal': _bestSignalLevel(),
      'uiMode': 0,
      'mediaProgress': 0.0,
      'mediaLabel': '',
    });
  } catch (_) {}
}

Future<void> _checkUpdate() async {
  await Future.delayed(const Duration(seconds: 5));
  final update = await UpdateService.instance.checkForUpdate();
  if (update != null) pendingUpdateNotifier.value = update;
}

class RlinkApp extends StatefulWidget {
  const RlinkApp({super.key});

  @override
  State<RlinkApp> createState() => _RlinkAppState();
}

class _RlinkAppState extends State<RlinkApp> with WidgetsBindingObserver {
  bool _ready = false;
  bool _hasProfile = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (RuntimePlatform.isDesktopWindows) {
        await DesktopTrayService.instance.init();
      }
      await initServices();
      if (mounted) {
        setState(() {
          _ready = true;
          _hasProfile = ProfileService.instance.hasProfile;
        });
        unawaited(RlinkDeepLinkService.instance.start(navigatorKey));
      }
    });
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Не останавливаем BLE при сворачивании — иначе нет mesh и нет приёма до
    // следующего открытия. Android дополнительно держит процесс через
    // foreground service; Windows — сворачивание в трей вместо kill.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      NotificationService.instance.isInBackground.value = true;
    } else if (state == AppLifecycleState.detached) {
      NotificationService.instance.isInBackground.value = true;
      unawaited(_notifyPeersOffline());
    } else if (state == AppLifecycleState.resumed) {
      NotificationService.instance.isInBackground.value = false;
      _notifyPeersOnline();
    }
  }

  Future<void> _notifyPeersOffline() async {
    try {
      debugPrint('[App] Engine detach — stopping BLE');
      await BleService.instance.stop();
      debugPrint('[App] BLE stopped');
    } catch (e) {
      debugPrint('[App] Error stopping: $e');
    }
  }

  Future<void> _notifyPeersOnline() async {
    try {
      debugPrint('[App] Notifying peers - back online');
      await applyConnectionTransport();
      unawaited(NotificationService.instance.clearApplicationIconBadge());
      if (RuntimePlatform.isIos && AppSettings.instance.connectionMode != 1) {
        unawaited(_startLiveActivity());
      }
    } catch (e) {
      debugPrint('[App] Error restarting: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [appRouteObserver],
      title: 'Rlink',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) child,
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: AudioQueueMiniPlayer(),
              ),
            ),
          ],
        );
      },
      themeMode: settings.themeMode,
      theme: _buildTheme(settings.accentColor, Brightness.light),
      darkTheme: _buildTheme(settings.accentColor, Brightness.dark),
      locale: settings.resolvedLocale,
      supportedLocales: const [
        Locale('ru'),
        Locale('en'),
        Locale('es'),
        Locale('de'),
        Locale('fr'),
        Locale('uk'),
        Locale('zh'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: !_ready
          ? const _SplashScreen()
          : _hasProfile
              ? const ChatListScreen()
              : const OnboardingScreen(),
    );
  }

  ThemeData _buildTheme(Color accent, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = isDark ? ThemeData.dark() : ThemeData.light();

    // Font size scaling: 0=small(0.85), 1=medium(1.0), 2=large(1.2)
    final fontScale = const [0.85, 1.0, 1.2][AppSettings.instance.fontSize];
    TextTheme scaled = GoogleFonts.googleSansTextTheme(base.textTheme);

    // Android: Noto Color Emoji как fallback — ближе к единому виду с iOS (вкл. в настройках).
    final emojiFallback =
        (RuntimePlatform.isAndroid && AppSettings.instance.useIosStyleEmoji)
            ? [GoogleFonts.notoColorEmoji().fontFamily!]
            : <String>[];

    TextStyle? addEmoji(TextStyle? st) {
      if (st == null) return st;
      if (emojiFallback.isEmpty) return st;
      final existing = st.fontFamilyFallback ?? <String>[];
      return st.copyWith(fontFamilyFallback: [...existing, ...emojiFallback]);
    }

    scaled = scaled.copyWith(
      displayLarge: addEmoji(scaled.displayLarge),
      displayMedium: addEmoji(scaled.displayMedium),
      displaySmall: addEmoji(scaled.displaySmall),
      headlineLarge: addEmoji(scaled.headlineLarge),
      headlineMedium: addEmoji(scaled.headlineMedium),
      headlineSmall: addEmoji(scaled.headlineSmall),
      titleLarge: addEmoji(scaled.titleLarge),
      titleMedium: addEmoji(scaled.titleMedium),
      titleSmall: addEmoji(scaled.titleSmall),
      bodyLarge: addEmoji(scaled.bodyLarge),
      bodyMedium: addEmoji(scaled.bodyMedium),
      bodySmall: addEmoji(scaled.bodySmall),
      labelLarge: addEmoji(scaled.labelLarge),
      labelMedium: addEmoji(scaled.labelMedium),
      labelSmall: addEmoji(scaled.labelSmall),
    );

    if (fontScale != 1.0) {
      // Don't use apply(fontSizeFactor:) — it asserts fontSize != null on
      // every style, but GoogleFonts may leave some null. Scale manually.
      TextStyle? s(TextStyle? st) => st == null || st.fontSize == null
          ? st
          : st.copyWith(fontSize: st.fontSize! * fontScale);
      scaled = scaled.copyWith(
        displayLarge: s(scaled.displayLarge),
        displayMedium: s(scaled.displayMedium),
        displaySmall: s(scaled.displaySmall),
        headlineLarge: s(scaled.headlineLarge),
        headlineMedium: s(scaled.headlineMedium),
        headlineSmall: s(scaled.headlineSmall),
        titleLarge: s(scaled.titleLarge),
        titleMedium: s(scaled.titleMedium),
        titleSmall: s(scaled.titleSmall),
        bodyLarge: s(scaled.bodyLarge),
        bodyMedium: s(scaled.bodyMedium),
        bodySmall: s(scaled.bodySmall),
        labelLarge: s(scaled.labelLarge),
        labelMedium: s(scaled.labelMedium),
        labelSmall: s(scaled.labelSmall),
      );
    }

    final cs = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      surface: isDark ? const Color(0xFF121212) : Colors.white,
      surfaceContainerHigh:
          isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F0F0),
    );

    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5),
      colorScheme: cs,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      iconTheme: IconThemeData(color: cs.onSurface),
      primaryIconTheme: IconThemeData(color: cs.onSurface),
      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurfaceVariant,
        textColor: cs.onSurface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: accent.withValues(alpha: 0.15),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: cs.primary, size: 24);
          }
          return IconThemeData(color: cs.onSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final base = scaled.labelMedium ?? const TextStyle(fontSize: 12);
          if (states.contains(WidgetState.selected)) {
            return base.copyWith(
                color: cs.primary, fontWeight: FontWeight.w600);
          }
          return base.copyWith(color: cs.onSurfaceVariant);
        }),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
        foregroundColor: isDark ? Colors.white : Colors.black87,
        iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black87),
        actionsIconTheme:
            IconThemeData(color: isDark ? Colors.white : Colors.black87),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorColor: accent,
        labelColor: accent,
        unselectedLabelColor: Colors.grey,
      ),
      textTheme: scaled,
      useMaterial3: true,
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mark = Image.asset(
      'assets/branding/rlink_mark.png',
      width: 72,
      height: 72,
      filterQuality: FilterQuality.high,
    );
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          dark
              ? ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    0.42,
                    0,
                    0,
                    0,
                    28,
                    0,
                    0.42,
                    0,
                    0,
                    28,
                    0,
                    0,
                    0.42,
                    0,
                    28,
                    0,
                    0,
                    0,
                    1,
                    0,
                  ]),
                  child: mark,
                )
              : mark,
          const SizedBox(height: 16),
          Text(
            'Rlink',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ]),
      ),
    );
  }
}
