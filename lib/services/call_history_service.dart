import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chat_storage_service.dart';

/// Одна запись в журнале звонков (локально на устройстве).
class CallHistoryEntry {
  final String id;
  final String peerId;
  final String peerDisplayName;
  final int endedAtMs;
  final int durationMs;
  final bool incoming;
  final bool video;

  const CallHistoryEntry({
    required this.id,
    required this.peerId,
    required this.peerDisplayName,
    required this.endedAtMs,
    required this.durationMs,
    required this.incoming,
    required this.video,
  });

  DateTime get endedAt =>
      DateTime.fromMillisecondsSinceEpoch(endedAtMs, isUtc: false);

  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerId': peerId,
        'peerDisplayName': peerDisplayName,
        'endedAtMs': endedAtMs,
        'durationMs': durationMs,
        'incoming': incoming,
        'video': video,
      };

  factory CallHistoryEntry.fromJson(Map<String, dynamic> m) {
    return CallHistoryEntry(
      id: m['id'] as String? ?? '',
      peerId: (m['peerId'] as String? ?? '').trim().toLowerCase(),
      peerDisplayName: m['peerDisplayName'] as String? ?? '',
      endedAtMs: (m['endedAtMs'] as num?)?.toInt() ?? 0,
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      incoming: m['incoming'] == true,
      video: m['video'] == true,
    );
  }
}

/// Локальная история звонков (до [_kMaxEntries] записей).
class CallHistoryService {
  CallHistoryService._();
  static final CallHistoryService instance = CallHistoryService._();

  static const int _kMaxEntries = 200;

  final ValueNotifier<int> version = ValueNotifier(0);
  List<CallHistoryEntry> _entries = [];
  File? _file;
  Future<void>? _ready;

  List<CallHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> _ensureReady() async {
    if (_file != null) return;
    _ready ??= () async {
      final dir = await getApplicationDocumentsDirectory();
      _file = File(p.join(dir.path, 'call_history.json'));
      await _load();
      version.value++;
    }();
    await _ready;
  }

  /// Подгрузить файл истории (для экрана вкладки).
  Future<void> ensureLoaded() => _ensureReady();

  Future<void> _load() async {
    final f = _file;
    if (f == null || !await f.exists()) {
      _entries = [];
      return;
    }
    try {
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _entries = [];
        return;
      }
      _entries = decoded
          .whereType<Map>()
          .map((e) => CallHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.peerId.length >= 8)
          .toList();
    } catch (e) {
      debugPrint('[CallHistory] load failed: $e');
      _entries = [];
    }
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    try {
      final encoded = jsonEncode(_entries.map((e) => e.toJson()).toList());
      await f.writeAsString(encoded);
    } catch (e) {
      debugPrint('[CallHistory] save failed: $e');
    }
  }

  static Future<String> _resolveDisplayName(String peerId) async {
    final c = await ChatStorageService.instance.getContact(peerId);
    final n = c?.nickname.trim() ?? '';
    if (n.isNotEmpty) return n;
    if (peerId.length >= 12) return '${peerId.substring(0, 8)}…';
    return peerId;
  }

  /// Завершённый или прерванный звонок ([CallService._cleanup]).
  Future<void> recordCallEnded({
    required String peerId,
    required Duration duration,
    required bool incoming,
    required bool video,
  }) async {
    if (peerId.trim().length < 8) return;
    final normalized = peerId.trim().toLowerCase();
    await _ensureReady();
    final name = await _resolveDisplayName(normalized);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = '${now}_$normalized';
    _entries.insert(
      0,
      CallHistoryEntry(
        id: id,
        peerId: normalized,
        peerDisplayName: name,
        endedAtMs: now,
        durationMs: duration.inMilliseconds.clamp(0, 86400000 * 1000),
        incoming: incoming,
        video: video,
      ),
    );
    while (_entries.length > _kMaxEntries) {
      _entries.removeLast();
    }
    version.value++;
    await _save();
  }

  /// Отклонённый входящий (ещё до поднятия трубки).
  Future<void> recordRejectedIncoming({
    required String peerId,
    required bool video,
  }) async {
    await recordCallEnded(
      peerId: peerId,
      duration: Duration.zero,
      incoming: true,
      video: video,
    );
  }
}
