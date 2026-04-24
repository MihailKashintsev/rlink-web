import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Initializes IndexedDB-backed SQLite factory on web.
Future<void> initWebStorageIfNeeded() async {
  if (!kIsWeb) return;
  databaseFactory = databaseFactoryFfiWeb;
}
