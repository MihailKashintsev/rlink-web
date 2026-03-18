import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'services/ble_service.dart';
import 'services/crypto_service.dart';
import 'services/gossip_router.dart';
import 'services/update_service.dart';
import 'ui/screens/home_screen.dart';

final incomingMessageController = StreamController<IncomingMessage>.broadcast();
final pendingUpdateNotifier = ValueNotifier<UpdateInfo?>(null);

class IncomingMessage {
  final String fromId;
  final String text;
  final DateTime timestamp;
  const IncomingMessage({required this.fromId, required this.text, required this.timestamp});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Сначала показываем UI — сервисы стартуют внутри приложения
  runApp(const ProviderScope(child: MeshChatApp()));
}

Future<void> initServices() async {
  try {
    await CryptoService.instance.init();

    GossipRouter.instance.init(
      onMessage: (fromId, encrypted) async {
        final plaintext = await CryptoService.instance.decryptMessage(encrypted);
        if (plaintext != null) {
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
    );

    await BleService.instance.start();

    if (!Platform.isAndroid) {
      unawaited(_checkUpdateInBackground());
    }
  } catch (e) {
    debugPrint('[main] Service init error: $e');
  }
}

Future<void> _checkUpdateInBackground() async {
  await Future.delayed(const Duration(seconds: 5));
  final update = await UpdateService.instance.checkForUpdate();
  if (update != null) pendingUpdateNotifier.value = update;
}

class MeshChatApp extends StatefulWidget {
  const MeshChatApp({super.key});

  @override
  State<MeshChatApp> createState() => _MeshChatAppState();
}

class _MeshChatAppState extends State<MeshChatApp> {
  @override
  void initState() {
    super.initState();
    // Запускаем сервисы после первого кадра
    WidgetsBinding.instance.addPostFrameCallback((_) {
      initServices();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshChat',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.dark),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: const HomeScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    const seed = Color(0xFF1DB954);
    return ThemeData(
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      textTheme: GoogleFonts.interTextTheme(ThemeData(brightness: brightness).textTheme),
      useMaterial3: true,
    );
  }
}