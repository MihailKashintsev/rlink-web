// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

/// Previously hit `GET /health` with credentials to prime cookies for some
/// reverse proxies. That is a cross-origin XHR from static hosts (GitHub
/// Pages, Tilda parent pages, etc.) and fails CORS unless the relay sends
/// `Access-Control-Allow-Origin`. WebSocket to `wss://…` does not use CORS;
/// skipping avoids console noise and does not affect the WS session.
Future<void> warmupRelayWebSession(String baseUrl) async {}
