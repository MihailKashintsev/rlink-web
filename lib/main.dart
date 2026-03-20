import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/chat_message.dart';
import 'models/contact.dart';
import 'services/ble_service.dart';
import 'services/chat_storage_service.dart';
import 'services/crypto_service.dart';
import 'services/gossip_router.dart';
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
      // bleId — BLE device ID отправителя (для маппинга)
      // publicKey — Ed25519 ключ из профиля
      onProfile: (bleId, publicKey, nick, color, emoji) async {
        // Регистрируем маппинг BLE ID → публичный ключ
        BleService.instance.registerPeerKey(bleId, publicKey);

        // Сохраняем контакт в БД ПЕРЕД тем как убрать лоадер
        // Порядок критичен: markProfileReceived триггерит UI rebuild,
        // который должен найти контакт уже в БД
        final existing =
            await ChatStorageService.instance.getContact(publicKey);
        if (existing == null) {
          final contact = Contact(
            publicKeyHex: publicKey,
            nickname: nick,
            avatarColor: color,
            avatarEmoji: emoji,
            addedAt: DateTime.now(),
          );
          await ChatStorageService.instance.saveContact(contact);
          debugPrint(
              '[Profile] Auto-saved contact: $nick (key: ${publicKey.substring(0, 8)}...)');
        } else {
          // Обновляем профиль — ник/цвет/эмодзи могли измениться
          await ChatStorageService.instance.updateContact(Contact(
            publicKeyHex: publicKey,
            nickname: nick,
            avatarColor: color,
            avatarEmoji: emoji,
            addedAt: existing.addedAt,
          ));
          debugPrint(
              '[Profile] Updated contact: $nick (key: ${publicKey.substring(0, 8)}...)');
        }

        // Убираем лоадер ПОСЛЕ сохранения контакта — UI увидит правильные данные
        BleService.instance.markProfileReceived(bleId);
      },
    );

    // При подключении нового пира — отправляем свой профиль
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
    };

    await BleService.instance.start();

    if (!Platform.isAndroid) {
      unawaited(_checkUpdate());
    }
  } catch (e) {
    debugPrint('[main] Init error: $e');
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
