import 'package:sqflite/sqflite.dart';

import 'runtime_platform.dart';

class AccountKvStore {
  AccountKvStore._();

  static const _dbName = 'rlink_account_state.db';
  static const _table = 'kv';
  static Database? _db;
  static Future<Database>? _dbFuture;

  static Future<Database> _open() {
    if (_db != null) return Future.value(_db!);
    if (_dbFuture != null) return _dbFuture!;
    _dbFuture = openDatabase(
      _dbName,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE IF NOT EXISTS $_table (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
        );
      },
    ).then((db) {
      _db = db;
      return db;
    });
    return _dbFuture!;
  }

  static Future<String?> read(String key) async {
    if (!RuntimePlatform.isWeb) return null;
    try {
      final db = await _open();
      final rows = await db.query(
        _table,
        columns: const ['v'],
        where: 'k = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final v = rows.first['v'];
      return v is String && v.isNotEmpty ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, String value) async {
    if (!RuntimePlatform.isWeb || value.isEmpty) return;
    try {
      final db = await _open();
      await db.insert(
        _table,
        <String, Object?>{'k': key, 'v': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }
}
