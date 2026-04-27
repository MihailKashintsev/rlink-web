// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js' as js;

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

Future<void> syncWebPushSubscription({
  required String relayServerUrl,
  required String publicKey,
  required String nick,
}) async {
  try {
    js.context.callMethod('rlinkSyncPushSubscription', [
      relayServerUrl,
      publicKey,
      nick,
    ]);
  } catch (_) {}
}
