import 'package:flutter/foundation.dart';

class DiagnosticsLogService {
  DiagnosticsLogService._();
  static final DiagnosticsLogService instance = DiagnosticsLogService._();

  static const int _maxEntries = 200;
  final ValueNotifier<List<String>> entries = ValueNotifier<List<String>>([]);

  void add(String line) {
    final ts = DateTime.now().toIso8601String();
    final next = List<String>.from(entries.value)..add('[$ts] $line');
    if (next.length > _maxEntries) {
      next.removeRange(0, next.length - _maxEntries);
    }
    entries.value = next;
  }

  void clear() {
    entries.value = <String>[];
  }

  String dump() => entries.value.join('\n');
}
