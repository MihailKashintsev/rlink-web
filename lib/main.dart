import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/chat_message.dart';
import 'models/contact.dart';
import 'services/app_settings.dart';
import 'services/channel_service.dart';
import 'services/ether_service.dart';
import 'services/ble_service.dart';
import 'services/chat_storage_service.dart';
import 'services/group_service.dart';
import 'services/crypto_service.dart';
import 'services/gossip_router.dart';
import 'services/image_service.dart';
import 'services/name_filter.dart';
import 'services/profile_service.dart';
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
Future<void> broadcastMyAvatar() async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final imagePath = ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
  if (imagePath != null) {
    await _broadcastAvatar(myProfile.publicKeyHex, imagePath);
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
      onMessage: (fromId, encrypted, messageId, replyToMessageId) async {
        debugPrint(
            '[Main] onMessage fromId=${fromId.substring(0, 16)} ephemeral=${encrypted.ephemeralPublicKey.isEmpty ? "empty" : "set"}');

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

        // Если незнакомец — автоматически создаём временный контакт
        final existing = await ChatStorageService.instance.getContact(fromId);
        if (existing == null) {
          final btName = BleService.instance.getDeviceName(fromId);
          final displayName = btName.isNotEmpty &&
                  btName !=
                      fromId.substring(0, btName.length.clamp(0, fromId.length))
              ? btName
              : '${fromId.substring(0, 8)}...';
          await ChatStorageService.instance.saveContact(Contact(
            publicKeyHex: fromId,
            nickname: displayName,
            avatarColor: 0xFF607D8B,
            avatarEmoji: '',
            addedAt: now,
          ));
          debugPrint('[RLINK][Main] Auto-created stranger contact: $displayName');
        }

        // Сохраняем сообщение в БД немедленно (peerId = fromId = public key)
        await ChatStorageService.instance.saveMessage(ChatMessage(
          id: msgId,
          peerId: fromId,
          text: text,
          replyToMessageId: replyToMessageId,
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
      onStory: (storyId, authorId, text, bgColor) {
        debugPrint('[RLINK][Main] onStory: author=${authorId.substring(0, 16)} text=${text.substring(0, text.length.clamp(0, 20))}');
        StoryService.instance.addStory(StoryItem(
          id: storyId,
          authorId: authorId,
          text: text,
          bgColor: bgColor,
          createdAt: DateTime.now(),
        ));
      },
      onPairReq: (bleId, publicKey, nick, color, emoji, x25519Key) {
        debugPrint('[RLINK][Main] Pair request from $nick ($bleId)');
        // Store x25519 key if provided
        if (x25519Key.isNotEmpty) {
          BleService.instance.registerPeerX25519Key(publicKey, x25519Key);
          unawaited(ChatStorageService.instance.updateContactX25519Key(publicKey, x25519Key));
        }
        final info = <String, dynamic>{
          'publicKey': publicKey,
          'nick': nick,
          'color': color,
          'emoji': emoji,
          'x25519Key': x25519Key,
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
      onPairAcc: (bleId, publicKey, nick, color, emoji, x25519Key) async {
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
        BleService.instance.setExchangeState(publicKey, 3); // complete
        // Force-clear all pending entries for this device
        BleService.instance.clearPendingForPublicKey(publicKey);
        try {
          await ChatStorageService.instance.saveContact(Contact(
            publicKeyHex: publicKey,
            nickname: nick,
            avatarColor: color,
            avatarEmoji: emoji,
            addedAt: DateTime.now(),
          ));
          unawaited(_updateEtherNameFilter());
        } catch (_) {}
        // Send our profile back
        final myProfile = ProfileService.instance.profile;
        if (myProfile != null) {
          await GossipRouter.instance.broadcastProfile(
            id: myProfile.publicKeyHex,
            nick: myProfile.nickname,
            color: myProfile.avatarColor,
            emoji: myProfile.avatarEmoji,
            x25519Key: CryptoService.instance.x25519PublicKeyBase64,
          );
          // Also send avatar
          final imagePath = ImageService.instance.resolveStoredPath(myProfile.avatarImagePath);
          if (imagePath != null) {
            unawaited(_broadcastAvatar(myProfile.publicKeyHex, imagePath));
          }
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

        final isAvatar = ImageService.instance.isAvatarAssembly(msgId);
        final isVoice = ImageService.instance.isVoiceAssembly(msgId);
        final isVideo = ImageService.instance.isVideoAssembly(msgId);
        final isFile = ImageService.instance.isFileAssembly(msgId);
        final senderKey = ImageService.instance.assemblyFromId(msgId).isNotEmpty
            ? ImageService.instance.assemblyFromId(msgId)
            : fromId;

        // Helper: ensure contact exists
        Future<void> ensureContact() async {
          final existing =
              await ChatStorageService.instance.getContact(senderKey);
          if (existing == null) {
            await ChatStorageService.instance.saveContact(Contact(
              publicKeyHex: senderKey,
              nickname: '${senderKey.substring(0, 8)}...',
              avatarColor: 0xFF607D8B,
              avatarEmoji: '',
              addedAt: DateTime.now(),
            ));
          }
        }

        if (isAvatar) {
          final path = await ImageService.instance.assembleAndSave(
            msgId,
            forContactKey: senderKey,
          );
          if (path != null) {
            await ChatStorageService.instance
                .updateContactAvatarImage(senderKey, path);
          }
        } else if (isVoice) {
          final path = await ImageService.instance.assembleAndSaveVoice(msgId);
          if (path == null) return;
          await ensureContact();
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
        } else if (isFile) {
          final origName = ImageService.instance.assemblyFileName(msgId);
          final path = await ImageService.instance.assembleAndSaveFile(msgId);
          if (path == null) return;
          await ensureContact();
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
        } else if (isVideo) {
          final isSquare = ImageService.instance.isSquareAssembly(msgId);
          final path = await ImageService.instance.assembleAndSaveVideo(msgId, isSquare: isSquare);
          if (path == null) return;
          await ensureContact();
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
        } else {
          final path = await ImageService.instance.assembleAndSave(msgId);
          if (path == null) return;

          // Check if this image belongs to a story (msgId == storyId)
          final existingStory = StoryService.instance.findStory(msgId);
          if (existingStory != null) {
            existingStory.imagePath = path;
            StoryService.instance.notifyUpdate();
            debugPrint('[RLINK][Main] Story image received for ${msgId.substring(0, 8)}');
            return;
          }

          await ensureContact();
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
        }
      },
      // bleId — BLE device ID источника пакета (для маппинга)
      // publicKey — Ed25519 ключ из payload профиля
      // x25519Key — X25519 ключ base64 для E2E шифрования (пустая строка у старых версий)
      onProfile: (bleId, publicKey, nick, color, emoji, x25519Key) async {
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
                avatarColor: color,
                avatarEmoji: emoji,
                avatarImagePath: oldContact.avatarImagePath,
                addedAt: oldContact.addedAt,
              ));
              await ChatStorageService.instance
                  .deleteContact(oldContact.publicKeyHex);
            } else {
              await ChatStorageService.instance.saveContact(Contact(
                publicKeyHex: publicKey,
                nickname: nick,
                avatarColor: color,
                avatarEmoji: emoji,
                addedAt: DateTime.now(),
              ));
              debugPrint(
                  '[Profile] Auto-saved contact: $nick (key: ${publicKey.substring(0, 8)}...) direct=$isDirect');
            }
          } else {
            // Обновляем существующий контакт
            await ChatStorageService.instance.updateContact(Contact(
              publicKeyHex: publicKey,
              nickname: nick,
              avatarColor: color,
              avatarEmoji: emoji,
              avatarImagePath: existing.avatarImagePath,
              addedAt: existing.addedAt,
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

    // При подключении нового пира — НЕ отправляем профиль автоматически.
    // Обмен профилями происходит только по приглашению (pair_req → pair_acc).
    BleService.instance.onPeerConnected = (peerId) async {
      debugPrint('[BLE] Peer connected: $peerId (no auto-profile, waiting for invite)');
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

/// Отправляет аватар-изображение по BLE (fire-and-forget, вызывается из onPeerConnected).
/// Аватар ~ 8–15 KB → ~120 чанков → ~6 секунд передачи (с задержками для BLE стека).
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
    final chunks = ImageService.instance.splitToBase64Chunks(bytes);
    final msgId = const Uuid().v4();
    debugPrint('[RLINK][Avatar] Starting broadcast: ${chunks.length} chunks, ${bytes.length} bytes');
    await GossipRouter.instance.sendImgMeta(
      msgId: msgId,
      totalChunks: chunks.length,
      fromId: myPublicKey,
      isAvatar: true,
    );
    // Small delay after meta to let receiver initialize assembly
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
    debugPrint('[RLINK][Avatar] Sent ${chunks.length} chunks via BLE+relay');
  } catch (e) {
    debugPrint('[RLINK][Avatar] Send failed: $e');
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

  // Ensure contact exists
  Future<void> ensureContact() async {
    final existing = await ChatStorageService.instance.getContact(senderKey);
    if (existing == null) {
      await ChatStorageService.instance.saveContact(Contact(
        publicKeyHex: senderKey,
        nickname: '${senderKey.substring(0, 8)}...',
        avatarColor: 0xFF607D8B,
        avatarEmoji: '',
        addedAt: DateTime.now(),
      ));
    }
  }

  if (isVoice) {
    final path = await ImageService.instance.assembleAndSaveVoice(msgId);
    if (path == null) { debugPrint('[RLINK][Blob] Voice assemble failed'); return; }
    await ensureContact();
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
    debugPrint('[RLINK][Blob] Voice saved: $path');
  } else if (isFile) {
    final origName = fileName ?? ImageService.instance.assemblyFileName(msgId);
    final path = await ImageService.instance.assembleAndSaveFile(msgId);
    if (path == null) { debugPrint('[RLINK][Blob] File assemble failed'); return; }
    await ensureContact();
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
    debugPrint('[RLINK][Blob] File saved: $path ($origName)');
  } else if (isVideo) {
    final path = await ImageService.instance.assembleAndSaveVideo(msgId, isSquare: isSquare);
    if (path == null) { debugPrint('[RLINK][Blob] Video assemble failed'); return; }
    await ensureContact();
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
    debugPrint('[RLINK][Blob] Video saved: $path (square=$isSquare)');
  } else {
    // Image
    final path = await ImageService.instance.assembleAndSave(msgId);
    if (path == null) { debugPrint('[RLINK][Blob] Image assemble failed'); return; }

    // Check if this image belongs to a story
    final existingStory = StoryService.instance.findStory(msgId);
    if (existingStory != null) {
      existingStory.imagePath = path;
      StoryService.instance.notifyUpdate();
      debugPrint('[RLINK][Blob] Story image received for ${msgId.substring(0, 8)}');
      return;
    }

    await ensureContact();
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

Future<void> _stopLiveActivity() async {
  try {
    await _kBleChannel.invokeMethod('stopLiveActivity');
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
      // Возобновляем BLE соединение
      await BleService.instance.start();
      // Clear notification badge when app resumes
      if (Platform.isIOS) {
        unawaited(_startLiveActivity());
      }
      debugPrint('[App] BLE restarted');
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
