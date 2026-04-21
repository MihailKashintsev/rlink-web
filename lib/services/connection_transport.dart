import 'dart:async';
import 'dart:io';

import 'app_settings.dart';
import 'ble_service.dart';
import 'profile_service.dart';
import 'relay_service.dart';
import 'wifi_direct_service.dart';

/// Применяет режим «Тип связи» из [AppSettings.connectionMode]:
/// - `0` — только Bluetooth (без Wi‑Fi Direct и без relay).
/// - `1` — только интернет (relay).
/// - `2` — Bluetooth + Wi‑Fi Direct (Android) + интернет.
Future<void> applyConnectionTransport() async {
  final mode = AppSettings.instance.connectionMode;

  if (mode != 1) {
    await BleService.instance.start();
  } else {
    await BleService.instance.stop();
  }

  if (Platform.isAndroid && mode == 2) {
    final p = ProfileService.instance.profile;
    await WifiDirectService.instance.start(userName: p?.nickname ?? 'Rlink');
  } else {
    await WifiDirectService.instance.stop();
  }

  if (mode >= 1) {
    unawaited(RelayService.instance.connect());
  } else {
    RelayService.instance.disconnect();
  }
}
