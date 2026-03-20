import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/contact.dart';

class ChatStorageService {
  ChatStorageService._();
  static final ChatStorageService instance = ChatStorageService._();

  Database? _db;

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _contactsNotifier.value = [];
  }

  Future<void> resetAll() async {
    await close();
    // Очищаем кэш нотификаторов сообщений
    _messagesNotifiers.clear();
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'rlink.db');
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'rlink.db');
    _db = await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('''
        CREATE TABLE contacts (
          id        TEXT PRIMARY KEY,
          nick      TEXT NOT NULL,
          color     INTEGER NOT NULL,
          emoji     TEXT NOT NULL,
          added_at  INTEGER NOT NULL,
          last_seen INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE messages (
          id          TEXT PRIMARY KEY,
          peer_id     TEXT NOT NULL,
          text        TEXT NOT NULL,
          is_outgoing INTEGER NOT NULL,
          timestamp   INTEGER NOT NULL,
          status      INTEGER NOT NULL DEFAULT 1
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_messages_peer ON messages(peer_id, timestamp)');
    });
    debugPrint('[DB] Initialized');
  }

  // ── Контакты ─────────────────────────────────────────────────

  Future<void> saveContact(Contact contact) async {
    await _db?.insert('contacts', contact.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _contactsNotifier.value = await getContacts();
  }

  Future<void> deleteContact(String id) async {
    await _db?.delete('contacts', where: 'id = ?', whereArgs: [id]);
    _contactsNotifier.value = await getContacts();
  }

  Future<List<Contact>> getContacts() async {
    final rows = await _db?.query('contacts', orderBy: 'nick ASC') ?? [];
    return rows.map(Contact.fromMap).toList();
  }

  Future<Contact?> getContact(String id) async {
    final rows = await _db?.query('contacts', where: 'id = ?', whereArgs: [id]);
    if (rows == null || rows.isEmpty) return null;
    return Contact.fromMap(rows.first);
  }

  Future<void> updateContactLastSeen(String id) async {
    await _db?.update(
      'contacts',
      {'last_seen': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateContact(Contact contact) async {
    await _db?.update(
      'contacts',
      {
        'nick': contact.nickname,
        'color': contact.avatarColor,
        'emoji': contact.avatarEmoji,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [contact.publicKeyHex],
    );
    _contactsNotifier.value = await getContacts();
  }

  final _contactsNotifier = ValueNotifier<List<Contact>>([]);
  ValueNotifier<List<Contact>> get contactsNotifier => _contactsNotifier;

  Future<void> loadContacts() async {
    _contactsNotifier.value = await getContacts();
  }

  // ── Сообщения ────────────────────────────────────────────────

  Future<void> saveMessage(ChatMessage message) async {
    await _db?.insert('messages', message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyMessages(message.peerId);
  }

  Future<List<ChatMessage>> getMessages(String peerId,
      {int limit = 100}) async {
    final rows = await _db?.query(
          'messages',
          where: 'peer_id = ?',
          whereArgs: [peerId],
          orderBy: 'timestamp ASC',
          limit: limit,
        ) ??
        [];
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> deleteChat(String peerId) async {
    await _db?.delete('messages', where: 'peer_id = ?', whereArgs: [peerId]);
    _messagesNotifiers.remove(peerId);
  }

  Future<ChatMessage?> getLastMessage(String peerId) async {
    final rows = await _db?.query(
      'messages',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (rows == null || rows.isEmpty) return null;
    return ChatMessage.fromMap(rows.first);
  }

  // ИСПРАВЛЕННЫЙ SQL — GROUP BY вместо DISTINCT с агрегатом
  Future<List<String>> getChatPeerIds() async {
    final rows = await _db?.rawQuery('''
      SELECT peer_id
      FROM messages
      GROUP BY peer_id
      ORDER BY MAX(timestamp) DESC
    ''') ?? [];
    return rows.map((r) => r['peer_id'] as String).toList();
  }

  final Map<String, ValueNotifier<List<ChatMessage>>> _messagesNotifiers = {};

  ValueNotifier<List<ChatMessage>> messagesNotifier(String peerId) {
    return _messagesNotifiers.putIfAbsent(peerId, () => ValueNotifier([]));
  }

  Future<void> loadMessages(String peerId) async {
    final msgs = await getMessages(peerId);
    messagesNotifier(peerId).value = msgs;
  }

  void _notifyMessages(String peerId) async {
    if (_messagesNotifiers.containsKey(peerId)) {
      final msgs = await getMessages(peerId);
      _messagesNotifiers[peerId]!.value = msgs;
    }
  }
}
