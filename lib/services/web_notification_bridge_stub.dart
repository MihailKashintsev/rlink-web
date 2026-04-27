Future<void> requestWebNotificationPermission() async {}

Future<void> showWebNotification({
  required String title,
  required String body,
  String? tag,
}) async {}

Future<void> syncWebPushSubscription({
  required String relayServerUrl,
  required String publicKey,
  required String nick,
}) async {}
