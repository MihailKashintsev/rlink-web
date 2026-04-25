// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;
import 'dart:async';

const _statePrefix = 'rlink_web_';
const _windowNameBucket = 'rlinkWebStateV1';
const _bridgeReqType = 'rlink_parent_storage_req';
const _bridgeResType = 'rlink_parent_storage_res';
const _bridgeTimeout = Duration(milliseconds: 2500);

int _bridgeSeq = 0;

Map<String, dynamic>? _messageAsMap(dynamic raw) {
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }
  try {
    final type = raw['type'];
    final id = raw['id'];
    if (type != null || id != null) {
      return <String, dynamic>{
        'type': type,
        'id': id,
        'ok': raw['ok'],
        'value': raw['value'],
      };
    }
  } catch (_) {}
  return null;
}

Future<String?> _bridgeGet(String fullKey) async {
  try {
    if (html.window.parent == null || html.window.parent == html.window) {
      return null;
    }
    final id = 'get_${DateTime.now().millisecondsSinceEpoch}_${_bridgeSeq++}';
    final c = Completer<String?>();
    late StreamSubscription<html.MessageEvent> sub;
    sub = html.window.onMessage.listen((event) {
      final data = _messageAsMap(event.data);
      if (data == null) return;
      if (data['type'] != _bridgeResType) return;
      if (data['id'] != id) return;
      final ok = data['ok'] == true;
      final v = ok ? data['value'] : null;
      c.complete(v?.toString());
      sub.cancel();
    });
    html.window.parent!.postMessage({
      'type': _bridgeReqType,
      'id': id,
      'op': 'get',
      'key': fullKey,
    }, '*');
    try {
      return await c.future.timeout(_bridgeTimeout);
    } on TimeoutException {
      await sub.cancel();
      if (!c.isCompleted) c.complete(null);
      return null;
    }
  } catch (_) {
    return null;
  }
}

Future<void> _bridgeSet(String fullKey, String value) async {
  try {
    if (html.window.parent == null || html.window.parent == html.window) {
      return;
    }
    final id = 'set_${DateTime.now().millisecondsSinceEpoch}_${_bridgeSeq++}';
    final c = Completer<void>();
    late StreamSubscription<html.MessageEvent> sub;
    sub = html.window.onMessage.listen((event) {
      final data = _messageAsMap(event.data);
      if (data == null) return;
      if (data['type'] != _bridgeResType) return;
      if (data['id'] != id) return;
      c.complete();
      sub.cancel();
    });
    html.window.parent!.postMessage({
      'type': _bridgeReqType,
      'id': id,
      'op': 'set',
      'key': fullKey,
      'value': value,
    }, '*');
    try {
      await c.future.timeout(_bridgeTimeout);
    } on TimeoutException {
      await sub.cancel();
      if (!c.isCompleted) c.complete();
    }
  } catch (_) {}
}

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

Future<String?> readWebState(String key) async {
  final k = '$_statePrefix$key';
  try {
    final v = html.window.localStorage[k];
    if (v != null && v.isNotEmpty) return v;
  } catch (_) {}
  final bridged = await _bridgeGet(k);
  if (bridged != null && bridged.isNotEmpty) return bridged;
  // Retry once: iframe/parent handshake can race on cold load.
  final bridgedRetry = await _bridgeGet(k);
  if (bridgedRetry != null && bridgedRetry.isNotEmpty) return bridgedRetry;
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
  await _bridgeSet(k, value);
  final wm = _readWindowNameState();
  wm[k] = value;
  _writeWindowNameState(wm);
}
