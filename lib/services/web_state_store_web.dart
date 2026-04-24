// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;

const _statePrefix = 'rlink_web_';
const _windowNameBucket = 'rlinkWebStateV1';

Map<String, String> _readWindowNameState() {
  try {
    final raw = html.window.name ?? '';
    if (raw.isEmpty) return <String, String>{};
    final parsed = jsonDecode(raw);
    if (parsed is! Map) return <String, String>{};
    final bucket = parsed[_windowNameBucket];
    if (bucket is! Map) return <String, String>{};
    return bucket.map((k, v) => MapEntry(k.toString(), v.toString()));
  } catch (_) {
    return <String, String>{};
  }
}

void _writeWindowNameState(Map<String, String> state) {
  try {
    final raw = html.window.name ?? '';
    Map<String, dynamic> parsed;
    try {
      final j = jsonDecode(raw);
      parsed = j is Map<String, dynamic> ? j : <String, dynamic>{};
    } catch (_) {
      parsed = <String, dynamic>{};
    }
    parsed[_windowNameBucket] = state;
    html.window.name = jsonEncode(parsed);
  } catch (_) {}
}

String? readWebState(String key) {
  final k = '$_statePrefix$key';
  try {
    final v = html.window.localStorage[k];
    if (v != null && v.isNotEmpty) return v;
  } catch (_) {}
  final wm = _readWindowNameState();
  final fromName = wm[k];
  if (fromName != null && fromName.isNotEmpty) return fromName;
  return null;
}

Future<void> writeWebState(String key, String value) async {
  final k = '$_statePrefix$key';
  try {
    html.window.localStorage[k] = value;
  } catch (_) {}
  final wm = _readWindowNameState();
  wm[k] = value;
  _writeWindowNameState(wm);
}
