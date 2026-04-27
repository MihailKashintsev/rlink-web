import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/group.dart';
import '../models/message_poll.dart';
import '../utils/reaction_limit.dart';
import 'image_service.dart';
import 'web_identity_portable.dart';

Future<void> _backfillGroupReadCursors(Database db) async {
  final groups =
      await db.rawQuery('SELECT DISTINCT group_id FROM group_messages');
  for (final r in groups) {
    final gid = r['group_id'] as String;
    final rows = await db.rawQuery(
      'SELECT id, timestamp FROM group_messages WHERE group_id = ? '
      'ORDER BY timestamp DESC, id DESC LIMIT 1',
      [gid],
    );
    if (rows.isEmpty) continue;
    await db.insert(
      'group_read_cursor',
      {
        'group_id': gid,
        'last_read_ts': rows.first['timestamp'] as int,
        'last_read_id': rows.first['id'] as String,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

Future<void> _tryDeleteGroupMediaFile(String? path) async {
  if (path == null || path.isEmpty) return;
  final resolved = ImageService.instance.resolveStoredPath(path) ?? path;
  try {
    final f = File(resolved);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

class GroupService {
  GroupService._();
  static final GroupService instance = GroupService._();

  final _uuid = const Uuid();
  Database? _db;

  Future<String> _dbPath(String fileName) async {
    if (kIsWeb) return fileName;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, fileName);
  }

  /// Notifies UI when group list changes.
  final version = ValueNotifier<int>(0);

  /// Pending group invites (group_invite packets received).
  final pendingInvites = ValueNotifier<List<GroupInvite>>([]);

  // Coalesce many rapid mutations (history sync, reactions) into
  // a single notification per microtask.
  bool _bumpScheduled = false;
  void _bump() {
    if (_bumpScheduled) return;
    _bumpScheduled = true;
    scheduleMicrotask(() {
      _bumpScheduled = false;
      version.value++;
    });
  }

  Future<void> init() async {
    final path = await _dbPath('groups.db');
    _db = await openDatabase(
      path,
      version: 7,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE groups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            creator_id TEXT NOT NULL,
            members TEXT NOT NULL,
            moderators TEXT DEFAULT '',
            avatar_color INTEGER DEFAULT 0xFF5C6BC0,
            avatar_emoji TEXT DEFAULT '👥',
            avatar_img_path TEXT,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE group_messages (
            id TEXT PRIMARY KEY,
            group_id TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            text TEXT DEFAULT '',
            image_path TEXT,
            video_path TEXT,
            voice_path TEXT,
            latitude REAL,
            longitude REAL,
            is_outgoing INTEGER DEFAULT 0,
            timestamp INTEGER NOT NULL,
            reactions TEXT,
            poll_json TEXT,
            forward_from_id TEXT,
            forward_from_nick TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_gm_group ON group_messages(group_id, timestamp)');
        await db.execute('''
          CREATE TABLE group_read_cursor (
            group_id     TEXT PRIMARY KEY,
            last_read_ts INTEGER NOT NULL,
            last_read_id TEXT NOT NULL DEFAULT ''
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              "ALTER TABLE groups ADD COLUMN moderators TEXT DEFAULT ''");
        }
        if (oldVersion < 3) {
          await db
              .execute('ALTER TABLE group_messages ADD COLUMN reactions TEXT');
        }
        if (oldVersion < 4) {
          await db
              .execute('ALTER TABLE group_messages ADD COLUMN poll_json TEXT');
        }
        if (oldVersion < 5) {
          try {
            await db.execute(
                'ALTER TABLE group_messages ADD COLUMN forward_from_id TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE group_messages ADD COLUMN forward_from_nick TEXT');
          } catch (_) {}
        }
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS group_read_cursor (
              group_id     TEXT PRIMARY KEY,
              last_read_ts INTEGER NOT NULL,
              last_read_id TEXT NOT NULL DEFAULT ''
            )
          ''');
          await _backfillGroupReadCursors(db);
        }
        if (oldVersion < 7) {
          try {
            await db
                .execute('ALTER TABLE group_messages ADD COLUMN latitude REAL');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE group_messages ADD COLUMN longitude REAL');
          } catch (_) {}
        }
      },
    );
  }

  Future<void> _ensureDbReady() async {
    if (_db != null) return;
    await init();
  }

  // ── Groups CRUD ────────────────────────────────────────────────

  Future<Group> createGroup({
    required String name,
    required String creatorId,
    required List<String> memberIds,
    int avatarColor = 0xFF5C6BC0,
    String avatarEmoji = '👥',
  }) async {
    await _ensureDbReady();
    final group = Group(
      id: _uuid.v4(),
      name: name,
      creatorId: creatorId,
      memberIds: memberIds,
      avatarColor: avatarColor,
      avatarEmoji: avatarEmoji,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (_db == null) throw StateError('GroupService DB not initialized');
    await _db!.insert('groups', {
      'id': group.id,
      'name': group.name,
      'creator_id': group.creatorId,
      'members': group.memberIds.join(','),
      'moderators': group.moderatorIds.join(','),
      'avatar_color': group.avatarColor,
      'avatar_emoji': group.avatarEmoji,
      'created_at': group.createdAt,
    });
    _bump();
    if (kIsWeb) {
      unawaited(WebIdentityPortable.exportIdentityKeyDownload());
    }
    return group;
  }

  Future<List<Group>> getGroups() async {
    if (_db == null) return [];
    final rows = await _db!.query('groups', orderBy: 'created_at DESC');
    return rows
        .map((r) => Group(
              id: r['id'] as String,
              name: r['name'] as String,
              creatorId: r['creator_id'] as String,
              memberIds: (r['members'] as String)
                  .split(',')
                  .where((s) => s.isNotEmpty)
                  .toList(),
              moderatorIds: ((r['moderators'] as String?) ?? '')
                  .split(',')
                  .where((s) => s.isNotEmpty)
                  .toList(),
              avatarColor: r['avatar_color'] as int? ?? 0xFF5C6BC0,
              avatarEmoji: r['avatar_emoji'] as String? ?? '👥',
              avatarImagePath: r['avatar_img_path'] as String?,
              createdAt: r['created_at'] as int,
            ))
        .toList();
  }

  Future<void> upsertGroupsFromBackup(List<Group> groups) async {
    await _ensureDbReady();
    if (_db == null) return;
    await _db!.transaction((txn) async {
      for (final g in groups) {
        await txn.insert(
          'groups',
          {
            'id': g.id,
            'name': g.name,
            'creator_id': g.creatorId,
            'members': g.memberIds.join(','),
            'moderators': g.moderatorIds.join(','),
            'avatar_color': g.avatarColor,
            'avatar_emoji': g.avatarEmoji,
            'avatar_img_path': g.avatarImagePath,
            'created_at': g.createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _bump();
  }

  Future<Map<String, dynamic>> exportBackupSnapshot() async {
    await _ensureDbReady();
    if (_db == null) return const {'v': 1};
    final groups = await _db!.query('groups');
    final messages = await _db!.query('group_messages');
    final cursors = await _db!.query('group_read_cursor');
    return {
      'v': 1,
      'groups': groups.map((r) => Map<String, dynamic>.from(r)).toList(),
      'messages': messages.map((r) => Map<String, dynamic>.from(r)).toList(),
      'cursors': cursors.map((r) => Map<String, dynamic>.from(r)).toList(),
    };
  }

  Future<void> importBackupSnapshot(Map<String, dynamic> snapshot) async {
    await _ensureDbReady();
    if (_db == null) return;
    final groups = (snapshot['groups'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final messages = (snapshot['messages'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final cursors = (snapshot['cursors'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    await _db!.transaction((txn) async {
      for (final row in groups) {
        await txn.insert(
          'groups',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in messages) {
        await txn.insert(
          'group_messages',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in cursors) {
        await txn.insert(
          'group_read_cursor',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _bump();
  }

  Future<List<String>> getGroupIds() async {
    final g = await getGroups();
    return g.map((e) => e.id).toList();
  }

  Future<Group?> getGroup(String id) async {
    if (_db == null) return null;
    final rows = await _db!.query('groups', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Group(
      id: r['id'] as String,
      name: r['name'] as String,
      creatorId: r['creator_id'] as String,
      memberIds: (r['members'] as String)
          .split(',')
          .where((s) => s.isNotEmpty)
          .toList(),
      moderatorIds: ((r['moderators'] as String?) ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toList(),
      avatarColor: r['avatar_color'] as int? ?? 0xFF5C6BC0,
      avatarEmoji: r['avatar_emoji'] as String? ?? '👥',
      avatarImagePath: r['avatar_img_path'] as String?,
      createdAt: r['created_at'] as int,
    );
  }

  Future<void> updateGroup(Group group) async {
    await _db!.update(
      'groups',
      {
        'name': group.name,
        'members': group.memberIds.join(','),
        'moderators': group.moderatorIds.join(','),
        'avatar_color': group.avatarColor,
        'avatar_emoji': group.avatarEmoji,
        'avatar_img_path': group.avatarImagePath,
      },
      where: 'id = ?',
      whereArgs: [group.id],
    );
    _bump();
    if (kIsWeb) {
      unawaited(WebIdentityPortable.exportIdentityKeyDownload());
    }
  }

  /// Promote or demote [userId] as moderator of [groupId].
  Future<Group?> setModerator(String groupId, String userId, bool isMod) async {
    final group = await getGroup(groupId);
    if (group == null) return null;
    final mods = List<String>.from(group.moderatorIds);
    if (isMod) {
      if (!mods.contains(userId)) mods.add(userId);
    } else {
      mods.remove(userId);
    }
    final updated = group.copyWith(moderatorIds: mods);
    await updateGroup(updated);
    return updated;
  }

  Future<void> addMember(String groupId, String memberId) async {
    final group = await getGroup(groupId);
    if (group == null) return;
    if (group.memberIds.contains(memberId)) return;
    final updated = group.copyWith(memberIds: [...group.memberIds, memberId]);
    await updateGroup(updated);
  }

  Future<void> saveGroupFromInvite(Group group) async {
    final existing = await getGroup(group.id);
    if (existing != null) return; // already joined
    await _db!.insert('groups', {
      'id': group.id,
      'name': group.name,
      'creator_id': group.creatorId,
      'members': group.memberIds.join(','),
      'moderators': group.moderatorIds.join(','),
      'avatar_color': group.avatarColor,
      'avatar_emoji': group.avatarEmoji,
      'created_at': group.createdAt,
    });
    _bump();
  }

  /// Remove a member (kick). Used by creator/moderator.
  Future<void> removeMember(String groupId, String userId) async {
    final group = await getGroup(groupId);
    if (group == null) return;
    final members = group.memberIds.where((m) => m != userId).toList();
    final mods = group.moderatorIds.where((m) => m != userId).toList();
    await updateGroup(group.copyWith(memberIds: members, moderatorIds: mods));
  }

  /// Wipe all local data (used on full app reset).
  Future<void> resetAll() async {
    await _db?.delete('group_messages');
    await _db?.delete('group_read_cursor');
    await _db?.delete('groups');
    _bump();
  }

  /// Только сообщения; группы и состав участников сохраняются.
  Future<void> deleteAllGroupMessages() async {
    if (_db == null) return;
    await _db!.delete('group_messages');
    await _db!.delete('group_read_cursor');
    _bump();
  }

  /// Очистка сообщений в выбранных группах (полностью или только медиа).
  Future<void> clearGroupMessages({
    required Set<String> groupIds,
    required bool mediaOnly,
  }) async {
    if (_db == null || groupIds.isEmpty) return;
    for (final gid in groupIds) {
      if (mediaOnly) {
        final rows = await _db!.query(
          'group_messages',
          columns: ['image_path', 'video_path', 'voice_path'],
          where: 'group_id = ?',
          whereArgs: [gid],
        );
        for (final r in rows) {
          await _tryDeleteGroupMediaFile(r['image_path'] as String?);
          await _tryDeleteGroupMediaFile(r['video_path'] as String?);
          await _tryDeleteGroupMediaFile(r['voice_path'] as String?);
        }
        await _db!.rawUpdate(
          'UPDATE group_messages SET image_path=NULL, video_path=NULL, '
          'voice_path=NULL WHERE group_id=?',
          [gid],
        );
      } else {
        await _db!
            .delete('group_messages', where: 'group_id = ?', whereArgs: [gid]);
        await _db!.delete('group_read_cursor',
            where: 'group_id = ?', whereArgs: [gid]);
      }
    }
    _bump();
  }

  Future<void> leaveGroup(String groupId) async {
    await _db!.delete('groups', where: 'id = ?', whereArgs: [groupId]);
    await _db!
        .delete('group_messages', where: 'group_id = ?', whereArgs: [groupId]);
    await _db!.delete('group_read_cursor',
        where: 'group_id = ?', whereArgs: [groupId]);
    _bump();
  }

  // ── Messages ───────────────────────────────────────────────────

  Future<void> saveMessage(GroupMessage msg) async {
    await _db!.insert('group_messages', msg.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _bump();
  }

  Future<List<GroupMessage>> getMessages(String groupId,
      {int limit = 50, int offset = 0}) async {
    final rows = await _db!.query(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return rows.reversed.map((r) => GroupMessage.fromMap(r)).toList();
  }

  Future<GroupMessage?> getMessage(String messageId) async {
    if (_db == null) return null;
    final rows = await _db!
        .query('group_messages', where: 'id = ?', whereArgs: [messageId]);
    if (rows.isEmpty) return null;
    return GroupMessage.fromMap(rows.first);
  }

  /// Toggle [emoji] reaction from [reactorId] on [messageId].
  /// Returns the updated message (or null if not found).
  Future<GroupMessage?> toggleMessageReaction(
      String messageId, String emoji, String reactorId) async {
    if (_db == null) return null;
    final msg = await getMessage(messageId);
    if (msg == null) return null;
    final updated = Map<String, List<String>>.from(
      msg.reactions.map((k, v) => MapEntry(k, List<String>.from(v))),
    );
    final list = List<String>.from(updated[emoji] ?? const <String>[]);
    if (list.contains(reactorId)) {
      list.remove(reactorId);
    } else {
      if (!reactionAddAllowed(updated, emoji, reactorId)) return null;
      list.add(reactorId);
    }
    if (list.isEmpty) {
      updated.remove(emoji);
    } else {
      updated[emoji] = list;
    }
    await _db!.update(
      'group_messages',
      {'reactions': updated.isEmpty ? null : jsonEncode(updated)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _bump();
    return GroupMessage(
      id: msg.id,
      groupId: msg.groupId,
      senderId: msg.senderId,
      text: msg.text,
      imagePath: msg.imagePath,
      videoPath: msg.videoPath,
      voicePath: msg.voicePath,
      latitude: msg.latitude,
      longitude: msg.longitude,
      isOutgoing: msg.isOutgoing,
      timestamp: msg.timestamp,
      reactions: updated,
      pollJson: msg.pollJson,
      forwardFromId: msg.forwardFromId,
      forwardFromNick: msg.forwardFromNick,
    );
  }

  Future<void> updateMessagePollJson(String messageId, String? pollJson) async {
    if (_db == null) return;
    await _db!.update(
      'group_messages',
      {'poll_json': pollJson},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _bump();
  }

  Future<void> updateMessageText(String messageId, String newText) async {
    if (_db == null) return;
    await _db!.update(
      'group_messages',
      {'text': newText},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _bump();
  }

  /// После сборки img_chunk для входящего группового сообщения с видео.
  Future<void> applyAssembledVideo(String messageId, String videoPath) async {
    if (_db == null) return;
    await _db!.update(
      'group_messages',
      {'video_path': videoPath},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _bump();
  }

  /// После сборки img_chunk для входящего группового сообщения с фото.
  Future<void> applyAssembledImage(String messageId, String imagePath) async {
    if (_db == null) return;
    await _db!.update(
      'group_messages',
      {'image_path': imagePath},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _bump();
  }

  Future<void> mergeIncomingMessagePoll(
      String messageId, String? incomingPj) async {
    if (incomingPj == null || incomingPj.isEmpty) return;
    final inc = MessagePoll.tryDecode(incomingPj);
    if (inc == null) return;
    final msg = await getMessage(messageId);
    if (msg == null) return;
    final cur = MessagePoll.tryDecode(msg.pollJson);
    final merged = (cur ?? inc).mergeVotesFrom(inc);
    await updateMessagePollJson(messageId, merged.encode());
  }

  Future<void> applyPollVote(
      String messageId, String voterId, List<int> choices) async {
    final msg = await getMessage(messageId);
    if (msg == null) return;
    final poll = MessagePoll.tryDecode(msg.pollJson);
    if (poll == null) return;
    final next = poll.withVote(voterId, choices);
    await updateMessagePollJson(messageId, next.encode());
  }

  Future<GroupMessage?> getLastMessage(String groupId) async {
    final rows = await _db!.query(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'timestamp DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GroupMessage.fromMap(rows.first);
  }

  /// Unread counts for groups (incoming / others' messages after read cursor).
  Future<Map<String, int>> getGroupUnreadCounts() async {
    if (_db == null) return const {};
    final rows = await _db!.rawQuery('''
      SELECT gm.group_id AS gid, COUNT(*) AS c
      FROM group_messages gm
      LEFT JOIN group_read_cursor gr ON gr.group_id = gm.group_id
      WHERE gm.is_outgoing = 0
      AND (
        gr.group_id IS NULL
        OR gm.timestamp > gr.last_read_ts
        OR (gm.timestamp = gr.last_read_ts AND gm.id > gr.last_read_id)
      )
      GROUP BY gm.group_id
    ''');
    return {for (final r in rows) r['gid'] as String: (r['c'] as int?) ?? 0};
  }

  Future<void> markGroupRead(String groupId) async {
    if (_db == null) return;
    final rows = await _db!.query(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'timestamp DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      await _db!.delete(
        'group_read_cursor',
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
    } else {
      final m = GroupMessage.fromMap(rows.first);
      await _db!.insert(
        'group_read_cursor',
        {
          'group_id': groupId,
          'last_read_ts': m.timestamp,
          'last_read_id': m.id,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    _bump();
  }

  // ── Invites ────────────────────────────────────────────────────

  void addInvite(GroupInvite invite) {
    final list = List<GroupInvite>.from(pendingInvites.value);
    // Avoid duplicates
    if (list.any((i) => i.groupId == invite.groupId)) return;
    list.add(invite);
    pendingInvites.value = list;
  }

  void removeInvite(String groupId) {
    final list = List<GroupInvite>.from(pendingInvites.value);
    list.removeWhere((i) => i.groupId == groupId);
    pendingInvites.value = list;
  }
}

/// Приглашение в группу (не сохраняется в БД, живёт в памяти).
class GroupInvite {
  final String groupId;
  final String groupName;
  final String inviterId; // кто пригласил
  final String inviterNick;
  final String creatorId;
  final List<String> memberIds;
  final int avatarColor;
  final String avatarEmoji;
  final int createdAt;

  const GroupInvite({
    required this.groupId,
    required this.groupName,
    required this.inviterId,
    required this.inviterNick,
    required this.creatorId,
    required this.memberIds,
    this.avatarColor = 0xFF5C6BC0,
    this.avatarEmoji = '👥',
    required this.createdAt,
  });
}
