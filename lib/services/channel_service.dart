import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/channel.dart';

class ChannelService {
  ChannelService._();
  static final ChannelService instance = ChannelService._();

  final _uuid = const Uuid();
  Database? _db;

  final version = ValueNotifier<int>(0);

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'channels.db');
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE channels (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            admin_id TEXT NOT NULL,
            subscribers TEXT NOT NULL,
            moderators TEXT DEFAULT '',
            avatar_color INTEGER DEFAULT 0xFF42A5F5,
            avatar_emoji TEXT DEFAULT '📢',
            avatar_img_path TEXT,
            description TEXT,
            comments_enabled INTEGER DEFAULT 1,
            created_at INTEGER NOT NULL,
            verified INTEGER DEFAULT 0,
            verified_by TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE channel_posts (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            author_id TEXT NOT NULL,
            text TEXT DEFAULT '',
            image_path TEXT,
            video_path TEXT,
            timestamp INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE channel_comments (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            author_id TEXT NOT NULL,
            text TEXT NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_cp_channel ON channel_posts(channel_id, timestamp)');
        await db.execute(
            'CREATE INDEX idx_cc_post ON channel_comments(post_id, timestamp)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE channels ADD COLUMN verified INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE channels ADD COLUMN verified_by TEXT');
        }
        if (oldVersion < 3) {
          await db.execute("ALTER TABLE channels ADD COLUMN moderators TEXT DEFAULT ''");
        }
      },
    );
  }

  // ── Channels CRUD ──────────────────────────────────────────────

  Future<Channel> createChannel({
    required String name,
    required String adminId,
    String? description,
    int avatarColor = 0xFF42A5F5,
    String avatarEmoji = '📢',
  }) async {
    final channel = Channel(
      id: _uuid.v4(),
      name: name,
      adminId: adminId,
      subscriberIds: [adminId],
      avatarColor: avatarColor,
      avatarEmoji: avatarEmoji,
      description: description,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (_db == null) throw StateError('ChannelService DB not initialized');
    await _db!.insert('channels', {
      'id': channel.id,
      'name': channel.name,
      'admin_id': channel.adminId,
      'subscribers': channel.subscriberIds.join(','),
      'moderators': channel.moderatorIds.join(','),
      'avatar_color': channel.avatarColor,
      'avatar_emoji': channel.avatarEmoji,
      'description': channel.description,
      'comments_enabled': channel.commentsEnabled ? 1 : 0,
      'created_at': channel.createdAt,
    });
    version.value++;
    return channel;
  }

  Future<List<Channel>> getChannels() async {
    if (_db == null) return [];
    final rows = await _db!.query('channels', orderBy: 'created_at DESC');
    return rows.map(_channelFromRow).toList();
  }

  Future<Channel?> getChannel(String id) async {
    if (_db == null) return null;
    final rows = await _db!.query('channels', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _channelFromRow(rows.first);
  }

  Channel _channelFromRow(Map<String, dynamic> r) => Channel(
        id: r['id'] as String,
        name: r['name'] as String,
        adminId: r['admin_id'] as String,
        subscriberIds: (r['subscribers'] as String).split(',').where((s) => s.isNotEmpty).toList(),
        moderatorIds: ((r['moderators'] as String?) ?? '').split(',').where((s) => s.isNotEmpty).toList(),
        avatarColor: r['avatar_color'] as int? ?? 0xFF42A5F5,
        avatarEmoji: r['avatar_emoji'] as String? ?? '📢',
        avatarImagePath: r['avatar_img_path'] as String?,
        description: r['description'] as String?,
        commentsEnabled: (r['comments_enabled'] as int?) == 1,
        createdAt: r['created_at'] as int,
        verified: (r['verified'] as int?) == 1,
        verifiedBy: r['verified_by'] as String?,
      );

  Future<void> updateChannel(Channel ch) async {
    await _db!.update(
      'channels',
      {
        'name': ch.name,
        'subscribers': ch.subscriberIds.join(','),
        'moderators': ch.moderatorIds.join(','),
        'avatar_color': ch.avatarColor,
        'avatar_emoji': ch.avatarEmoji,
        'avatar_img_path': ch.avatarImagePath,
        'description': ch.description,
        'comments_enabled': ch.commentsEnabled ? 1 : 0,
        'verified': ch.verified ? 1 : 0,
        'verified_by': ch.verifiedBy,
      },
      where: 'id = ?',
      whereArgs: [ch.id],
    );
    version.value++;
  }

  /// Promote or demote [userId] as moderator of [channelId].
  Future<Channel?> setModerator(String channelId, String userId, bool isMod) async {
    final ch = await getChannel(channelId);
    if (ch == null) return null;
    final mods = List<String>.from(ch.moderatorIds);
    if (isMod) {
      if (!mods.contains(userId)) mods.add(userId);
    } else {
      mods.remove(userId);
    }
    final updated = ch.copyWith(moderatorIds: mods);
    await updateChannel(updated);
    return updated;
  }

  Future<void> saveChannelFromBroadcast(Channel ch) async {
    final existing = await getChannel(ch.id);
    if (existing != null) {
      // update subscriber list etc
      await updateChannel(ch);
      return;
    }
    await _db!.insert('channels', {
      'id': ch.id,
      'name': ch.name,
      'admin_id': ch.adminId,
      'subscribers': ch.subscriberIds.join(','),
      'moderators': ch.moderatorIds.join(','),
      'avatar_color': ch.avatarColor,
      'avatar_emoji': ch.avatarEmoji,
      'description': ch.description,
      'comments_enabled': ch.commentsEnabled ? 1 : 0,
      'created_at': ch.createdAt,
      'verified': ch.verified ? 1 : 0,
      'verified_by': ch.verifiedBy,
    });
    version.value++;
  }

  Future<void> subscribe(String channelId, String userId) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    if (ch.subscriberIds.contains(userId)) return;
    await updateChannel(
        ch.copyWith(subscriberIds: [...ch.subscriberIds, userId]));
  }

  Future<void> unsubscribe(String channelId, String userId) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(
        subscriberIds: ch.subscriberIds.where((s) => s != userId).toList()));
  }

  Future<void> deleteChannel(String channelId) async {
    await _db!.delete('channels', where: 'id = ?', whereArgs: [channelId]);
    await _db!.delete('channel_posts',
        where: 'channel_id = ?', whereArgs: [channelId]);
    // delete all comments for posts in this channel
    final posts = await _db!.query('channel_posts',
        columns: ['id'], where: 'channel_id = ?', whereArgs: [channelId]);
    for (final post in posts) {
      await _db!.delete('channel_comments',
          where: 'post_id = ?', whereArgs: [post['id']]);
    }
    version.value++;
  }

  // ── Verification ─────────────────────────────────────────────

  Future<void> verifyChannel(String channelId, String verifiedBy) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(verified: true, verifiedBy: verifiedBy));
  }

  /// Авто-верификация: возвращает true, если у канала 10+ подписчиков.
  bool checkAutoVerify(Channel ch) {
    return ch.subscriberIds.length >= 10;
  }

  // ── Posts ──────────────────────────────────────────────────────

  Future<void> savePost(ChannelPost post) async {
    await _db!.insert('channel_posts', post.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    version.value++;
  }

  Future<List<ChannelPost>> getPosts(String channelId,
      {int limit = 30, int offset = 0}) async {
    final rows = await _db!.query(
      'channel_posts',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    final posts = <ChannelPost>[];
    for (final r in rows) {
      final comments = await getComments(r['id'] as String);
      posts.add(ChannelPost.fromMap(r, comments: comments));
    }
    return posts.reversed.toList();
  }

  Future<ChannelPost?> getLastPost(String channelId) async {
    if (_db == null) return null;
    final rows = await _db!.query(
      'channel_posts',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChannelPost.fromMap(rows.first);
  }

  Future<void> deletePost(String postId) async {
    await _db!.delete('channel_posts', where: 'id = ?', whereArgs: [postId]);
    await _db!.delete('channel_comments',
        where: 'post_id = ?', whereArgs: [postId]);
    version.value++;
  }

  // ── Comments ──────────────────────────────────────────────────

  Future<void> saveComment(ChannelComment comment) async {
    await _db!.insert('channel_comments', comment.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    version.value++;
  }

  Future<List<ChannelComment>> getComments(String postId) async {
    final rows = await _db!.query(
      'channel_comments',
      where: 'post_id = ?',
      whereArgs: [postId],
      orderBy: 'timestamp ASC',
    );
    return rows.map((r) => ChannelComment.fromMap(r)).toList();
  }

  /// Remove a subscriber (kick). Used by admin/moderator.
  Future<void> removeSubscriber(String channelId, String userId) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    final subs = ch.subscriberIds.where((s) => s != userId).toList();
    final mods = ch.moderatorIds.where((m) => m != userId).toList();
    await updateChannel(ch.copyWith(subscriberIds: subs, moderatorIds: mods));
  }

  /// Wipe all local data (used on full app reset).
  Future<void> resetAll() async {
    await _db?.delete('channel_comments');
    await _db?.delete('channel_posts');
    await _db?.delete('channels');
    version.value++;
  }

  String newId() => _uuid.v4();

  // ── Channel Invites (in-memory) ─────────────────────────────────

  final pendingChannelInvites = ValueNotifier<List<ChannelInvite>>([]);

  void addChannelInvite(ChannelInvite invite) {
    final list = List<ChannelInvite>.from(pendingChannelInvites.value);
    if (list.any((i) => i.channelId == invite.channelId)) return;
    list.add(invite);
    pendingChannelInvites.value = list;
  }

  void removeChannelInvite(String channelId) {
    final list = List<ChannelInvite>.from(pendingChannelInvites.value);
    list.removeWhere((i) => i.channelId == channelId);
    pendingChannelInvites.value = list;
  }
}

/// Приглашение в канал (не сохраняется в БД, живёт в памяти).
class ChannelInvite {
  final String channelId;
  final String channelName;
  final String adminId;
  final String inviterId;
  final String inviterNick;
  final int avatarColor;
  final String avatarEmoji;
  final String? description;
  final int createdAt;

  const ChannelInvite({
    required this.channelId,
    required this.channelName,
    required this.adminId,
    required this.inviterId,
    required this.inviterNick,
    this.avatarColor = 0xFF42A5F5,
    this.avatarEmoji = '📢',
    this.description,
    required this.createdAt,
  });
}
