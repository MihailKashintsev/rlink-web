// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Future<void> requestWebNotificationPermission() async {
  if (!html.Notification.supported) return;
  try {
    await html.Notification.requestPermission();
  } catch (_) {}
}

Future<void> showWebNotification({
  required String title,
  required String body,
  String? tag,
}) async {
  if (!html.Notification.supported) return;
  if (html.Notification.permission != 'granted') return;
  try {
    html.Notification(
      title,
      body: body,
      tag: tag,
    );
  } catch (_) {}
}
