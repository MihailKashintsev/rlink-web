import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ui/screens/onboarding_screen.dart';
import 'ble_service.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gigachat_service.dart';
import 'group_service.dart';
import 'media_upload_queue.dart';
import 'profile_service.dart';
import 'relay_service.dart';
import 'story_service.dart';

/// Полный сброс приложения и переход на экран регистрации.
Future<void> rlinkPerformFullAppReset(BuildContext context) async {
  try {
    await BleService.instance.stop();
  } catch (_) {}
  BleService.instance.clearMappings();
  await ChatStorageService.instance.resetAll();
  await ChannelService.instance.resetAll();
  await GroupService.instance.resetAll();
  await StoryService.instance.reset();
  await MediaUploadQueue.instance.clearAll();
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  await storage.deleteAll();
  await GigachatService.instance.clear();
  await CryptoService.instance.regenerateKeys();
  try {
    RelayService.instance.reconnect();
  } catch (_) {}
  ProfileService.instance.clearProfile();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    (route) => false,
  );
}
