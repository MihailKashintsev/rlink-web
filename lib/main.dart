import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

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
  const IncomingMessage(
      {required this.fromId, required this.text, required this.timestamp});
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
      onMessage: (fromId, encrypted) async {
        debugPrint(
            '[Main] onMessage fromId=${fromId.substring(0, 16)} ephemeral=${encrypted.ephemeralPublicKey.isEmpty ? "empty" : "set"}');
        // fromId — Ed25519 public key отправителя
        if (encrypted.ephemeralPublicKey.isEmpty) {
          debugPrint(
              '[Main] Adding to stream: fromId=${fromId.substring(0, 16)}');
          incomingMessageController.add(IncomingMessage(
            fromId: fromId,
            text: encrypted.cipherText,
            timestamp: DateTime.now(),
          ));
          return;
        }
        final plaintext =
            await CryptoService.instance.decryptMessage(encrypted);
        if (plaintext != null) {
          debugPrint(
              '[Main] Adding to stream: fromId=${fromId.substring(0, 16)}');
          incomingMessageController.add(IncomingMessage(
            fromId: fromId,
            text: plaintext,
            timestamp: DateTime.now(),
          ));
        }
      },
      onForward: (packet) async {
        await BleService.instance.broadcastPacket(packet);
      },
      // bleId — BLE device ID отправителя (для маппинга)
      // publicKey — Ed25519 ключ из профиля
      onProfile: (bleId, publicKey, nick, color, emoji) async {
        // Регистрируем маппинг BLE ID → публичный ключ
        BleService.instance.registerPeerKey(bleId, publicKey);

        // Сохраняем контакт с его именем
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
          await ChatStorageService.instance.updateContactLastSeen(publicKey);
        }
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
