import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/channel.dart';
import '../models/message_poll.dart';
import 'gossip_router.dart';
import 'image_service.dart';

Future<void> _backfillChannelReadCursors(Database db) async {
  final chans =
      await db.rawQuery('SELECT DISTINCT channel_id FROM channel_posts');
  for (final r in chans) {
    final cid = r['channel_id'] as String;
    final rows = await db.rawQuery(
      'SELECT id, timestamp FROM channel_posts WHERE channel_id = ? '
      'ORDER BY timestamp DESC, id DESC LIMIT 1',
      [cid],
    );
    if (rows.isEmpty) continue;
    await db.insert(
      'channel_read_cursor',
      {
        'channel_id': cid,
        'last_read_ts': rows.first['timestamp'] as int,
        'last_read_id': rows.first['id'] as String,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

class ChannelService {
  ChannelService._();
  static final ChannelService instance = ChannelService._();

  final _uuid = const Uuid();
  Database? _db;

  /// Медиа пришло по img_chunk до пакета channel_post — временно кладём путь сюда.
  final Map<String, String> _pendingPostImagePaths = {};
  final Map<String, String> _pendingPostVideoPaths = {};
  final Map<String, String> _pendingPostVoicePaths = {};
  final Map<String, String> _pendingPostFilePaths = {};
  final Map<String, String> _pendingPostFileNames = {};
  final Map<String, int> _pendingPostFileSizes = {};
  final Map<String, String> _pendingCommentImagePaths = {};
  final Map<String, String> _pendingCommentVideoPaths = {};
  final Map<String, String> _pendingCommentVoicePaths = {};
  final Map<String, String> _pendingCommentFilePaths = {};
  final Map<String, String> _pendingCommentFileNames = {};
  final Map<String, int> _pendingCommentFileSizes = {};

  final version = ValueNotifier<int>(0);

  // Coalesce many rapid mutations (e.g. bulk history sync) into
  // a single notification per microtask, saving iOS redraws.
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
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'channels.db');
    _db = await openDatabase(
      path,
      version: 11,
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
            banner_img_path TEXT,
            description TEXT,
            comments_enabled INTEGER DEFAULT 1,
            created_at INTEGER NOT NULL,
            verified INTEGER DEFAULT 0,
            verified_by TEXT,
            foreign_agent INTEGER DEFAULT 0,
            blocked INTEGER DEFAULT 0,
            username TEXT DEFAULT '',
            universal_code TEXT DEFAULT '',
            is_public INTEGER DEFAULT 1
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
            voice_path TEXT,
            file_path TEXT,
            file_name TEXT,
            file_size INTEGER,
            timestamp INTEGER NOT NULL,
            reactions TEXT,
            poll_json TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE channel_comments (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            author_id TEXT NOT NULL,
            text TEXT NOT NULL,
            image_path TEXT,
            video_path TEXT,
            voice_path TEXT,
            file_path TEXT,
            file_name TEXT,
            file_size INTEGER,
            timestamp INTEGER NOT NULL,
            reactions TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE verification_requests (
            channel_id TEXT PRIMARY KEY,
            channel_name TEXT NOT NULL,
            admin_id TEXT NOT NULL,
            subscriber_count INTEGER DEFAULT 0,
            avatar_emoji TEXT DEFAULT '📢',
            description TEXT,
            requested_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_cp_channel ON channel_posts(channel_id, timestamp)');
        await db.execute(
            'CREATE INDEX idx_cc_post ON channel_comments(post_id, timestamp)');
        await db.execute('''
          CREATE TABLE channel_read_cursor (
            channel_id   TEXT PRIMARY KEY,
            last_read_ts INTEGER NOT NULL,
            last_read_id TEXT NOT NULL DEFAULT ''
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE channels ADD COLUMN verified INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE channels ADD COLUMN verified_by TEXT');
        }
        if (oldVersion < 3) {
          await db.execute("ALTER TABLE channels ADD COLUMN moderators TEXT DEFAULT ''");
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS verification_requests (
              channel_id TEXT PRIMARY KEY,
              channel_name TEXT NOT NULL,
              admin_id TEXT NOT NULL,
              subscriber_count INTEGER DEFAULT 0,
              avatar_emoji TEXT DEFAULT '📢',
              description TEXT,
              requested_at INTEGER NOT NULL
            )
          ''');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE channels ADD COLUMN foreign_agent INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE channels ADD COLUMN blocked INTEGER DEFAULT 0');
        }
        if (oldVersion < 6) {
          await db.execute("ALTER TABLE channels ADD COLUMN username TEXT DEFAULT ''");
          await db.execute("ALTER TABLE channels ADD COLUMN universal_code TEXT DEFAULT ''");
          await db.execute('ALTER TABLE channels ADD COLUMN is_public INTEGER DEFAULT 1');
        }
        if (oldVersion < 7) {
          try {
            await db.execute('ALTER TABLE channel_posts ADD COLUMN reactions TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN reactions TEXT');
          } catch (_) {}
        }
        if (oldVersion < 8) {
          try {
            await db.execute('ALTER TABLE channel_posts ADD COLUMN poll_json TEXT');
          } catch (_) {}
        }
        if (oldVersion < 9) {
          try {
            await db.execute('ALTER TABLE channels ADD COLUMN banner_img_path TEXT');
          } catch (_) {}
        }
        if (oldVersion < 10) {
          try {
            await db.execute('ALTER TABLE channel_posts ADD COLUMN voice_path TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_posts ADD COLUMN file_path TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_posts ADD COLUMN file_name TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_posts ADD COLUMN file_size INTEGER');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN image_path TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN video_path TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN voice_path TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN file_path TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN file_name TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE channel_comments ADD COLUMN file_size INTEGER');
          } catch (_) {}
        }
        if (oldVersion < 11) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS channel_read_cursor (
              channel_id   TEXT PRIMARY KEY,
              last_read_ts INTEGER NOT NULL,
              last_read_id TEXT NOT NULL DEFAULT ''
            )
          ''');
          await _backfillChannelReadCursors(db);
        }
      },
    );
  }

  static String compactChannelId(String channelId) =>
      channelId.replaceAll('-', '');

  /// msgId для рассылки картинки аватара канала (подписчики собирают img_chunk).
  static String channelAvatarBroadcastMsgId(String channelId) =>
      'chav_${compactChannelId(channelId)}';

  static String channelBannerBroadcastMsgId(String channelId) =>
      'chbn_${compactChannelId(channelId)}';

  // ── Channels CRUD ──────────────────────────────────────────────

  Future<Channel> createChannel({
    required String name,
    required String adminId,
    String? description,
    int avatarColor = 0xFF42A5F5,
    String avatarEmoji = '📢',
    String username = '',
    bool isPublic = true,
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
      username: username,
      universalCode: _generateUniversalCode(),
      isPublic: isPublic,
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
      'avatar_img_path': channel.avatarImagePath,
      'banner_img_path': channel.bannerImagePath,
      'description': channel.description,
      'comments_enabled': channel.commentsEnabled ? 1 : 0,
      'created_at': channel.createdAt,
      'username': channel.username,
      'universal_code': channel.universalCode,
      'is_public': channel.isPublic ? 1 : 0,
    });
    _bump();
    return channel;
  }

  /// Универсальный код канала: короткий публичный идентификатор.
  /// Используется для поиска аналогично публичному ключу у пользователей.
  String _generateUniversalCode() {
    // 12 алфавитно-цифровых символов на базе uuid v4 (без дефисов, в верхнем регистре).
    final raw = _uuid.v4().replaceAll('-', '').toUpperCase();
    return raw.substring(0, 12);
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

  Future<List<String>> getChannelIds() async {
    if (_db == null) return [];
    final rows = await _db!.query('channels', columns: ['id']);
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Посты и комментарии выбранных каналов: полное удаление или только медиа.
  Future<void> clearChannelPostsAndComments({
    required Set<String> channelIds,
    required bool mediaOnly,
  }) async {
    if (_db == null || channelIds.isEmpty) return;
    for (final cid in channelIds) {
      if (mediaOnly) {
        final posts = await _db!.query(
          'channel_posts',
          columns: [
            'id',
            'image_path',
            'video_path',
            'voice_path',
            'file_path',
          ],
          where: 'channel_id = ?',
          whereArgs: [cid],
        );
        for (final r in posts) {
          await _tryDeleteChannelMediaFile(r['image_path'] as String?);
          await _tryDeleteChannelMediaFile(r['video_path'] as String?);
          await _tryDeleteChannelMediaFile(r['voice_path'] as String?);
          await _tryDeleteChannelMediaFile(r['file_path'] as String?);
        }
        await _db!.rawUpdate(
          'UPDATE channel_posts SET image_path=NULL, video_path=NULL, '
          'voice_path=NULL, file_path=NULL, file_name=NULL, file_size=NULL '
          'WHERE channel_id=?',
          [cid],
        );
        final comments = await _db!.rawQuery(
          'SELECT id, image_path, video_path, voice_path, file_path '
          'FROM channel_comments WHERE post_id IN '
          '(SELECT id FROM channel_posts WHERE channel_id = ?)',
          [cid],
        );
        for (final r in comments) {
          await _tryDeleteChannelMediaFile(r['image_path'] as String?);
          await _tryDeleteChannelMediaFile(r['video_path'] as String?);
          await _tryDeleteChannelMediaFile(r['voice_path'] as String?);
          await _tryDeleteChannelMediaFile(r['file_path'] as String?);
        }
        await _db!.rawUpdate(
          'UPDATE channel_comments SET image_path=NULL, video_path=NULL, '
          'voice_path=NULL, file_path=NULL, file_name=NULL, file_size=NULL '
          'WHERE post_id IN (SELECT id FROM channel_posts WHERE channel_id = ?)',
          [cid],
        );
      } else {
        await _db!.delete(
          'channel_comments',
          where: 'post_id IN (SELECT id FROM channel_posts WHERE channel_id = ?)',
          whereArgs: [cid],
        );
        await _db!.delete('channel_posts',
            where: 'channel_id = ?', whereArgs: [cid]);
      }
    }
    _bump();
  }

  Future<void> _tryDeleteChannelMediaFile(String? path) async {
    if (path == null || path.isEmpty) return;
    final resolved = ImageService.instance.resolveStoredPath(path) ?? path;
    try {
      final f = File(resolved);
      if (await f.exists()) await f.delete();
    } catch (_) {}
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
        bannerImagePath: r['banner_img_path'] as String?,
        description: r['description'] as String?,
        commentsEnabled: (r['comments_enabled'] as int?) == 1,
        createdAt: r['created_at'] as int,
        verified: (r['verified'] as int?) == 1,
        verifiedBy: r['verified_by'] as String?,
        foreignAgent: (r['foreign_agent'] as int?) == 1,
        blocked: (r['blocked'] as int?) == 1,
        username: (r['username'] as String?) ?? '',
        universalCode: (r['universal_code'] as String?) ?? '',
        isPublic: (r['is_public'] as int?) != 0,
      );

  Future<void> updateChannel(Channel ch) async {
    final existing = await getChannel(ch.id);
    await _db!.update(
      'channels',
      {
        'name': ch.name,
        'subscribers': ch.subscriberIds.join(','),
        'moderators': ch.moderatorIds.join(','),
        'avatar_color': ch.avatarColor,
        'avatar_emoji': ch.avatarEmoji,
        'avatar_img_path': ch.avatarImagePath,
        'banner_img_path': ch.bannerImagePath,
        'description': ch.description,
        'comments_enabled': ch.commentsEnabled ? 1 : 0,
        'verified': ch.verified ? 1 : 0,
        'verified_by': ch.verifiedBy,
        'foreign_agent': ch.foreignAgent ? 1 : 0,
        'blocked': ch.blocked ? 1 : 0,
        'username': ch.username,
        'universal_code': ch.universalCode,
        'is_public': ch.isPublic ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [ch.id],
    );
    if (existing != null) {
      if (existing.avatarImagePath != ch.avatarImagePath) {
        ImageService.instance.evictFileImageCache(existing.avatarImagePath);
        ImageService.instance.evictFileImageCache(ch.avatarImagePath);
      }
      if (existing.bannerImagePath != ch.bannerImagePath) {
        ImageService.instance.evictFileImageCache(existing.bannerImagePath);
        ImageService.instance.evictFileImageCache(ch.bannerImagePath);
      }
    } else {
      ImageService.instance.evictFileImageCache(ch.avatarImagePath);
      ImageService.instance.evictFileImageCache(ch.bannerImagePath);
    }
    _bump();
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

  /// Слияние `channel_meta` gossip: отсутствующие в пакете поля не затираются.
  Future<void> applyChannelMetaFromPayload(Map<String, dynamic> p) async {
    if (_db == null) return;
    final channelId = p['channelId'] as String?;
    final name = p['name'] as String?;
    final adminId = p['adminId'] as String?;
    if (channelId == null || name == null || adminId == null) return;

    final existing = await getChannel(channelId);

    List<String> subs() {
      if (p.containsKey('subscriberIds')) {
        final raw = p['subscriberIds'] as List<dynamic>?;
        return raw?.cast<String>() ?? [adminId];
      }
      return existing?.subscriberIds ?? [adminId];
    }

    List<String> mods() {
      if (p.containsKey('moderatorIds')) {
        final raw = p['moderatorIds'] as List<dynamic>?;
        return raw?.cast<String>() ?? const [];
      }
      return existing?.moderatorIds ?? const [];
    }

    final ch = Channel(
      id: channelId,
      name: name,
      adminId: adminId,
      subscriberIds: subs(),
      moderatorIds: mods(),
      avatarColor: p.containsKey('avatarColor')
          ? (p['avatarColor'] as int? ?? 0xFF42A5F5)
          : (existing?.avatarColor ?? 0xFF42A5F5),
      avatarEmoji: p.containsKey('avatarEmoji')
          ? (p['avatarEmoji'] as String? ?? '📢')
          : (existing?.avatarEmoji ?? '📢'),
      avatarImagePath: existing?.avatarImagePath,
      bannerImagePath: existing?.bannerImagePath,
      description: p.containsKey('description')
          ? p['description'] as String?
          : existing?.description,
      commentsEnabled: p.containsKey('commentsEnabled')
          ? (p['commentsEnabled'] as bool? ?? true)
          : (existing?.commentsEnabled ?? true),
      createdAt: p.containsKey('createdAt')
          ? (p['createdAt'] as int? ??
              DateTime.now().millisecondsSinceEpoch)
          : (existing?.createdAt ??
              DateTime.now().millisecondsSinceEpoch),
      verified: p.containsKey('verified')
          ? (p['verified'] as bool? ?? false)
          : (existing?.verified ?? false),
      verifiedBy: p.containsKey('verifiedBy')
          ? p['verifiedBy'] as String?
          : existing?.verifiedBy,
      foreignAgent: p.containsKey('foreignAgent')
          ? (p['foreignAgent'] as bool? ?? false)
          : (existing?.foreignAgent ?? false),
      blocked: p.containsKey('blocked')
          ? (p['blocked'] as bool? ?? false)
          : (existing?.blocked ?? false),
      username: p.containsKey('username')
          ? (p['username'] as String? ?? '')
          : (existing?.username ?? ''),
      universalCode: p.containsKey('universalCode')
          ? (p['universalCode'] as String? ?? '')
          : (existing?.universalCode ?? ''),
      isPublic: p.containsKey('isPublic')
          ? (p['isPublic'] as bool? ?? true)
          : (existing?.isPublic ?? true),
    );
    await saveChannelFromBroadcast(ch);
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
      'avatar_img_path': ch.avatarImagePath,
      'banner_img_path': ch.bannerImagePath,
      'description': ch.description,
      'comments_enabled': ch.commentsEnabled ? 1 : 0,
      'created_at': ch.createdAt,
      'verified': ch.verified ? 1 : 0,
      'verified_by': ch.verifiedBy,
      'foreign_agent': ch.foreignAgent ? 1 : 0,
      'blocked': ch.blocked ? 1 : 0,
      'username': ch.username,
      'universal_code': ch.universalCode,
      'is_public': ch.isPublic ? 1 : 0,
    });
    _bump();
  }

  /// Поиск каналов среди локально известных: сверяем название, юзернейм, универсальный код.
  /// Возвращает только публичные каналы (если `includeHidden=false`, по умолчанию).
  Future<List<Channel>> searchChannels(String query,
      {bool includeHidden = false}) async {
    if (_db == null) return [];
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final all = await getChannels();
    return all.where((c) {
      if (!includeHidden && !c.isPublic) return false;
      if (c.blocked) return false;
      final name = c.name.toLowerCase();
      final uname = c.username.toLowerCase();
      final code = c.universalCode.toLowerCase();
      return name.contains(q) || uname.contains(q) || code.contains(q);
    }).toList();
  }

  /// true если username уже занят любым известным каналом (кроме `excludeId`).
  Future<bool> isUsernameTaken(String username, {String? excludeId}) async {
    if (_db == null) return false;
    final u = username.trim().toLowerCase();
    if (u.isEmpty) return false;
    final rows = await _db!.query(
      'channels',
      where: 'LOWER(username) = ?',
      whereArgs: [u],
    );
    for (final r in rows) {
      if (excludeId != null && r['id'] == excludeId) continue;
      return true;
    }
    return false;
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

  /// Посты и комментарии всех каналов (метаданные каналов остаются — можно запросить историю снова).
  Future<void> deleteAllPostsAndComments() async {
    if (_db == null) return;
    await _db!.delete('channel_comments');
    await _db!.delete('channel_posts');
    await _db!.delete('channel_read_cursor');
    _bump();
  }

  Future<void> deleteChannel(String channelId) async {
    final posts = await _db!.query('channel_posts',
        columns: ['id'], where: 'channel_id = ?', whereArgs: [channelId]);
    for (final post in posts) {
      await _db!.delete('channel_comments',
          where: 'post_id = ?', whereArgs: [post['id']]);
    }
    await _db!.delete('channel_posts',
        where: 'channel_id = ?', whereArgs: [channelId]);
    await _db!.delete('channel_read_cursor',
        where: 'channel_id = ?', whereArgs: [channelId]);
    await _db!.delete('channels', where: 'id = ?', whereArgs: [channelId]);
    _bump();
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

  /// Помечает канал как ИНОАГЕНТ (или снимает пометку).
  Future<void> setForeignAgent(String channelId, bool value) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(foreignAgent: value));
  }

  /// Блокирует или разблокирует канал.
  Future<void> setBlocked(String channelId, bool value) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(blocked: value));
  }

  /// Применяет админский пакет (foreign_agent / block / delete) к локальной БД.
  Future<void> applyAdminAction({
    required String channelId,
    bool? foreignAgent,
    bool? blocked,
    bool delete = false,
    String? universalCode,
  }) async {
    if (delete) {
      final ch = await getChannel(channelId);
      if (ch == null) return;
      final uc = universalCode?.trim() ?? '';
      if (uc.isNotEmpty && ch.universalCode.isNotEmpty && ch.universalCode != uc) {
        debugPrint(
            '[RLINK][Channel] Admin delete ignored: universal code mismatch for $channelId');
        return;
      }
      await deleteChannel(channelId);
      return;
    }
    final ch = await getChannel(channelId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(
      foreignAgent: foreignAgent ?? ch.foreignAgent,
      blocked: blocked ?? ch.blocked,
    ));
  }

  // ── Posts ──────────────────────────────────────────────────────

  Future<void> savePost(ChannelPost post) async {
    await _db!.insert('channel_posts', post.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _bump();
  }

  /// Перезаписывает реакции поста в БД (используется при синхронизации истории
  /// из P2P-сети, чтобы обновлённые реакции не терялись).
  Future<void> updatePostReactions(
      String postId, Map<String, List<String>> reactions) async {
    if (_db == null) return;
    await _db!.update(
      'channel_posts',
      {'reactions': reactions.isEmpty ? null : jsonEncode(reactions)},
      where: 'id = ?',
      whereArgs: [postId],
    );
    _bump();
  }

  Future<void> updatePostPollJson(String postId, String? pollJson) async {
    if (_db == null) return;
    await _db!.update(
      'channel_posts',
      {'poll_json': pollJson},
      where: 'id = ?',
      whereArgs: [postId],
    );
    _bump();
  }

  /// Объединяет голоса из входящего `pj` с локальным опросом поста.
  Future<void> mergeIncomingPostPoll(String postId, String? incomingPj) async {
    if (incomingPj == null || incomingPj.isEmpty) return;
    final inc = MessagePoll.tryDecode(incomingPj);
    if (inc == null) return;
    final post = await getPost(postId);
    if (post == null) return;
    final cur = MessagePoll.tryDecode(post.pollJson);
    final merged = (cur ?? inc).mergeVotesFrom(inc);
    await updatePostPollJson(postId, merged.encode());
  }

  Future<void> applyPollVote(
      String postId, String voterId, List<int> choices) async {
    final post = await getPost(postId);
    if (post == null) return;
    final poll = MessagePoll.tryDecode(post.pollJson);
    if (poll == null) return;
    final next = poll.withVote(voterId, choices);
    await updatePostPollJson(postId, next.encode());
  }

  /// Перезаписывает реакции комментария.
  Future<void> updateCommentReactions(
      String commentId, Map<String, List<String>> reactions) async {
    if (_db == null) return;
    await _db!.update(
      'channel_comments',
      {'reactions': reactions.isEmpty ? null : jsonEncode(reactions)},
      where: 'id = ?',
      whereArgs: [commentId],
    );
    _bump();
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
      orderBy: 'timestamp DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChannelPost.fromMap(rows.first);
  }

  /// Posts newer than the read cursor (all authors).
  Future<Map<String, int>> getChannelUnreadCounts() async {
    if (_db == null) return const {};
    final rows = await _db!.rawQuery('''
      SELECT cp.channel_id AS cid, COUNT(*) AS c
      FROM channel_posts cp
      LEFT JOIN channel_read_cursor cr ON cr.channel_id = cp.channel_id
      WHERE
        cr.channel_id IS NULL
        OR cp.timestamp > cr.last_read_ts
        OR (cp.timestamp = cr.last_read_ts AND cp.id > cr.last_read_id)
      GROUP BY cp.channel_id
    ''');
    return {for (final r in rows) r['cid'] as String: (r['c'] as int?) ?? 0};
  }

  Future<void> markChannelRead(String channelId) async {
    if (_db == null) return;
    final rows = await _db!.query(
      'channel_posts',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'timestamp DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      await _db!.delete(
        'channel_read_cursor',
        where: 'channel_id = ?',
        whereArgs: [channelId],
      );
    } else {
      final p = ChannelPost.fromMap(rows.first);
      await _db!.insert(
        'channel_read_cursor',
        {
          'channel_id': channelId,
          'last_read_ts': p.timestamp,
          'last_read_id': p.id,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    _bump();
  }

  Future<void> deletePost(String postId) async {
    await _db!.delete('channel_posts', where: 'id = ?', whereArgs: [postId]);
    await _db!.delete('channel_comments',
        where: 'post_id = ?', whereArgs: [postId]);
    _bump();
  }

  // ── Comments ──────────────────────────────────────────────────

  Future<void> saveComment(ChannelComment comment) async {
    await _db!.insert('channel_comments', comment.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _bump();
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

  Future<void> deleteCommentById(String commentId) async {
    if (_db == null) return;
    await _db!.delete('channel_comments',
        where: 'id = ?', whereArgs: [commentId]);
    _bump();
  }

  Future<String?> _findChannelIdForCompact(String compact) async {
    if (_db == null) return null;
    final rows = await _db!.query('channels', columns: ['id']);
    for (final r in rows) {
      final id = r['id'] as String;
      if (id.replaceAll('-', '') == compact) return id;
    }
    return null;
  }

  Future<void> applyChannelBannerFromNetwork(
      String compactId, String localImagePath) async {
    final fullId = await _findChannelIdForCompact(compactId);
    if (fullId == null) return;
    final ch = await getChannel(fullId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(bannerImagePath: localImagePath));
  }

  Future<void> applyChannelAvatarFromNetwork(
      String compactId, String localImagePath) async {
    final fullId = await _findChannelIdForCompact(compactId);
    if (fullId == null) return;
    final ch = await getChannel(fullId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(avatarImagePath: localImagePath));
  }

  Future<void> flushPendingMediaForPost(String postId) async {
    final img = _pendingPostImagePaths.remove(postId);
    final vid = _pendingPostVideoPaths.remove(postId);
    final vo = _pendingPostVoicePaths.remove(postId);
    final fp = _pendingPostFilePaths.remove(postId);
    final fn = _pendingPostFileNames.remove(postId);
    final fs = _pendingPostFileSizes.remove(postId);
    if (img == null &&
        vid == null &&
        vo == null &&
        fp == null) return;
    final post = await getPost(postId);
    if (post == null) {
      if (img != null) _pendingPostImagePaths[postId] = img;
      if (vid != null) _pendingPostVideoPaths[postId] = vid;
      if (vo != null) _pendingPostVoicePaths[postId] = vo;
      if (fp != null) _pendingPostFilePaths[postId] = fp;
      if (fn != null) _pendingPostFileNames[postId] = fn;
      if (fs != null) _pendingPostFileSizes[postId] = fs;
      return;
    }
    await _db!.update(
      'channel_posts',
      {
        'image_path': img ?? post.imagePath,
        'video_path': vid ?? post.videoPath,
        'voice_path': vo ?? post.voicePath,
        'file_path': fp ?? post.filePath,
        'file_name': fn ?? post.fileName,
        'file_size': fs ?? post.fileSize,
      },
      where: 'id = ?',
      whereArgs: [postId],
    );
    _bump();
  }

  /// После сборки img_chunk для поста канала.
  Future<void> applyAssembledPostMedia({
    required String postId,
    String? imagePath,
    String? videoPath,
    String? voicePath,
    String? filePath,
    String? fileName,
    int? fileSize,
  }) async {
    if (imagePath == null &&
        videoPath == null &&
        voicePath == null &&
        filePath == null) return;
    final post = await getPost(postId);
    if (post == null) {
      if (imagePath != null) _pendingPostImagePaths[postId] = imagePath!;
      if (videoPath != null) _pendingPostVideoPaths[postId] = videoPath!;
      if (voicePath != null) _pendingPostVoicePaths[postId] = voicePath!;
      if (filePath != null) _pendingPostFilePaths[postId] = filePath!;
      if (fileName != null) _pendingPostFileNames[postId] = fileName!;
      if (fileSize != null) _pendingPostFileSizes[postId] = fileSize!;
      return;
    }
    await _db!.update(
      'channel_posts',
      {
        'image_path': imagePath ?? post.imagePath,
        'video_path': videoPath ?? post.videoPath,
        'voice_path': voicePath ?? post.voicePath,
        'file_path': filePath ?? post.filePath,
        'file_name': fileName ?? post.fileName,
        'file_size': fileSize ?? post.fileSize,
      },
      where: 'id = ?',
      whereArgs: [postId],
    );
    _bump();
  }

  Future<void> flushPendingMediaForComment(String commentId) async {
    final img = _pendingCommentImagePaths.remove(commentId);
    final vid = _pendingCommentVideoPaths.remove(commentId);
    final vo = _pendingCommentVoicePaths.remove(commentId);
    final fp = _pendingCommentFilePaths.remove(commentId);
    final fn = _pendingCommentFileNames.remove(commentId);
    final fs = _pendingCommentFileSizes.remove(commentId);
    if (img == null &&
        vid == null &&
        vo == null &&
        fp == null) return;
    final c = await getComment(commentId);
    if (c == null) {
      if (img != null) _pendingCommentImagePaths[commentId] = img;
      if (vid != null) _pendingCommentVideoPaths[commentId] = vid;
      if (vo != null) _pendingCommentVoicePaths[commentId] = vo;
      if (fp != null) _pendingCommentFilePaths[commentId] = fp;
      if (fn != null) _pendingCommentFileNames[commentId] = fn;
      if (fs != null) _pendingCommentFileSizes[commentId] = fs;
      return;
    }
    await _db!.update(
      'channel_comments',
      {
        'image_path': img ?? c.imagePath,
        'video_path': vid ?? c.videoPath,
        'voice_path': vo ?? c.voicePath,
        'file_path': fp ?? c.filePath,
        'file_name': fn ?? c.fileName,
        'file_size': fs ?? c.fileSize,
      },
      where: 'id = ?',
      whereArgs: [commentId],
    );
    _bump();
  }

  Future<void> applyAssembledCommentMedia({
    required String commentId,
    String? imagePath,
    String? videoPath,
    String? voicePath,
    String? filePath,
    String? fileName,
    int? fileSize,
  }) async {
    if (imagePath == null &&
        videoPath == null &&
        voicePath == null &&
        filePath == null) return;
    final c = await getComment(commentId);
    if (c == null) {
      if (imagePath != null) {
        _pendingCommentImagePaths[commentId] = imagePath!;
      }
      if (videoPath != null) {
        _pendingCommentVideoPaths[commentId] = videoPath!;
      }
      if (voicePath != null) {
        _pendingCommentVoicePaths[commentId] = voicePath!;
      }
      if (filePath != null) _pendingCommentFilePaths[commentId] = filePath!;
      if (fileName != null) _pendingCommentFileNames[commentId] = fileName!;
      if (fileSize != null) _pendingCommentFileSizes[commentId] = fileSize!;
      return;
    }
    await _db!.update(
      'channel_comments',
      {
        'image_path': imagePath ?? c.imagePath,
        'video_path': videoPath ?? c.videoPath,
        'voice_path': voicePath ?? c.voicePath,
        'file_path': filePath ?? c.filePath,
        'file_name': fileName ?? c.fileName,
        'file_size': fileSize ?? c.fileSize,
      },
      where: 'id = ?',
      whereArgs: [commentId],
    );
    _bump();
  }

  /// Повторная отправка бинарника поста подписчику (история канала).
  Future<void> forwardChannelPostMediaIfPresent(ChannelPost post) async {
    final aid = post.authorId;

    String? resolve(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      return ImageService.instance.resolveStoredPath(raw);
    }

    final img = resolve(post.imagePath);
    if (img != null && File(img).existsSync()) {
      final bytes = await File(img).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: post.id,
        totalChunks: chunks.length,
        fromId: aid,
        isAvatar: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: post.id,
          index: i,
          base64Data: chunks[i],
          fromId: aid,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }

    final vid = resolve(post.videoPath);
    if (vid != null && File(vid).existsSync()) {
      final bytes = await File(vid).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: post.id,
        totalChunks: chunks.length,
        fromId: aid,
        isAvatar: false,
        isVideo: true,
        isSquare: true,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: post.id,
          index: i,
          base64Data: chunks[i],
          fromId: aid,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }

    final voice = resolve(post.voicePath);
    if (voice != null && File(voice).existsSync()) {
      final bytes = await File(voice).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: post.id,
        totalChunks: chunks.length,
        fromId: aid,
        isAvatar: false,
        isVoice: true,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: post.id,
          index: i,
          base64Data: chunks[i],
          fromId: aid,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }

    final fPath = resolve(post.filePath);
    if (fPath != null && File(fPath).existsSync()) {
      final bytes = await File(fPath).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final nm = post.fileName ?? p.basename(fPath);
      await GossipRouter.instance.sendImgMeta(
        msgId: post.id,
        totalChunks: chunks.length,
        fromId: aid,
        isAvatar: false,
        isFile: true,
        fileName: nm,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: post.id,
          index: i,
          base64Data: chunks[i],
          fromId: aid,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }
  }

  /// Повторная отправка медиа комментария (история канала).
  Future<void> forwardChannelCommentMediaIfPresent(
      ChannelComment c, String authorId) async {
    String? resolve(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      return ImageService.instance.resolveStoredPath(raw);
    }

    final img = resolve(c.imagePath);
    if (img != null && File(img).existsSync()) {
      final bytes = await File(img).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: c.id,
        totalChunks: chunks.length,
        fromId: authorId,
        isAvatar: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: c.id,
          index: i,
          base64Data: chunks[i],
          fromId: authorId,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }

    final vid = resolve(c.videoPath);
    if (vid != null && File(vid).existsSync()) {
      final bytes = await File(vid).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: c.id,
        totalChunks: chunks.length,
        fromId: authorId,
        isAvatar: false,
        isVideo: true,
        isSquare: true,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: c.id,
          index: i,
          base64Data: chunks[i],
          fromId: authorId,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }

    final voice = resolve(c.voicePath);
    if (voice != null && File(voice).existsSync()) {
      final bytes = await File(voice).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: c.id,
        totalChunks: chunks.length,
        fromId: authorId,
        isAvatar: false,
        isVoice: true,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: c.id,
          index: i,
          base64Data: chunks[i],
          fromId: authorId,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }

    final fPath = resolve(c.filePath);
    if (fPath != null && File(fPath).existsSync()) {
      final bytes = await File(fPath).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      final nm = c.fileName ?? p.basename(fPath);
      await GossipRouter.instance.sendImgMeta(
        msgId: c.id,
        totalChunks: chunks.length,
        fromId: authorId,
        isAvatar: false,
        isFile: true,
        fileName: nm,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: c.id,
          index: i,
          base64Data: chunks[i],
          fromId: authorId,
        );
        await Future.delayed(const Duration(milliseconds: 35));
      }
    }
  }

  // ── Reactions ────────────────────────────────────────────────

  /// Переключает реакцию [emoji] от [reactorId] на посте канала [postId].
  Future<void> togglePostReaction(
      String postId, String emoji, String reactorId) async {
    if (_db == null) return;
    final rows = await _db!.query(
      'channel_posts',
      where: 'id = ?',
      whereArgs: [postId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final post = ChannelPost.fromMap(rows.first);
    final updated = <String, List<String>>{};
    post.reactions.forEach((k, v) => updated[k] = List<String>.from(v));
    final list = updated.putIfAbsent(emoji, () => <String>[]);
    if (list.contains(reactorId)) {
      list.remove(reactorId);
      if (list.isEmpty) updated.remove(emoji);
    } else {
      list.add(reactorId);
    }
    await _db!.update(
      'channel_posts',
      {'reactions': updated.isEmpty ? null : jsonEncode(updated)},
      where: 'id = ?',
      whereArgs: [postId],
    );
    _bump();
  }

  /// Переключает реакцию [emoji] от [reactorId] на комментарии [commentId].
  Future<void> toggleCommentReaction(
      String commentId, String emoji, String reactorId) async {
    if (_db == null) return;
    final rows = await _db!.query(
      'channel_comments',
      where: 'id = ?',
      whereArgs: [commentId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final comment = ChannelComment.fromMap(rows.first);
    final updated = <String, List<String>>{};
    comment.reactions.forEach((k, v) => updated[k] = List<String>.from(v));
    final list = updated.putIfAbsent(emoji, () => <String>[]);
    if (list.contains(reactorId)) {
      list.remove(reactorId);
      if (list.isEmpty) updated.remove(emoji);
    } else {
      list.add(reactorId);
    }
    await _db!.update(
      'channel_comments',
      {'reactions': updated.isEmpty ? null : jsonEncode(updated)},
      where: 'id = ?',
      whereArgs: [commentId],
    );
    _bump();
  }

  Future<ChannelPost?> getPost(String postId) async {
    if (_db == null) return null;
    final rows = await _db!.query(
      'channel_posts',
      where: 'id = ?',
      whereArgs: [postId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final comments = await getComments(postId);
    return ChannelPost.fromMap(rows.first, comments: comments);
  }

  Future<ChannelComment?> getComment(String commentId) async {
    if (_db == null) return null;
    final rows = await _db!.query(
      'channel_comments',
      where: 'id = ?',
      whereArgs: [commentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChannelComment.fromMap(rows.first);
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
    await _db?.delete('channel_read_cursor');
    await _db?.delete('channels');
    _bump();
  }

  String newId() => _uuid.v4();

  // ── Verification Requests (persistent) ──────────────────────────

  final pendingVerifications = ValueNotifier<List<VerificationRequest>>([]);

  Future<void> addVerificationRequest(VerificationRequest req) async {
    if (_db == null) return;
    await _db!.insert('verification_requests', req.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _loadVerificationRequests();
  }

  Future<void> removeVerificationRequest(String channelId) async {
    if (_db == null) return;
    await _db!.delete('verification_requests',
        where: 'channel_id = ?', whereArgs: [channelId]);
    await _loadVerificationRequests();
  }

  Future<void> _loadVerificationRequests() async {
    if (_db == null) return;
    final rows = await _db!.query('verification_requests',
        orderBy: 'requested_at DESC');
    pendingVerifications.value =
        rows.map((r) => VerificationRequest.fromMap(r)).toList();
  }

  Future<void> loadVerificationRequests() => _loadVerificationRequests();

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

/// Запрос на верификацию канала (сохраняется в БД).
class VerificationRequest {
  final String channelId;
  final String channelName;
  final String adminId;
  final int subscriberCount;
  final String avatarEmoji;
  final String? description;
  final int requestedAt;

  const VerificationRequest({
    required this.channelId,
    required this.channelName,
    required this.adminId,
    this.subscriberCount = 0,
    this.avatarEmoji = '📢',
    this.description,
    required this.requestedAt,
  });

  Map<String, dynamic> toMap() => {
    'channel_id': channelId,
    'channel_name': channelName,
    'admin_id': adminId,
    'subscriber_count': subscriberCount,
    'avatar_emoji': avatarEmoji,
    'description': description,
    'requested_at': requestedAt,
  };

  factory VerificationRequest.fromMap(Map<String, dynamic> m) =>
      VerificationRequest(
        channelId: m['channel_id'] as String,
        channelName: m['channel_name'] as String,
        adminId: m['admin_id'] as String,
        subscriberCount: m['subscriber_count'] as int? ?? 0,
        avatarEmoji: m['avatar_emoji'] as String? ?? '📢',
        description: m['description'] as String?,
        requestedAt: m['requested_at'] as int,
      );
}
