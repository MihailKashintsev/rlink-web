import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_settings.dart';

/// Единая служба локальных уведомлений.
///
/// Показывает уведомления для:
/// - личных сообщений;
/// - сообщений групп;
/// - постов каналов;
/// когда пользователь **не в этом чате** (экран закрыт/app в фоне, пока ОС
/// держит процесс живым — типичный BLE-mesh сценарий).
///
/// Push-серверов у нас нет сознательно: идея — минимум данных на серверах.
/// Если приложение убито ОС — уведомление прилетит при следующем запуске.
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
    const init = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
      macOS: macInit,
      linux: linuxInit,
    );
    await _plugin.initialize(init);
  }

  /// Запрашивает разрешения на уведомления (iOS/Android 13+/macOS).
  Future<void> requestPermissions() async {
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
    if (!_initialised) await init();
    try {
      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: 'Rlink: $channelName',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
      );
      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: threadIdentifier,
      );
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: payload,
      );
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
