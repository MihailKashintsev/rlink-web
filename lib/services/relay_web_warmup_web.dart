// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Future<void> warmupRelayWebSession(String baseUrl) async {
  final healthUrl = '$baseUrl/health';
  try {
    await html.HttpRequest.request(
      healthUrl,
      method: 'GET',
      withCredentials: true,
    );
  } catch (_) {}
}
