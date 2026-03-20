import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/chat_message.dart';
import 'models/contact.dart';
import 'services/ble_service.dart';
import 'services/chat_storage_service.dart';
import 'services/crypto_service.dart';
import 'services/gossip_router.dart';
import 'services/image_service.dart';
import 'services/profile_service.dart';
import 'services/update_service.dart';
import 'ui/screens/chat_list_screen.dart';
import 'ui/screens/onboarding_screen.dart';

final incomingMessageController = StreamController<IncomingMessage>.broadcast();
final pendingUpdateNotifier = ValueNotifier<UpdateInfo?>(null);

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
    await CryptoService.instance.init();
    await ProfileService.instance.init();
    await ChatStorageService.instance.init();

    GossipRouter.instance.init(
      myKey: CryptoService.instance.publicKeyHex,
      onMessage: (fromId, encrypted, messageId, replyToMessageId) async {
        debugPrint(
            '[Main] onMessage fromId=${fromId.substring(0, 16)} ephemeral=${encrypted.ephemeralPublicKey.isEmpty ? "empty" : "set"}');

        final String text;
        if (encrypted.ephemeralPublicKey.isEmpty) {
          text = encrypted.cipherText;
        } else {
          final plaintext =
              await CryptoService.instance.decryptMessage(encrypted);
          if (plaintext == null) return;
          text = plaintext;
        }

        final now = DateTime.now();
        final msgId = messageId;

        // Если незнакомец — автоматически создаём временный контакт
        final existing =
            await ChatStorageService.instance.getContact(fromId);
        if (existing == null) {
          final btName = BleService.instance.getDeviceName(fromId);
          final displayName = btName.isNotEmpty && btName != fromId.substring(0, btName.length.clamp(0, fromId.length))
              ? btName
              : '${fromId.substring(0, 8)}...';
          await ChatStorageService.instance.saveContact(Contact(
            publicKeyHex: fromId,
            nickname: displayName,
            avatarColor: 0xFF607D8B,
            avatarEmoji: '',
            addedAt: now,
          ));
          debugPrint('[Main] Auto-created stranger contact: $displayName');
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

        debugPrint('[Main] Adding to stream: fromId=${fromId.substring(0, 16)}');
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
      },
      onForward: (packet) async {
        await BleService.instance.broadcastPacket(packet);
      },
      onEdit: (fromId, messageId, newText) async {
        await ChatStorageService.instance.editMessage(messageId, newText);
      },
      onDelete: (fromId, messageId) async {
        await ChatStorageService.instance.deleteMessage(messageId);
      },
      onReact: (fromId, messageId, emoji) async {
        await ChatStorageService.instance.addReaction(messageId, emoji, fromId);
      },
      onImgMetaReceived: (fromId, msgId, totalChunks, isAvatar, isVoice) {
        ImageService.instance.initAssembly(
          msgId, totalChunks, isAvatar: isAvatar, isVoice: isVoice, fromId: fromId,
        );
      },
      onImgChunkReceived: (fromId, msgId, totalChunks, index, base64Data) async {
        ImageService.instance.receiveChunk(
          msgId: msgId,
          totalChunks: totalChunks,
          index: index,
          base64Data: base64Data,
        );
        if (!ImageService.instance.isComplete(msgId)) return;

        final isAvatar = ImageService.instance.isAvatarAssembly(msgId);
        final isVoice  = ImageService.instance.isVoiceAssembly(msgId);
        final senderKey = ImageService.instance.assemblyFromId(msgId).isNotEmpty
            ? ImageService.instance.assemblyFromId(msgId)
            : fromId;

        // Helper: ensure contact exists
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

        if (isAvatar) {
          final path = await ImageService.instance.assembleAndSave(
            msgId, forContactKey: senderKey,
          );
          if (path != null) {
            await ChatStorageService.instance.updateContactAvatarImage(senderKey, path);
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
        } else {
          final path = await ImageService.instance.assembleAndSave(msgId);
          if (path == null) return;
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
      // bleId — BLE device ID отправителя (для маппинга)
      // publicKey — Ed25519 ключ из профиля
      onProfile: (bleId, publicKey, nick, color, emoji) async {
        // Регистрируем маппинг BLE ID → публичный ключ
        BleService.instance.registerPeerKey(bleId, publicKey);

        // Сохраняем контакт в БД ПЕРЕД тем как убрать лоадер.
        // finally гарантирует markProfileReceived даже при ошибке БД.
        try {
          final existing =
              await ChatStorageService.instance.getContact(publicKey);
          if (existing == null) {
            await ChatStorageService.instance.saveContact(Contact(
              publicKeyHex: publicKey,
              nickname: nick,
              avatarColor: color,
              avatarEmoji: emoji,
              addedAt: DateTime.now(),
            ));
            debugPrint(
                '[Profile] Auto-saved contact: $nick (key: ${publicKey.substring(0, 8)}...)');
          } else {
            await ChatStorageService.instance.updateContact(Contact(
              publicKeyHex: publicKey,
              nickname: nick,
              avatarColor: color,
              avatarEmoji: emoji,
              avatarImagePath: existing.avatarImagePath,
              addedAt: existing.addedAt,
            ));
            debugPrint(
                '[Profile] Updated contact: $nick (key: ${publicKey.substring(0, 8)}...)');
          }
        } catch (e) {
          debugPrint('[Profile] DB error saving contact: $e');
        } finally {
          // Убираем лоадер ПОСЛЕ сохранения контакта — UI увидит правильные данные
          BleService.instance.markProfileReceived(bleId);
        }
      },
    );

    // При подключении нового пира — отправляем свой профиль + аватар
    BleService.instance.onPeerConnected = (peerId) async {
      final profile = ProfileService.instance.profile;
      if (profile == null) return;
      await Future.delayed(const Duration(milliseconds: 500));
      await GossipRouter.instance.broadcastProfile(
        id: profile.publicKeyHex,
        nick: profile.nickname,
        color: profile.avatarColor,
        emoji: profile.avatarEmoji,
      );
      debugPrint('[Profile] Sent my profile to $peerId');
      // Отправляем аватар в фоне после текстового профиля
      final imagePath = profile.avatarImagePath;
      if (imagePath != null) {
        unawaited(_broadcastAvatar(profile.publicKeyHex, imagePath));
      }
    };

    await BleService.instance.start();

    if (!Platform.isAndroid) {
      unawaited(_checkUpdate());
    }
  } catch (e) {
    debugPrint('[main] Init error: $e');
  }
}

/// Отправляет аватар-изображение по BLE (fire-and-forget, вызывается из onPeerConnected).
/// Аватар ~ 8–15 KB → ~120 чанков → ~4 секунды передачи.
Future<void> _broadcastAvatar(String myPublicKey, String imagePath) async {
  try {
    await Future.delayed(const Duration(milliseconds: 300));
    final bytes = await File(imagePath).readAsBytes();
    final chunks = ImageService.instance.splitToBase64Chunks(bytes);
    final msgId = const Uuid().v4();
    await GossipRouter.instance.sendImgMeta(
      msgId: msgId,
      totalChunks: chunks.length,
      fromId: myPublicKey,
      isAvatar: true,
    );
    for (var i = 0; i < chunks.length; i++) {
      await GossipRouter.instance.sendImgChunk(
        msgId: msgId,
        index: i,
        base64Data: chunks[i],
        fromId: myPublicKey,
      );
    }
    debugPrint('[Avatar] Sent ${chunks.length} chunks');
  } catch (e) {
    debugPrint('[Avatar] Send failed: $e');
  }
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

class _RlinkAppState extends State<RlinkApp> {
  bool _ready = false;
  bool _hasProfile = false;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rlink',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: !_ready
          ? const _SplashScreen()
          : _hasProfile
              ? const ChatListScreen()
              : const OnboardingScreen(),
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1DB954),
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF121212),
        surfaceContainerHigh: const Color(0xFF1E1E1E),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF121212),
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: Color(0xFF1DB954),
        labelColor: Color(0xFF1DB954),
        unselectedLabelColor: Colors.grey,
      ),
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
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
