import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_settings.dart';
import 'sound_effects_service.dart';
import 'web_notification_bridge.dart';

/// Единая служба локальных уведомлений.
///
/// Показывает уведомления для:
/// - личных сообщений;
/// - сообщений групп;
/// - постов каналов;
/// когда пользователь **не в этом чате** (экран закрыт или в фоне).
///
/// На Android процесс в фоне держится кэшированным FlutterEngine + foreground
/// service; на Windows окно можно закрыть в трей — relay остаётся активным.
/// Принудительная остановка приложения из настроек ОС по-прежнему рвёт сеть.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _nativeBle = MethodChannel('com.rendergames.rlink/ble');

  /// Сейчас открытый экран чата/группы/канала (чтобы не дублировать нотификации).
  /// Ключи: `dm:<publicKey>`, `group:<groupId>`, `channel:<channelId>`.
  final ValueNotifier<String?> currentRoute = ValueNotifier<String?>(null);

  /// Находится ли приложение в фоне (обновляется из WidgetsBindingObserver).
  final ValueNotifier<bool> isInBackground = ValueNotifier<bool>(false);

  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false, // запросим позже (см. requestPermissions)
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const macInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linuxInit = LinuxInitializationSettings(defaultActionName: 'Открыть');
    final WindowsInitializationSettings? windowsInit =
        defaultTargetPlatform == TargetPlatform.windows
            ? const WindowsInitializationSettings(
                appName: 'Rlink',
                appUserModelId: 'com.rendergames.rlink',
                guid: 'c8f1a2b3-4d5e-6f70-a89b-0c1d2e3f4a5b',
              )
            : null;
    final init = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
      macOS: macInit,
      linux: linuxInit,
      windows: windowsInit,
    );
    await _plugin.initialize(settings: init);
  }

  /// Запрашивает разрешения на уведомления (iOS/Android 13+/macOS).
  Future<void> requestPermissions() async {
    if (!_initialised) await init();
    if (kIsWeb) {
      await requestWebNotificationPermission();
      return;
    }
    try {
      final iosImpl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);
      final macImpl = _plugin.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      await macImpl?.requestPermissions(alert: true, badge: true, sound: true);
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('[RLINK][Notif] requestPermissions failed: $e');
    }
  }

  // ── Public show methods ─────────────────────────────────────

  Future<void> showPersonalMessage({
    required String peerId,
    required String title,
    required String body,
  }) async {
    if (!AppSettings.instance.notificationsEnabled) return;
    if (!AppSettings.instance.notifyPersonal) return;
    if (currentRoute.value == 'dm:$peerId' && !isInBackground.value) return;
    await _show(
      id: _stableId('dm', peerId),
      channelId: 'personal',
      channelName: 'Личные сообщения',
      title: title,
      body: body,
      payload: 'dm:$peerId',
      threadIdentifier: peerId,
    );
  }

  Future<void> showGroupMessage({
    required String groupId,
    required String title,
    required String body,
  }) async {
    if (!AppSettings.instance.notificationsEnabled) return;
    if (!AppSettings.instance.notifyGroups) return;
    if (currentRoute.value == 'group:$groupId' && !isInBackground.value) return;
    await _show(
      id: _stableId('group', groupId),
      channelId: 'groups',
      channelName: 'Группы',
      title: title,
      body: body,
      payload: 'group:$groupId',
      threadIdentifier: 'group:$groupId',
    );
  }

  Future<void> showChannelPost({
    required String channelId,
    required String title,
    required String body,
  }) async {
    if (!AppSettings.instance.notificationsEnabled) return;
    if (!AppSettings.instance.notifyChannels) return;
    if (currentRoute.value == 'channel:$channelId' && !isInBackground.value) {
      return;
    }
    await _show(
      id: _stableId('channel', channelId),
      channelId: 'channels',
      channelName: 'Каналы',
      title: title,
      body: body,
      payload: 'channel:$channelId',
      threadIdentifier: 'channel:$channelId',
    );
  }

  /// Снимает число на иконке (iOS / счётчик на Android), не трогая список в центре уведомлений.
  Future<void> clearApplicationIconBadge() async {
    try {
      await _nativeBle.invokeMethod<void>('clearApplicationBadge');
    } catch (e) {
      debugPrint('[RLINK][Notif] clearApplicationBadge failed: $e');
    }
  }

  // ── Internals ───────────────────────────────────────────────

  Future<void> _show({
    required int id,
    required String channelId,
    required String channelName,
    required String title,
    required String body,
    required String payload,
    String? threadIdentifier,
  }) async {
    if (kIsWeb) {
      await showWebNotification(
        title: title,
        body: body,
        tag: threadIdentifier ?? payload,
      );
      return;
    }
    if (!_initialised) await init();
    try {
      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: 'Rlink: $channelName',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        playSound: false,
      );
      final darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: false,
        threadIdentifier: threadIdentifier,
      );
      final WindowsNotificationDetails? windowsDetails =
          defaultTargetPlatform == TargetPlatform.windows
              ? const WindowsNotificationDetails(
                  duration: WindowsNotificationDuration.long,
                )
              : null;
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
          windows: windowsDetails,
        ),
        payload: payload,
      );
      await SoundEffectsService.instance.playPushNotificationSound();
    } catch (e) {
      debugPrint('[RLINK][Notif] show failed: $e');
    }
  }

  /// Генерирует стабильный int id из (type, key), чтобы новая нотификация
  /// заменяла предыдущую того же диалога (Android не суммирует иначе).
  int _stableId(String type, String key) {
    final raw = '$type:$key';
    var hash = 0;
    for (final codeUnit in raw.codeUnits) {
      hash = 0x1fffffff & (hash * 31 + codeUnit);
    }
    return hash.abs();
  }
}
