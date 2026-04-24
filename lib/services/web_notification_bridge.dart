import 'web_notification_bridge_stub.dart'
    if (dart.library.html) 'web_notification_bridge_web.dart' as impl;

Future<void> requestWebNotificationPermission() =>
    impl.requestWebNotificationPermission();

Future<void> showWebNotification({
  required String title,
  required String body,
  String? tag,
}) =>
    impl.showWebNotification(title: title, body: body, tag: tag);
