import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Initializes IndexedDB-backed SQLite factory on web.
Future<void> initWebStorageIfNeeded() async {
  if (!kIsWeb) return;
  // In embedded web contexts (e.g. iframe on Tilda) shared-worker startup can
  // intermittently fail or return invalid messages. Use the non-worker factory
  // for stability; persistence is still IndexedDB-backed.
  databaseFactory = databaseFactoryFfiWebNoWebWorker;
}
