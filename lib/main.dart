import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/channel.dart';
import 'models/chat_message.dart';
import 'models/contact.dart';
import 'models/group.dart';
import 'services/app_settings.dart';
import 'services/channel_service.dart';
import 'services/ether_service.dart';
import 'services/ble_service.dart';
import 'services/block_service.dart';
import 'services/chat_storage_service.dart';
import 'services/group_service.dart';
import 'services/crypto_service.dart';
import 'services/gossip_router.dart';
import 'services/image_service.dart';
import 'services/name_filter.dart';
import 'services/profile_service.dart';
import 'services/media_upload_queue.dart';
import 'services/story_service.dart';
import 'services/relay_service.dart';
import 'services/typing_service.dart';
import 'services/update_service.dart';
import 'services/wifi_direct_service.dart';
import 'ui/screens/chat_list_screen.dart';
import 'ui/screens/onboarding_screen.dart';

const _kBleChannel = MethodChannel('com.rendergames.rlink/ble');

final incomingMessageController = StreamController<IncomingMessage>.broadcast();
final pendingUpdateNotifier = ValueNotifier<UpdateInfo?>(null);
final navigatorKey = GlobalKey<NavigatorState>();

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

Future<void> broadcastMyAvatar() async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final imagePath = ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
  if (imagePath != null) {
    await _broadcastAvatar(myProfile.publicKeyHex, imagePath);
  }
}

/// Broadcast my banner to all peers (callable from anywhere).
Future<void> broadcastMyBanner() async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final bannerPath = ImageService.instance.resolveStoredPath(myProfile.bannerImagePath);
  if (bannerPath != null) {
    await _broadcastBanner(myProfile.publicKeyHex, bannerPath);
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
    final pending = await ChatStorageService.instance.getPendingOutgoingMessages();
    if (pending.isEmpty) return;
    debugPrint('[RLINK][Outbox] Flushing ${pending.length} pending messages');
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    for (final m in pending) {
      if (!RelayService.instance.isConnected) break;
      // Только текстовые сообщения — медиа требуют отдельной повторной загрузки.
      if (m.imagePath != null || m.videoPath != null ||
          m.voicePath != null || m.filePath != null) {
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
      case 0: HapticFeedback.lightImpact();
      case 1: HapticFeedback.mediumImpact();
      case 2: HapticFeedback.heavyImpact();
      default: HapticFeedback.selectionClick();
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
    '🎉', '🎊', '🥳', '🎈', '🎁', '✨', '💫', '🌟', '⭐', '🔥',
    '💥', '🎆', '🎇', '🌈', '🦄', '🐉', '🚀', '🛸', '👾', '🤖',
    '💜', '💙', '💚', '💛', '🧡', '❤️', '🤍', '🖤', '💎', '👑',
    '🎵', '🎶', '🎸', '🥁', '🎺', '🎻', '🎹', '🎤', '🎧', '🪩',
    '🦋', '🌸', '🌺', '🌻', '🍀', '🌴', '🌙', '☀️', '🪐', '🌍',
    '🐱', '🐶', '🦊', '🐼', '🐨', '🦁', '🐯', '🦈', '🐙', '🦑',
    '🍕', '🍩', '🍪', '🧁', '🎂', '🍰', '🍫', '🍬', '🍭', '🧃',
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
    hash = (hash * 31 + sorted[0].codeUnitAt(i % sorted[0].length) +
        sorted[1].codeUnitAt(i % sorted[1].length)) & 0x7FFFFFFF;
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
  runApp(const ProviderScope(child: RlinkApp()));
}

Future<void> initServices() async {
  try {
    // Запрашиваем все необходимые разрешения при первом запуске
    if (Platform.isAndroid) {
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
    } else if (Platform.isIOS) {
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
    EtherService.instance.init();
    await ImageService.instance.init(); // Must be before ProfileService (path resolution)
    await CryptoService.instance.init();
    await ProfileService.instance.init();
    await ChatStorageService.instance.init();
    await ChannelService.instance.init();
    await GroupService.instance.init();
    await StoryService.instance.init();
    await MediaUploadQueue.instance.init();
    await MediaUploadQueue.instance.cleanUp();

    // Restore X25519 keys from contacts DB (survive app restarts)
    try {
      final savedContacts = await ChatStorageService.instance.getContacts();
      for (final c in savedContacts) {
        if (c.x25519Key != null && c.x25519Key!.isNotEmpty) {
          BleService.instance.registerPeerX25519Key(c.publicKeyHex, c.x25519Key!);
        }
      }
      debugPrint('[RLINK][Init] Loaded ${savedContacts.where((c) => c.x25519Key != null && c.x25519Key!.isNotEmpty).length} X25519 keys from DB');
    } catch (e) {
      debugPrint('[RLINK][Init] Failed to load X25519 keys: $e');
    }

    // Populate ether name filter with known contacts + own name
    _updateEtherNameFilter();

    GossipRouter.instance.init(
      myKey: CryptoService.instance.publicKeyHex,
      onMessage: (fromId, encrypted, messageId, replyToMessageId,
          {double? latitude, double? longitude}) async {
        debugPrint(
            '[Main] onMessage fromId=${fromId.substring(0, 16)} ephemeral=${encrypted.ephemeralPublicKey.isEmpty ? "empty" : "set"}');

        // Заблокированный отправитель — молча выкидываем сообщение.
        if (BlockService.instance.isBlocked(fromId)) {
          debugPrint('[Block] Dropped text from blocked ${fromId.substring(0, 8)}');
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
            debugPrint('[RLINK][Main] Dropping malformed encrypted message (missing fields)');
            return;
          }
          final plaintext =
              await CryptoService.instance.decryptMessage(encrypted);
          if (plaintext == null) {
            debugPrint('[RLINK][Main] Decryption failed! from=${fromId.substring(0, 16)} msgId=$messageId');
            debugPrint('[RLINK][Main] Trying fallback: x25519 key present=${BleService.instance.getPeerX25519Key(fromId) != null}');
            return;
          }
          text = plaintext;
        }

        final now = DateTime.now();
        final msgId = messageId;

        // Сохраняем сообщение в БД (peerId = fromId = public key).
        // Контакт НЕ создаётся автоматически — только через pair_req/pair_acc.
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
            final contact = await ChatStorageService.instance.getContact(fromId);
            final senderName = contact?.nickname ?? '${fromId.substring(0, 8)}…';
            final preview = text.length > 60 ? '${text.substring(0, 60)}…' : text;
            await _kBleChannel.invokeMethod('showNotification', {
              'title': senderName,
              'body': preview,
              'threadId': fromId, // group by sender
              'sound': AppSettings.instance.notifSound,
              'vibration': AppSettings.instance.notifVibration,
            });
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

        // Update Dynamic Island with latest message
        if (Platform.isIOS) {
          final contact = await ChatStorageService.instance.getContact(fromId);
          final senderName = contact?.nickname ?? '${fromId.substring(0, 8)}…';
          try {
            _kBleChannel.invokeMethod('updateLiveActivity', {
              'peers': BleService.instance.peersCount.value,
              'sender': senderName,
              'message': text.length > 40 ? '${text.substring(0, 40)}…' : text,
              'signal': _bestSignalLevel(),
            });
          } catch (_) {}
        }
      },
      onAck: (fromId, messageId) async {
        // fromId reserved for protocol symmetry; keep referenced to satisfy lints.
        if (fromId.isEmpty) return;
        await ChatStorageService.instance.updateMessageStatus(
          messageId,
          MessageStatus.delivered,
        );
      },
      onForward: (packet) async {
        final mode = AppSettings.instance.connectionMode;
        // 1. BLE mesh broadcast (skip in Internet-only mode)
        if (mode != 1) {
          await BleService.instance.broadcastPacket(packet);
        }
        // 2. WiFi Direct (if running, skip in Internet-only mode)
        if (mode != 1 && WifiDirectService.instance.isRunning) {
          unawaited(WifiDirectService.instance.sendToAll(packet.encode()));
        }
        // 3. Relay (internet) — prefer directed send for private messages
        if (RelayService.instance.isConnected &&
            AppSettings.instance.connectionMode >= 1) {
          try {
            // Extract full recipient key from payload context
            final rid8 = packet.payload['r'] as String?;
            String? recipientKey;
            if (rid8 != null) {
              // Look up full key from known peers
              recipientKey = RelayService.instance.findPeerByPrefix(rid8);
            }
            if (recipientKey != null && recipientKey.isNotEmpty) {
              // Directed send — reliable, goes straight to recipient
              await RelayService.instance.sendPacket(packet, recipientKey: recipientKey);
              debugPrint('[RLINK][Forward] Relay DIRECTED to ${recipientKey.substring(0, 8)} type=${packet.type}');
            } else {
              // Broadcast fallback — goes to all connected peers
              await RelayService.instance.broadcastPacket(packet);
              debugPrint('[RLINK][Forward] Relay BROADCAST type=${packet.type} rid8=$rid8');
            }
          } catch (e) {
            debugPrint('[RLINK][Forward] Relay send failed: $e');
          }
        }
      },
      onEdit: (fromId, messageId, newText) async {
        await ChatStorageService.instance.editMessage(messageId, newText);
      },
      onDelete: (fromId, messageId) async {
        await ChatStorageService.instance.deleteMessage(messageId);
      },
      onReact: (fromId, messageId, emoji) async {
        await ChatStorageService.instance
            .toggleReaction(messageId, emoji, fromId);
      },
      onImgMetaReceived: (String fromId, String msgId, int totalChunks,
          bool isAvatar, bool isVoice, bool isVideo, bool isSquare,
          bool isFile, String? fileName) {
        ImageService.instance.initAssembly(
          msgId,
          totalChunks,
          isAvatar: isAvatar,
          isVoice: isVoice,
          fromId: fromId,
          isVideo: isVideo,
          isSquare: isSquare,
          isFile: isFile,
          fileName: fileName,
        );
      },
      onEther: (id, text, color, senderId, senderNick) {
        debugPrint('[RLINK][Main] onEther: text=${text.substring(0, text.length.clamp(0, 20))} sender=$senderNick');
        EtherService.instance.addMessage(EtherMessage(
          id: id,
          text: text,
          color: color,
          receivedAt: DateTime.now(),
          senderId: senderId,
          senderNick: senderNick,
        ));
      },
      onStory: (storyId, authorId, text, bgColor, textX, textY, textSize) {
        debugPrint('[RLINK][Main] onStory: author=${authorId.substring(0, 16)} text=${text.substring(0, text.length.clamp(0, 20))}');
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
      onPairReq: (bleId, publicKey, nick, username, color, emoji, x25519Key, tags) {
        // Игнорируем pair-запросы от заблокированных.
        if (BlockService.instance.isBlocked(publicKey)) {
          debugPrint('[Block] Dropped pair_req from blocked ${publicKey.substring(0, 8)}');
          return;
        }
        debugPrint('[RLINK][Main] Pair request from $nick ($bleId)');
        // Store x25519 key and username
        if (x25519Key.isNotEmpty) {
          BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
          unawaited(ChatStorageService.instance.updateContactX25519Key(publicKey, x25519Key));
        }
        if (username.isNotEmpty) {
          RelayService.instance.registerPeerUsername(publicKey, username);
        }
        final info = <String, dynamic>{
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
              debugPrint('[RLINK][Main] Navigator ctx null, retry ${attempt + 1}/5');
              Future.delayed(const Duration(milliseconds: 300), () => tryShowScreen(attempt + 1));
            } else {
              debugPrint('[RLINK][Main] Could not show pair screen after 5 retries');
            }
          });
        }
        tryShowScreen(0);
      },
      onPairAcc: (bleId, publicKey, nick, username, color, emoji, x25519Key, tags) async {
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
          unawaited(ChatStorageService.instance.updateContactX25519Key(publicKey, x25519Key));
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
          final existing = await ChatStorageService.instance.getContact(publicKey);
          final isStub = existing != null &&
              RegExp(r'^[0-9a-fA-F]{8}\.\.\.').hasMatch(existing.nickname);
          await ChatStorageService.instance.saveContact(Contact(
            publicKeyHex: publicKey,
            nickname: (existing != null && !isStub) ? existing.nickname : nick,
            username: username.isNotEmpty ? username : (existing?.username ?? ''),
            avatarColor: color,
            avatarEmoji: emoji,
            avatarImagePath: existing?.avatarImagePath,
            x25519Key: x25519Key.isNotEmpty ? x25519Key : existing?.x25519Key,
            addedAt: existing?.addedAt ?? DateTime.now(),
            tags: tags.isNotEmpty ? tags : (existing?.tags ?? const []),
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
          debugPrint('[RLINK][Chunks] msgId=$msgId already completed via blob, skipping');
          return;
        }

        final isAvatar = ImageService.instance.isAvatarAssembly(msgId);
        final isVoice = ImageService.instance.isVoiceAssembly(msgId);
        final isVideo = ImageService.instance.isVideoAssembly(msgId);
        final isFile = ImageService.instance.isFileAssembly(msgId);
        final isBanner = msgId.startsWith('banner_');
        final senderKey = ImageService.instance.assemblyFromId(msgId).isNotEmpty
            ? ImageService.instance.assemblyFromId(msgId)
            : fromId;

        if (isBanner) {
          // Banner image via BLE chunks — save as contact banner
          final path = await ImageService.instance.assembleAndSave(
            msgId,
            forContactKey: '${senderKey}_banner',
          );
          if (path != null) {
            ImageService.instance.markCompleted(msgId);
            _evictImageCache(path);
            final existing = await ChatStorageService.instance.getContact(senderKey);
            if (existing != null) {
              await ChatStorageService.instance.saveContact(
                existing.copyWith(bannerImagePath: path));
              debugPrint('[RLINK][Banner] Saved BLE banner for ${senderKey.substring(0, 8)}');
            }
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
          final msg = ChatMessage(
            id: msgId,
            peerId: senderKey,
            text: '🎤 Голосовое',
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
            voicePath: path,
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
          final origName = ImageService.instance.assemblyFileName(msgId);
          final path = await ImageService.instance.assembleAndSaveFile(msgId);
          if (path == null) return;
          ImageService.instance.markCompleted(msgId);
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
          final isSquare = ImageService.instance.isSquareAssembly(msgId);
          final path = await ImageService.instance.assembleAndSaveVideo(msgId, isSquare: isSquare);
          if (path == null) return;
          ImageService.instance.markCompleted(msgId);
          final label = isSquare ? '⬛ Видео' : '📹 Видео';
          final msg = ChatMessage(
            id: msgId,
            peerId: senderKey,
            text: label,
            isOutgoing: false,
            timestamp: DateTime.now(),
            status: MessageStatus.delivered,
            videoPath: path,
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

          // Check if this image belongs to a story (msgId == storyId)
          final existingStory = StoryService.instance.findStory(msgId);
          if (existingStory != null) {
            existingStory.imagePath = path;
            StoryService.instance.notifyUpdate();
            debugPrint('[RLINK][Main] Story image received for ${msgId.substring(0, 8)}');
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
      onProfile: (bleId, publicKey, nick, username, color, emoji, x25519Key, tags) async {
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
          unawaited(ChatStorageService.instance.updateContactX25519Key(publicKey, x25519Key));
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
              (c) => c.publicKeyHex != publicKey && (
                c.nickname == nick || // ник совпадает — ротация ключа
                (hexStubRe.hasMatch(c.nickname.replaceAll('...', '')) &&
                 publicKey.startsWith(c.nickname.replaceAll('...', ''))) // стаб с hex-префиксом нашего ключа
              ),
            );
          } catch (_) {
            oldContact = null;
          }

          // Дополнительно: если для прямого пира есть BLE UUID-контакт — удалить/перенести
          if (isDirect && oldContact == null) {
            try {
              oldContact = allContactsForDedup.firstWhere(
                (c) => c.publicKeyHex != publicKey &&
                  c.publicKeyHex == bleId, // контакт создан под BLE UUID
              );
            } catch (_) {
              oldContact = null;
            }
          }

          if (existing == null) {
            if (oldContact != null) {
              // Стаб или смена ключа: переносим историю и удаляем старый
              debugPrint(
                  '[Profile] Merging stub/rotated contact for $nick: '
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
              addedAt: existing.addedAt,
              tags: tags.isNotEmpty ? tags : existing.tags,
              bannerImagePath: existing.bannerImagePath,
            ));
            // Если нашли ник-дубликат или стаб с другим ключом — переносим историю и удаляем
            if (oldContact != null) {
              debugPrint(
                  '[Profile] Removing duplicate/stub for $nick: '
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
          final allPeerIds =
              await ChatStorageService.instance.getChatPeerIds();
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
              await ChatStorageService.instance
                  .migrateMessages(pid, publicKey);
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
            final avatarPath = ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
            if (avatarPath != null) {
              unawaited(_broadcastAvatar(myProfile.publicKeyHex, avatarPath));
            }
          }
        }
      },
    );

    // ── Channel/Group packet handlers ──────────────────────────────
    GossipRouter.instance.onChannelMeta = (payload) {
      final channelId = payload['channelId'] as String?;
      final name = payload['name'] as String?;
      final adminId = payload['adminId'] as String?;
      if (channelId == null || name == null || adminId == null) return;
      final subs = (payload['subscriberIds'] as List<dynamic>?)?.cast<String>() ?? [adminId];
      final mods = (payload['moderatorIds'] as List<dynamic>?)?.cast<String>() ?? [];
      final ch = Channel(
        id: channelId,
        name: name,
        adminId: adminId,
        subscriberIds: subs,
        moderatorIds: mods,
        avatarColor: payload['avatarColor'] as int? ?? 0xFF42A5F5,
        avatarEmoji: payload['avatarEmoji'] as String? ?? '📢',
        description: payload['description'] as String?,
        commentsEnabled: payload['commentsEnabled'] as bool? ?? true,
        createdAt: payload['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        verified: payload['verified'] as bool? ?? false,
        verifiedBy: payload['verifiedBy'] as String?,
        username: payload['username'] as String? ?? '',
        universalCode: payload['universalCode'] as String? ?? '',
        isPublic: payload['isPublic'] as bool? ?? true,
      );
      ChannelService.instance.saveChannelFromBroadcast(ch);
    };
    GossipRouter.instance.onChannelPost = (payload) {
      final channelId = payload['channelId'] as String?;
      final postId = payload['postId'] as String?;
      final authorId = payload['authorId'] as String?;
      if (channelId == null || postId == null || authorId == null) return;
      ChannelService.instance.savePost(ChannelPost(
        id: postId,
        channelId: channelId,
        authorId: authorId,
        text: payload['text'] as String? ?? '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
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
        ChannelService.instance.subscribe(channelId, userId);
      }
    };
    GossipRouter.instance.onChannelInvite = (payload) {
      final channelId = payload['channelId'] as String?;
      final channelName = payload['channelName'] as String?;
      final adminId = payload['adminId'] as String?;
      final inviterId = payload['inviterId'] as String?;
      final inviterNick = payload['inviterNick'] as String?;
      if (channelId == null || channelName == null || adminId == null ||
          inviterId == null || inviterNick == null) { return; }
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
        createdAt: payload['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ));
    };
    GossipRouter.instance.onChannelHistoryReq = (payload) async {
      final channelId = payload['channelId'] as String?;
      final requesterId = payload['requesterId'] as String?;
      final sinceTs = (payload['sinceTs'] as int?) ?? 0;
      if (channelId == null || requesterId == null) return;
      final me = CryptoService.instance.publicKeyHex;
      if (me.isEmpty || me == requesterId) return;
      // Отвечают только те, у кого есть посты: обычно это админ,
      // но подойдут и старые подписчики.
      final ch = await ChannelService.instance.getChannel(channelId);
      if (ch == null) return;
      final posts = await ChannelService.instance.getPosts(channelId, limit: 50);
      for (final post in posts) {
        if (post.timestamp <= sinceTs) continue;
        await GossipRouter.instance.sendChannelPost(
          channelId: channelId,
          postId: post.id,
          authorId: post.authorId,
          text: post.text,
        );
        await Future.delayed(const Duration(milliseconds: 50));
      }
      debugPrint('[RLINK][Channel] Replied to history request for $channelId'
          ' with ${posts.length} posts');
    };
    GossipRouter.instance.onChannelComment = (payload) {
      final postId = payload['postId'] as String?;
      final commentId = payload['commentId'] as String?;
      final authorId = payload['authorId'] as String?;
      final text = payload['text'] as String?;
      if (postId == null || commentId == null || authorId == null || text == null) return;
      ChannelService.instance.saveComment(ChannelComment(
        id: commentId,
        postId: postId,
        authorId: authorId,
        text: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    };
    // Универсальный обработчик реакций для историй/постов/комментов/групп.
    GossipRouter.instance.onReactionExt = (payload) async {
      final kind = payload['kind'] as String?;
      final targetId = payload['targetId'] as String?;
      final emoji = payload['emoji'] as String?;
      final from = payload['from'] as String?;
      if (kind == null || targetId == null || emoji == null || from == null) return;
      switch (kind) {
        case 'story':
          StoryService.instance.applyIncomingReaction(targetId, emoji, from);
          break;
        case 'channel_post':
          await ChannelService.instance.togglePostReaction(targetId, emoji, from);
          break;
        case 'channel_comment':
          await ChannelService.instance.toggleCommentReaction(targetId, emoji, from);
          break;
        case 'group_message':
          await GroupService.instance.toggleMessageReaction(targetId, emoji, from);
          break;
      }
    };
    // Удаляет историю при получении story_del от автора
    GossipRouter.instance.onStoryDelete = (storyId, authorId) {
      debugPrint('[RLINK][Stories] story_del: $storyId from ${authorId.substring(0, authorId.length.clamp(0, 8))}');
      StoryService.instance.deleteStory(storyId, authorId);
    };

    // Регистрирует просмотр истории (приходит от зрителя, обрабатывается у автора)
    GossipRouter.instance.onStoryView = (storyId, viewerId) {
      debugPrint('[RLINK][Stories] story_view: $storyId from ${viewerId.substring(0, viewerId.length.clamp(0, 8))}');
      StoryService.instance.addViewer(storyId, viewerId);
    };

    // Отвечает на story_req: переотправляет свои активные истории и их картинки
    GossipRouter.instance.onStoryRequest = (fromId) async {
      final myKey = CryptoService.instance.publicKeyHex;
      if (myKey.isEmpty) return;
      final myStories = StoryService.instance.storiesFor(myKey);
      if (myStories.isEmpty) return;
      debugPrint('[RLINK][Stories] story_req from ${fromId.substring(0, 8)}, re-sending ${myStories.length} stories');
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

    // Синхронизация хэша пароля от другого устройства администратора
    GossipRouter.instance.onAdminConfig = (payload) async {
      final hash = payload['hash'] as String?;
      if (hash != null && hash.isNotEmpty) {
        await AppSettings.instance.setAdminPasswordHash(hash);
        debugPrint('[RLINK][Admin] Admin password hash updated from peer');
      }
    };
    GossipRouter.instance.onGroupMessage = (payload) {
      final groupId = payload['groupId'] as String?;
      final senderId = payload['senderId'] as String?;
      final text = payload['text'] as String?;
      final messageId = payload['messageId'] as String?;
      if (groupId == null || senderId == null || text == null || messageId == null) return;
      final myKey = CryptoService.instance.publicKeyHex;
      GroupService.instance.saveMessage(GroupMessage(
        id: messageId,
        groupId: groupId,
        senderId: senderId,
        text: text,
        isOutgoing: senderId == myKey,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    };
    GossipRouter.instance.onGroupInvite = (payload) {
      final groupId = payload['groupId'] as String?;
      final groupName = payload['groupName'] as String?;
      final inviterId = payload['inviterId'] as String?;
      final inviterNick = payload['inviterNick'] as String?;
      final creatorId = payload['creatorId'] as String?;
      final memberIds = (payload['memberIds'] as List<dynamic>?)?.cast<String>() ?? [];
      if (groupId == null || groupName == null || inviterId == null ||
          inviterNick == null || creatorId == null) { return; }
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
        createdAt: payload['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
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
      ChannelService.instance.applyAdminAction(
          channelId: channelId, foreignAgent: value);
    };
    GossipRouter.instance.onChannelBlock = (payload) {
      final channelId = payload['channelId'] as String?;
      final value = payload['value'] as bool? ?? true;
      if (channelId == null) return;
      debugPrint('[RLINK] Channel $channelId blocked = $value');
      ChannelService.instance.applyAdminAction(
          channelId: channelId, blocked: value);
    };
    GossipRouter.instance.onChannelAdminDelete = (payload) {
      final channelId = payload['channelId'] as String?;
      if (channelId == null) return;
      debugPrint('[RLINK] Channel $channelId deleted by admin');
      ChannelService.instance.applyAdminAction(
          channelId: channelId, delete: true);
    };

    // При подключении BLE-пира — автоматически рассылаем свой профиль.
    // Это позволяет контактам обновить наш ник/аватар без ручного переприглашения.
    // Пакет 'profile' с TTL≥1 — не показывает диалог, только обновляет контакт.
    BleService.instance.onPeerConnected = (peerId) async {
      debugPrint('[BLE] Peer connected: $peerId — broadcasting profile + requesting stories');
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

    // Start BLE only if not Internet-only mode
    if (AppSettings.instance.connectionMode != 1) {
      await BleService.instance.start();
    } else {
      debugPrint('[RLINK][Init] BLE skipped — Internet-only mode');
    }

    // Start WiFi Direct transport (Android only, skip in Internet-only mode)
    if (Platform.isAndroid && AppSettings.instance.connectionMode != 1) {
      final myProfile = ProfileService.instance.profile;
      unawaited(WifiDirectService.instance.start(
        userName: myProfile?.nickname ?? 'Rlink',
      ));
    }

    // Start relay (internet) transport
    if (AppSettings.instance.connectionMode >= 1) {
      RelayService.instance.onBlobReceived = _onBlobReceived;
      RelayService.instance.onPeerOnline = _onRelayPeerOnline;
      // When relay connects, send profile to all online peers so they get our username
      RelayService.instance.state.addListener(() {
        if (RelayService.instance.isConnected) {
          // Small delay to let presence data arrive from server
          Future.delayed(const Duration(seconds: 2), _sendProfileToOnlinePeers);
          // Попробовать досылать зависшие исходящие сообщения.
          Future.delayed(const Duration(seconds: 3), flushOutbox);
          // Request stories from online peers so we see them even after reconnect.
          Future.delayed(const Duration(seconds: 4), _requestStoriesFromPeers);
          // Resume any pending background uploads.
          Future.delayed(const Duration(seconds: 5), MediaUploadQueue.instance.processQueue);
        }
      });
      unawaited(RelayService.instance.connect());
    }

    // Start Dynamic Island Live Activity on iOS
    if (Platform.isIOS) {
      unawaited(_startLiveActivity());
      // Update Live Activity when peers/relay count changes
      BleService.instance.peersCount.addListener(_updateLiveActivity);
      RelayService.instance.onlineCount.addListener(_updateLiveActivity);
      RelayService.instance.state.addListener(_updateLiveActivity);
    }

    // Проверка обновлений (Android → RuStore, десктоп → GitHub releases)
    unawaited(_checkUpdate());
  } catch (e) {
    debugPrint('[RLINK][main] Init error: $e');
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
    },
  );
  try {
    await RelayService.instance.sendPacket(packet, recipientKey: peerKey);
    debugPrint('[RLINK][Profile] Sent DIRECTED profile to ${peerKey.substring(0, 8)}');
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
  final imagePath = ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
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
      debugPrint('[RLINK][Avatar] Sent avatar blob to ${peerKey.substring(0, 8)}');
    } catch (e) {
      debugPrint('[RLINK][Avatar] Avatar blob to ${peerKey.substring(0, 8)} failed: $e');
    }
  }

  // Send banner blob
  final bannerPath = ImageService.instance.resolveStoredPath(myProfile.bannerImagePath);
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
      debugPrint('[RLINK][Banner] Sent banner blob to ${peerKey.substring(0, 8)}');
    } catch (e) {
      debugPrint('[RLINK][Banner] Banner blob to ${peerKey.substring(0, 8)} failed: $e');
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
    );
    debugPrint('[RLINK][Profile] Gossip-broadcast profile');
  } catch (e) {
    debugPrint('[RLINK][Profile] Gossip broadcast failed: $e');
  }

  // 3) Re-broadcast avatar + banner so visuals refresh everywhere.
  if (myProfile.avatarImagePath != null && myProfile.avatarImagePath!.isNotEmpty) {
    unawaited(_broadcastAvatar(myKey, myProfile.avatarImagePath!));
  }
  if (myProfile.bannerImagePath != null && myProfile.bannerImagePath!.isNotEmpty) {
    unawaited(broadcastMyBanner());
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
        debugPrint('[RLINK][Avatar] Sent relay blob to ${contacts.length} contacts');
      } catch (e) {
        debugPrint('[RLINK][Avatar] Relay blob failed: $e');
      }
    }

    // BLE chunk path — only in modes that use BLE (0=BLE only, 2=Both)
    if (AppSettings.instance.connectionMode != 1) {
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final msgId = const Uuid().v4();
      debugPrint('[RLINK][Avatar] Starting BLE broadcast: ${chunks.length} chunks, ${bytes.length} bytes');
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
      debugPrint('[RLINK][Banner] Sent banner via relay to ${contacts.length} contacts');
    }
    // BLE chunks — only in modes that use BLE (0=BLE only, 2=Both)
    if (AppSettings.instance.connectionMode != 1) {
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final bleMsgId = 'banner_${myPublicKey.substring(0, 16)}_${const Uuid().v4().substring(0, 8)}';
      await GossipRouter.instance.sendImgMeta(
        msgId: bleMsgId,
        totalChunks: chunks.length,
        fromId: myPublicKey,
        isAvatar: false,
      );
      await Future.delayed(const Duration(milliseconds: 200));
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: bleMsgId, index: i, base64Data: chunks[i], fromId: myPublicKey,
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

/// Handle blob received from relay — reassemble into a file and save message
void _onBlobReceived(String fromId, String msgId, Uint8List data,
    bool isVoice, bool isVideo, bool isSquare, bool isFile, String? fileName) async {
  debugPrint('[RLINK][Blob] Received ${data.length} bytes from ${fromId.substring(0, 8)} msgId=$msgId voice=$isVoice video=$isVideo file=$isFile');

  // Заблокированный отправитель — молча выкидываем blob.
  if (BlockService.instance.isBlocked(fromId)) {
    debugPrint('[Block] Dropped blob from blocked ${fromId.substring(0, 8)}');
    return;
  }

  // Dedup: if this msgId was already assembled via gossip chunks, skip
  if (ImageService.instance.wasAlreadyCompleted(msgId)) {
    debugPrint('[RLINK][Blob] msgId=$msgId already completed via chunks, skipping');
    return;
  }

  // Handle avatar blob — save as contact avatar, not a chat message
  if (msgId.startsWith('avatar_')) {
    try {
      final decompressed = ImageService.instance.decompress(data);
      final avatarPath = await ImageService.instance.saveContactAvatar(
        fromId, decompressed,
      );
      // Файл перезаписан с тем же путём — сбрасываем кэш Flutter,
      // иначе UI продолжит показывать старую картинку.
      _evictImageCache(avatarPath);
      await ChatStorageService.instance.updateContactAvatarImage(fromId, avatarPath);
      debugPrint('[RLINK][Avatar] Saved relay avatar for ${fromId.substring(0, 8)} → $avatarPath');
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
      final bannerPath = await ImageService.instance.saveBannerImage(fromId, decompressed);
      _evictImageCache(bannerPath);
      final existing = await ChatStorageService.instance.getContact(fromId);
      if (existing != null) {
        // saveContact fires contactsNotifier, so UI auto-refreshes.
        await ChatStorageService.instance.saveContact(existing.copyWith(bannerImagePath: bannerPath));
        debugPrint('[RLINK][Banner] Saved relay banner for ${fromId.substring(0, 8)} → $bannerPath');
      }
    } catch (e) {
      debugPrint('[RLINK][Banner] Failed to save relay banner: $e');
    }
    return;
  }

  // Handle story VIDEO blob — msgId format: 'story_vid_<storyId>'
  if (msgId.startsWith('story_vid_')) {
    try {
      final storyId = msgId.substring('story_vid_'.length);
      final decompressed = ImageService.instance.decompress(data);
      final videoPath = await ImageService.instance.saveStoryVideo(storyId, decompressed);
      final story = StoryService.instance.findStory(storyId);
      if (story != null) {
        story.videoPath = videoPath;
        StoryService.instance.notifyUpdate();
        debugPrint('[RLINK][Story] Attached relay video to story ${storyId.substring(0, storyId.length.clamp(0, 8))}');
      } else {
        // История ещё не пришла — кэшируем видео и прикрепим при появлении.
        StoryService.instance.cachePendingVideo(storyId, videoPath);
        debugPrint('[RLINK][Story] Cached pending video for ${storyId.substring(0, storyId.length.clamp(0, 8))}');
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
        'story_$storyId', decompressed,
      );
      final story = StoryService.instance.findStory(storyId);
      if (story != null) {
        story.imagePath = imagePath;
        StoryService.instance.notifyUpdate();
        debugPrint('[RLINK][Story] Attached relay image to story ${storyId.substring(0, 8)}');
      } else {
        // История ещё не пришла — кэшируем картинку и прикрепим при появлении.
        StoryService.instance.cachePendingImage(storyId, imagePath);
        debugPrint('[RLINK][Story] Cached pending image for ${storyId.substring(0, 8)}');
      }
    } catch (e) {
      debugPrint('[RLINK][Story] Failed to save relay story image: $e');
    }
    return;
  }

  // Feed directly to ImageService as if all chunks arrived at once
  ImageService.instance.initAssembly(
    msgId, 1,
    isAvatar: false,
    isVoice: isVoice,
    fromId: fromId,
    isVideo: isVideo,
    isSquare: isSquare,
    isFile: isFile,
    fileName: fileName,
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
    if (path == null) { debugPrint('[RLINK][Blob] Voice assemble failed'); return; }
    ImageService.instance.markCompleted(msgId);

    final msg = ChatMessage(
      id: msgId,
      peerId: senderKey,
      text: '🎤 Голосовое',
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      voicePath: path,
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: '🎤 Голосовое',
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance.sendAck(
        messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] Voice saved: $path');
  } else if (isFile) {
    final origName = fileName ?? ImageService.instance.assemblyFileName(msgId);
    final path = await ImageService.instance.assembleAndSaveFile(msgId);
    if (path == null) { debugPrint('[RLINK][Blob] File assemble failed'); return; }
    ImageService.instance.markCompleted(msgId);

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
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: fileLabel,
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance.sendAck(
        messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] File saved: $path ($origName)');
  } else if (isVideo) {
    final path = await ImageService.instance.assembleAndSaveVideo(msgId, isSquare: isSquare);
    if (path == null) { debugPrint('[RLINK][Blob] Video assemble failed'); return; }
    ImageService.instance.markCompleted(msgId);

    final label = isSquare ? '⬛ Видео' : '📹 Видео';
    final msg = ChatMessage(
      id: msgId,
      peerId: senderKey,
      text: label,
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      videoPath: path,
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: label,
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance.sendAck(
        messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] Video saved: $path (square=$isSquare)');
  } else {
    // Image
    final path = await ImageService.instance.assembleAndSave(msgId);
    if (path == null) { debugPrint('[RLINK][Blob] Image assemble failed'); return; }
    ImageService.instance.markCompleted(msgId);

    // Check if this image belongs to a story
    final existingStory = StoryService.instance.findStory(msgId);
    if (existingStory != null) {
      existingStory.imagePath = path;
      StoryService.instance.notifyUpdate();
      debugPrint('[RLINK][Blob] Story image received for ${msgId.substring(0, 8)}');
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
    );
    await ChatStorageService.instance.saveMessage(msg);
    incomingMessageController.add(IncomingMessage(
      fromId: senderKey,
      text: '',
      timestamp: msg.timestamp,
      msgId: msgId,
    ));
    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance.sendAck(
        messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    debugPrint('[RLINK][Blob] Image saved: $path');
  }
}

Future<void> _startLiveActivity() async {
  try {
    await _kBleChannel.invokeMethod('startLiveActivity', {
      'peers': BleService.instance.peersCount.value,
      'sender': '',
      'message': '',
      'signal': _bestSignalLevel(),
    });
    debugPrint('[RLINK][LiveActivity] Started');
  } catch (e) {
    debugPrint('[RLINK][LiveActivity] Start failed: $e');
  }
}

void _updateLiveActivity() {
  final blePeers = BleService.instance.peersCount.value;
  final relayOnline = RelayService.instance.onlineCount.value;
  final mode = AppSettings.instance.connectionMode;
  // Show relevant count based on connection mode
  final String statusText;
  if (mode == 0) {
    statusText = 'BLE: $blePeers рядом';
  } else if (mode == 1) {
    statusText = 'Онлайн: $relayOnline';
  } else {
    statusText = 'BLE: $blePeers · Онлайн: $relayOnline';
  }
  try {
    _kBleChannel.invokeMethod('updateLiveActivity', {
      'peers': blePeers + relayOnline,
      'sender': statusText,
      'message': '',
      'signal': _bestSignalLevel(),
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
      await initServices();
      if (mounted) {
        setState(() {
          _ready = true;
          _hasProfile = ProfileService.instance.hasProfile;
        });
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

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Отправляем статус "я вышел из сети"
      _notifyPeersOffline();
    } else if (state == AppLifecycleState.resumed) {
      // Восстанавливаем соединение
      _notifyPeersOnline();
    }
  }

  Future<void> _notifyPeersOffline() async {
    try {
      debugPrint('[App] Notifying peers - going offline');
      // Отправляем сигнал отключения через BLE (останавливаем рекламу)
      await BleService.instance.stop();
      debugPrint('[App] BLE stopped');
    } catch (e) {
      debugPrint('[App] Error stopping: $e');
    }
  }

  Future<void> _notifyPeersOnline() async {
    try {
      debugPrint('[App] Notifying peers - back online');
      // Возобновляем BLE только если пользователь его не отключил.
      // connectionMode: 0=BLE only, 1=Internet only, 2=Both.
      if (AppSettings.instance.connectionMode != 1) {
        await BleService.instance.start();
        debugPrint('[App] BLE restarted');
      } else {
        // Если по какой-то причине BLE всё ещё работает — гасим его.
        try { await BleService.instance.stop(); } catch (_) {}
        debugPrint('[App] BLE skipped on resume — Internet-only mode');
      }
      // Force-reconnect relay (it may have dropped while suspended).
      if (AppSettings.instance.connectionMode >= 1 &&
          !RelayService.instance.isConnected) {
        unawaited(RelayService.instance.connect());
      }
      // Clear notification badge when app resumes
      if (Platform.isIOS) {
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
      title: 'Rlink',
      debugShowCheckedModeBanner: false,
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
    TextTheme scaled = GoogleFonts.interTextTheme(base.textTheme);

    // On Android, add Noto Color Emoji as font fallback so emojis render
    // consistently (colorful, similar to iOS Apple Color Emoji style).
    final emojiFallback = Platform.isAndroid
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

    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ).copyWith(
        surface: isDark ? const Color(0xFF121212) : Colors.white,
        surfaceContainerHigh: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F0F0),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
        foregroundColor: isDark ? Colors.white : Colors.black87,
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
    return const Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bluetooth, size: 64, color: Color(0xFF1DB954)),
          SizedBox(height: 16),
          Text('Rlink',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}
