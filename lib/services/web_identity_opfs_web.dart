// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:web/web.dart' as web;

const _fileName = 'rlink_identity.json';

/// Origin Private File System — persists across reloads for same origin
/// without relying on third‑party cookie / partitioned storage quirks.
Future<String?> readIdentityJsonFromOpfs() async {
  try {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final fh = await root
        .getFileHandle(
          _fileName,
          web.FileSystemGetFileOptions(create: false),
        )
        .toDart;
    final file = await fh.getFile().toDart;
    final text = await file.text().toDart;
    return text.toDart;
  } catch (_) {
    return null;
  }
}

Future<void> writeIdentityJsonToOpfs(String json) async {
  try {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final fh = await root
        .getFileHandle(
          _fileName,
          web.FileSystemGetFileOptions(create: true),
        )
        .toDart;
    final writable = await fh.createWritable().toDart;
    final blob = web.Blob([json.toJS].toJS);
    await writable.write(blob).toDart;
    await writable.close().toDart;
  } catch (_) {}
}

/// Human-visible backup (Downloads). Same JSON as OPFS.
void triggerIdentityDownload(String json, String shortId) {
  try {
    final blob = web.Blob([json.toJS].toJS);
    final url = web.URL.createObjectURL(blob);
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = 'rlink-key-$shortId.rlink.json';
    web.document.body?.appendChild(a);
    a.click();
    a.remove();
    web.URL.revokeObjectURL(url);
  } catch (_) {}
}

/// Parse exported / OPFS payload and return flat key map for [WebAccountBundle].
Map<String, String>? parseIdentityExport(String raw) {
  try {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if ((j['v'] as num?)?.toInt() != 1) return null;
    final edPr = j['edPr'] as String?;
    final edPu = j['edPu'] as String?;
    final xPr = j['xPr'] as String?;
    final xPu = j['xPu'] as String?;
    final prof = j['prof'] as String?;
    if (edPr == null ||
        edPu == null ||
        xPr == null ||
        xPu == null ||
        edPr.isEmpty ||
        edPu.isEmpty ||
        xPr.isEmpty ||
        xPu.isEmpty) {
      return null;
    }
    return {
      'mesh_identity_private': edPr,
      'mesh_identity_public': edPu,
      'mesh_x25519_private': xPr,
      'mesh_x25519_public': xPu,
      if (prof != null && prof.isNotEmpty) 'rlink_user_profile': prof,
    };
  } catch (_) {
    return null;
  }
}

String buildIdentityExportJson({
  required String edPrivB64,
  required String edPubB64,
  required String xPrivB64,
  required String xPubB64,
  String? profileJson,
}) {
  return jsonEncode(<String, dynamic>{
    'v': 1,
    'edPr': edPrivB64,
    'edPu': edPubB64,
    'xPr': xPrivB64,
    'xPu': xPubB64,
    if (profileJson != null && profileJson.isNotEmpty) 'prof': profileJson,
  });
}

/// User-selected backup file (same JSON as OPFS / registration download).
Future<String?> pickAndReadIdentityBackupFile() async {
  final c = Completer<String?>();
  final input = html.FileUploadInputElement()
    ..accept = '.json,.rlink.json,application/json'
    ..style.display = 'none';
  html.document.body?.append(input);
  void done(String? v) {
    if (!c.isCompleted) c.complete(v);
    input.remove();
  }

  late final StreamSubscription<html.Event> sub;
  sub = input.onChange.listen((_) async {
    await sub.cancel();
    final files = input.files;
    if (files == null || files.isEmpty) {
      done(null);
      return;
    }
    final reader = html.FileReader();
    reader.onLoadEnd.listen((__) {
      final r = reader.result;
      done(r is String ? r : null);
    });
    reader.onError.listen((_) => done(null));
    reader.readAsText(files.first);
  });
  input.click();
  return c.future.timeout(
    const Duration(minutes: 3),
    onTimeout: () {
      input.remove();
      return null;
    },
  );
}

void reloadWebApp() => html.window.location.reload();
