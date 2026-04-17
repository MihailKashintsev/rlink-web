import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/group.dart';

class GroupService {
  GroupService._();
  static final GroupService instance = GroupService._();

  final _uuid = const Uuid();
  Database? _db;

  /// Notifies UI when group list changes.
  final version = ValueNotifier<int>(0);

  /// Pending group invites (group_invite packets received).
  final pendingInvites = ValueNotifier<List<GroupInvite>>([]);

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'groups.db');
    _db = await openDatabase(
      path,
      version: 3,
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
            is_outgoing INTEGER DEFAULT 0,
            timestamp INTEGER NOT NULL,
            reactions TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_gm_group ON group_messages(group_id, timestamp)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute("ALTER TABLE groups ADD COLUMN moderators TEXT DEFAULT ''");
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE group_messages ADD COLUMN reactions TEXT');
        }
      },
    );
  }

  // ── Groups CRUD ────────────────────────────────────────────────

  Future<Group> createGroup({
    required String name,
    required String creatorId,
    required List<String> memberIds,
    int avatarColor = 0xFF5C6BC0,
    String avatarEmoji = '👥',
  }) async {
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
    version.value++;
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
              memberIds: (r['members'] as String).split(',').where((s) => s.isNotEmpty).toList(),
              moderatorIds: ((r['moderators'] as String?) ?? '').split(',').where((s) => s.isNotEmpty).toList(),
              avatarColor: r['avatar_color'] as int? ?? 0xFF5C6BC0,
              avatarEmoji: r['avatar_emoji'] as String? ?? '👥',
              avatarImagePath: r['avatar_img_path'] as String?,
              createdAt: r['created_at'] as int,
            ))
        .toList();
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
      memberIds: (r['members'] as String).split(',').where((s) => s.isNotEmpty).toList(),
      moderatorIds: ((r['moderators'] as String?) ?? '').split(',').where((s) => s.isNotEmpty).toList(),
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
    version.value++;
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
    version.value++;
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
    await _db?.delete('groups');
    version.value++;
  }

  Future<void> leaveGroup(String groupId) async {
    await _db!.delete('groups', where: 'id = ?', whereArgs: [groupId]);
    await _db!.delete('group_messages',
        where: 'group_id = ?', whereArgs: [groupId]);
    version.value++;
  }

  // ── Messages ───────────────────────────────────────────────────

  Future<void> saveMessage(GroupMessage msg) async {
    await _db!.insert('group_messages', msg.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    version.value++;
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
    version.value++;
    return GroupMessage(
      id: msg.id,
      groupId: msg.groupId,
      senderId: msg.senderId,
      text: msg.text,
      imagePath: msg.imagePath,
      videoPath: msg.videoPath,
      voicePath: msg.voicePath,
      isOutgoing: msg.isOutgoing,
      timestamp: msg.timestamp,
      reactions: updated,
    );
  }

  Future<GroupMessage?> getLastMessage(String groupId) async {
    final rows = await _db!.query(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GroupMessage.fromMap(rows.first);
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
