/// Non-web stubs — OPFS / file backup only used on web.
Future<String?> readIdentityJsonFromOpfs() async => null;

Future<void> writeIdentityJsonToOpfs(String json) async {}

void triggerIdentityDownload(String json, String shortId) {}

Future<bool> confirmIdentityDownloadPrompt() async => true;

Map<String, String>? parseIdentityExport(String raw) => null;

String buildIdentityExportJson({
  required String edPrivB64,
  required String edPubB64,
  required String xPrivB64,
  required String xPubB64,
  String? profileJson,
  String? settingsJson,
  String? channelsJson,
  String? groupsJson,
  String? chatsJson,
}) =>
    '{"v":0}';

Future<String?> pickAndReadIdentityBackupFile() async => null;

void reloadWebApp() {}
