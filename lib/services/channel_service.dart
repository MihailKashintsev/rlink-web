import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/channel.dart';
import '../models/message_poll.dart';
import '../utils/reaction_limit.dart';
import 'gossip_router.dart';
import 'image_service.dart';
import 'account_sync_publish.dart';
import 'channel_directory_relay.dart';
import 'crypto_service.dart';
import 'web_identity_portable.dart';

Map<String, String> _staffLabelsFromDb(String? raw) {
  if (raw == null || raw.isEmpty || raw == '{}') return const {};
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return const {};
  }
}

String _staffLabelsToDb(Map<String, String> m) =>
    m.isEmpty ? '{}' : jsonEncode(m);

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

  /// Последний применённый с relay `updatedAt` по channelId (антидубль снимка каталога).
  static const _relayChDirRevPrefsKey = 'relay_channel_dir_updated_at_v1';

  final _uuid = const Uuid();
  Database? _db;

  Future<String> _dbPath(String fileName) async {
    if (kIsWeb) return fileName;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, fileName);
  }

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
    final path = await _dbPath('channels.db');
    _db = await openDatabase(
      path,
      version: 19,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE channels (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            admin_id TEXT NOT NULL,
            subscribers TEXT NOT NULL,
            moderators TEXT DEFAULT '',
            link_admins TEXT DEFAULT '',
            sign_staff_posts INTEGER DEFAULT 0,
            staff_labels_json TEXT DEFAULT '{}',
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
            is_public INTEGER DEFAULT 1,
            drive_backup_enabled INTEGER DEFAULT 0,
            drive_backup_rev INTEGER DEFAULT 0,
            drive_file_id TEXT,
            drive_file_url TEXT,
            drive_keys_url TEXT,
            allow_mods_manage_drive_account INTEGER DEFAULT 0
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
            poll_json TEXT,
            view_count INTEGER DEFAULT 0,
            forward_count INTEGER DEFAULT 0,
            staff_label TEXT,
            is_sticker INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE channel_post_viewers (
            post_id TEXT NOT NULL,
            viewer_id TEXT NOT NULL,
            PRIMARY KEY (post_id, viewer_id)
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_cpv_post ON channel_post_viewers(post_id)');
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
          await db.execute(
              'ALTER TABLE channels ADD COLUMN verified INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE channels ADD COLUMN verified_by TEXT');
        }
        if (oldVersion < 3) {
          await db.execute(
              "ALTER TABLE channels ADD COLUMN moderators TEXT DEFAULT ''");
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
          await db.execute(
              'ALTER TABLE channels ADD COLUMN foreign_agent INTEGER DEFAULT 0');
          await db.execute(
              'ALTER TABLE channels ADD COLUMN blocked INTEGER DEFAULT 0');
        }
        if (oldVersion < 6) {
          await db.execute(
              "ALTER TABLE channels ADD COLUMN username TEXT DEFAULT ''");
          await db.execute(
              "ALTER TABLE channels ADD COLUMN universal_code TEXT DEFAULT ''");
          await db.execute(
              'ALTER TABLE channels ADD COLUMN is_public INTEGER DEFAULT 1');
        }
        if (oldVersion < 7) {
          try {
            await db
                .execute('ALTER TABLE channel_posts ADD COLUMN reactions TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN reactions TEXT');
          } catch (_) {}
        }
        if (oldVersion < 8) {
          try {
            await db
                .execute('ALTER TABLE channel_posts ADD COLUMN poll_json TEXT');
          } catch (_) {}
        }
        if (oldVersion < 9) {
          try {
            await db.execute(
                'ALTER TABLE channels ADD COLUMN banner_img_path TEXT');
          } catch (_) {}
        }
        if (oldVersion < 10) {
          try {
            await db.execute(
                'ALTER TABLE channel_posts ADD COLUMN voice_path TEXT');
          } catch (_) {}
          try {
            await db
                .execute('ALTER TABLE channel_posts ADD COLUMN file_path TEXT');
          } catch (_) {}
          try {
            await db
                .execute('ALTER TABLE channel_posts ADD COLUMN file_name TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_posts ADD COLUMN file_size INTEGER');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN image_path TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN video_path TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN voice_path TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN file_path TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN file_name TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_comments ADD COLUMN file_size INTEGER');
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
        if (oldVersion < 12) {
          try {
            await db.execute(
                'ALTER TABLE channel_posts ADD COLUMN view_count INTEGER DEFAULT 0');
          } catch (_) {}
          await db.execute('''
            CREATE TABLE IF NOT EXISTS channel_post_viewers (
              post_id TEXT NOT NULL,
              viewer_id TEXT NOT NULL,
              PRIMARY KEY (post_id, viewer_id)
            )
          ''');
          try {
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_cpv_post ON channel_post_viewers(post_id)');
          } catch (_) {}
        }
        if (oldVersion < 13) {
          try {
            await db.execute(
                'ALTER TABLE channel_posts ADD COLUMN forward_count INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 14) {
          try {
            await db.execute(
                "ALTER TABLE channels ADD COLUMN link_admins TEXT DEFAULT ''");
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channels ADD COLUMN sign_staff_posts INTEGER DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute(
                "ALTER TABLE channels ADD COLUMN staff_labels_json TEXT DEFAULT '{}'");
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channel_posts ADD COLUMN staff_label TEXT');
          } catch (_) {}
        }
        if (oldVersion < 15) {
          try {
            await db.execute(
                'ALTER TABLE channels ADD COLUMN drive_backup_enabled INTEGER DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE channels ADD COLUMN drive_backup_rev INTEGER DEFAULT 0');
          } catch (_) {}
          try {
            await db
                .execute('ALTER TABLE channels ADD COLUMN drive_file_id TEXT');
          } catch (_) {}
        }
        if (oldVersion < 16) {
          try {
            await db.execute(
                'ALTER TABLE channel_posts ADD COLUMN is_sticker INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 17) {
          try {
            await db.execute(
              'ALTER TABLE channels ADD COLUMN allow_mods_manage_drive_account INTEGER DEFAULT 0',
            );
          } catch (_) {}
        }
        if (oldVersion < 18) {
          try {
            await db.execute('ALTER TABLE channels ADD COLUMN drive_file_url TEXT');
          } catch (_) {}
        }
        if (oldVersion < 19) {
          try {
            await db.execute('ALTER TABLE channels ADD COLUMN drive_keys_url TEXT');
          } catch (_) {}
        }
      },
    );
  }

  Future<void> _ensureDbReady() async {
    if (_db != null) return;
    await init();
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
    await _ensureDbReady();
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
      'link_admins': channel.linkAdminIds.join(','),
      'sign_staff_posts': channel.signStaffPosts ? 1 : 0,
      'staff_labels_json': _staffLabelsToDb(channel.staffLabels),
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
      'drive_backup_enabled': channel.driveBackupEnabled ? 1 : 0,
      'drive_backup_rev': channel.driveBackupRev,
      'drive_file_id': channel.driveFileId,
      'drive_file_url': channel.driveFileUrl,
      'drive_keys_url': channel.driveKeysUrl,
      'allow_mods_manage_drive_account':
          channel.allowModeratorsManageDriveAccount ? 1 : 0,
    });
    _bump();
    unawaited(publishAccountChannelSubscriptions());
    if (kIsWeb) {
      unawaited(WebIdentityPortable.exportIdentityKeyDownload());
    }
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

  Future<void> upsertChannelsFromBackup(List<Channel> channels) async {
    await _ensureDbReady();
    if (_db == null) return;
    await _db!.transaction((txn) async {
      for (final ch in channels) {
        await txn.insert(
          'channels',
          {
            'id': ch.id,
            'name': ch.name,
            'admin_id': ch.adminId,
            'subscribers': ch.subscriberIds.join(','),
            'moderators': ch.moderatorIds.join(','),
            'link_admins': ch.linkAdminIds.join(','),
            'sign_staff_posts': ch.signStaffPosts ? 1 : 0,
            'staff_labels_json': _staffLabelsToDb(ch.staffLabels),
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
            'drive_backup_enabled': ch.driveBackupEnabled ? 1 : 0,
            'drive_backup_rev': ch.driveBackupRev,
            'drive_file_id': ch.driveFileId,
            'drive_file_url': ch.driveFileUrl,
            'drive_keys_url': ch.driveKeysUrl,
            'allow_mods_manage_drive_account':
                ch.allowModeratorsManageDriveAccount ? 1 : 0,
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
    final channels = await _db!.query('channels');
    final posts = await _db!.query('channel_posts');
    final comments = await _db!.query('channel_comments');
    final viewers = await _db!.query('channel_post_viewers');
    final cursors = await _db!.query('channel_read_cursor');
    final verifyReq = await _db!.query('verification_requests');
    return {
      'v': 1,
      'channels': channels.map((r) => Map<String, dynamic>.from(r)).toList(),
      'posts': posts.map((r) => Map<String, dynamic>.from(r)).toList(),
      'comments': comments.map((r) => Map<String, dynamic>.from(r)).toList(),
      'viewers': viewers.map((r) => Map<String, dynamic>.from(r)).toList(),
      'cursors': cursors.map((r) => Map<String, dynamic>.from(r)).toList(),
      'verifyReq': verifyReq.map((r) => Map<String, dynamic>.from(r)).toList(),
    };
  }

  Future<void> importBackupSnapshot(Map<String, dynamic> snapshot) async {
    await _ensureDbReady();
    if (_db == null) return;
    List<Map<String, dynamic>> rowsFor(String key) =>
        (snapshot[key] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    final channels = rowsFor('channels');
    final posts = rowsFor('posts');
    final comments = rowsFor('comments');
    final viewers = rowsFor('viewers');
    final cursors = rowsFor('cursors');
    final verifyReq = rowsFor('verifyReq');
    await _db!.transaction((txn) async {
      for (final row in channels) {
        await txn.insert(
          'channels',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in posts) {
        await txn.insert(
          'channel_posts',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in comments) {
        await txn.insert(
          'channel_comments',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in viewers) {
        await txn.insert(
          'channel_post_viewers',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in cursors) {
        await txn.insert(
          'channel_read_cursor',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in verifyReq) {
        await txn.insert(
          'verification_requests',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _bump();
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
        await _db!.rawDelete(
          'DELETE FROM channel_post_viewers WHERE post_id IN '
          '(SELECT id FROM channel_posts WHERE channel_id = ?)',
          [cid],
        );
        await _db!.delete(
          'channel_comments',
          where:
              'post_id IN (SELECT id FROM channel_posts WHERE channel_id = ?)',
          whereArgs: [cid],
        );
        await _db!
            .delete('channel_posts', where: 'channel_id = ?', whereArgs: [cid]);
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

  static const _channelMediaColumns = {
    'image_path',
    'video_path',
    'voice_path',
    'file_path',
  };

  Future<int> _sumDistinctColumnFromTable(String table, String column) async {
    if (_db == null || !_channelMediaColumns.contains(column)) return 0;
    final rows = await _db!.rawQuery(
      'SELECT DISTINCT $column AS p FROM $table '
      'WHERE $column IS NOT NULL AND TRIM($column) != ""',
    );
    final seen = <String>{};
    var sum = 0;
    for (final r in rows) {
      final raw = r['p'] as String?;
      if (raw == null || raw.isEmpty) continue;
      final resolved = ImageService.instance.resolveStoredPath(raw) ?? raw;
      if (seen.contains(resolved)) continue;
      seen.add(resolved);
      try {
        final f = File(resolved);
        if (await f.exists()) sum += await f.length();
      } catch (_) {}
    }
    return sum;
  }

  /// Сумма размеров медиа в постах и комментариях каналов для колонки.
  Future<int> sumDistinctChannelMediaBytes(String column) async {
    final a = await _sumDistinctColumnFromTable('channel_posts', column);
    final b = await _sumDistinctColumnFromTable('channel_comments', column);
    return a + b;
  }

  /// Удаляет файлы и обнуляет колонку во всех постах и комментариях.
  Future<void> clearAllChannelMediaColumn(String column) async {
    if (_db == null || !_channelMediaColumns.contains(column)) return;
    for (final table in ['channel_posts', 'channel_comments']) {
      final rows = await _db!.query(table, columns: [column]);
      for (final r in rows) {
        await _tryDeleteChannelMediaFile(r[column] as String?);
      }
      if (column == 'file_path') {
        await _db!.execute(
          'UPDATE $table SET file_path=NULL, file_name=NULL, file_size=NULL '
          'WHERE file_path IS NOT NULL',
        );
      } else {
        await _db!.rawUpdate(
          'UPDATE $table SET $column=NULL WHERE $column IS NOT NULL '
          'AND TRIM($column) != ""',
        );
      }
    }
    _bump();
  }

  Channel _channelFromRow(Map<String, dynamic> r) => Channel(
        id: r['id'] as String,
        name: r['name'] as String,
        adminId: r['admin_id'] as String,
        subscriberIds: (r['subscribers'] as String)
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        moderatorIds: ((r['moderators'] as String?) ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        linkAdminIds: ((r['link_admins'] as String?) ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        signStaffPosts: (r['sign_staff_posts'] as int?) == 1,
        staffLabels: _staffLabelsFromDb(r['staff_labels_json'] as String?),
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
        driveBackupEnabled: (r['drive_backup_enabled'] as int?) == 1,
        driveBackupRev: (r['drive_backup_rev'] as int?) ?? 0,
        driveFileId: r['drive_file_id'] as String?,
        driveFileUrl: r['drive_file_url'] as String?,
        driveKeysUrl: r['drive_keys_url'] as String?,
        allowModeratorsManageDriveAccount:
            (r['allow_mods_manage_drive_account'] as int?) == 1,
      );

  Future<void> updateChannel(Channel ch) async {
    final existing = await getChannel(ch.id);
    await _db!.update(
      'channels',
      {
        'name': ch.name,
        'subscribers': ch.subscriberIds.join(','),
        'moderators': ch.moderatorIds.join(','),
        'link_admins': ch.linkAdminIds.join(','),
        'sign_staff_posts': ch.signStaffPosts ? 1 : 0,
        'staff_labels_json': _staffLabelsToDb(ch.staffLabels),
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
        'drive_backup_enabled': ch.driveBackupEnabled ? 1 : 0,
        'drive_backup_rev': ch.driveBackupRev,
        'drive_file_id': ch.driveFileId,
        'drive_file_url': ch.driveFileUrl,
        'drive_keys_url': ch.driveKeysUrl,
        'allow_mods_manage_drive_account':
            ch.allowModeratorsManageDriveAccount ? 1 : 0,
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
    if (kIsWeb) {
      unawaited(WebIdentityPortable.exportIdentityKeyDownload());
    }
  }

  /// Promote or demote [userId] as moderator of [channelId].
  Future<Channel?> setModerator(
      String channelId, String userId, bool isMod) async {
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

  /// Админы «ссылок» — публикуют наравне с модераторами.
  Future<Channel?> setLinkAdmin(
      String channelId, String userId, bool isLink) async {
    final ch = await getChannel(channelId);
    if (ch == null) return null;
    final links = List<String>.from(ch.linkAdminIds);
    if (isLink) {
      if (!links.contains(userId)) links.add(userId);
    } else {
      links.remove(userId);
    }
    final updated = ch.copyWith(linkAdminIds: links);
    await updateChannel(updated);
    return updated;
  }

  Future<void> updatePostStaffLabel(String postId, String? staffLabel) async {
    if (_db == null) return;
    await _db!.update(
      'channel_posts',
      {'staff_label': staffLabel},
      where: 'id = ?',
      whereArgs: [postId],
    );
    _bump();
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

    List<String> links() {
      if (p.containsKey('linkAdminIds')) {
        final raw = p['linkAdminIds'] as List<dynamic>?;
        return raw?.cast<String>() ?? const [];
      }
      return existing?.linkAdminIds ?? const [];
    }

    bool signStaff() {
      if (p.containsKey('signStaffPosts')) {
        return p['signStaffPosts'] as bool? ?? false;
      }
      return existing?.signStaffPosts ?? false;
    }

    Map<String, String> labels() {
      if (p.containsKey('staffLabels') && p['staffLabels'] is Map) {
        final m = p['staffLabels'] as Map;
        return m.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      return existing?.staffLabels ?? const {};
    }

    final ch = Channel(
      id: channelId,
      name: name,
      adminId: adminId,
      subscriberIds: subs(),
      moderatorIds: mods(),
      linkAdminIds: links(),
      signStaffPosts: signStaff(),
      staffLabels: labels(),
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
          ? (p['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch)
          : (existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch),
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
      driveBackupEnabled: p.containsKey('driveBackup')
          ? (p['driveBackup'] as bool? ?? false)
          : (existing?.driveBackupEnabled ?? false),
      driveBackupRev: p.containsKey('driveBackupRev')
          ? ((p['driveBackupRev'] as num?)?.toInt() ?? 0)
          : (existing?.driveBackupRev ?? 0),
      driveFileId: existing?.driveFileId,
      driveFileUrl: p.containsKey('driveFileUrl')
          ? p['driveFileUrl'] as String?
          : existing?.driveFileUrl,
      driveKeysUrl: p.containsKey('driveKeysUrl')
          ? p['driveKeysUrl'] as String?
          : existing?.driveKeysUrl,
      allowModeratorsManageDriveAccount:
          p.containsKey('allowModeratorsManageDriveAccount')
              ? (p['allowModeratorsManageDriveAccount'] as bool? ?? false)
              : (existing?.allowModeratorsManageDriveAccount ?? false),
    );
    await saveChannelFromBroadcast(ch);
  }

  /// Слияние снимка каталога с relay (подпись уже проверена на сервере).
  Future<void> applyRelayChannelDirectoryEntries(List<dynamic> raw) async {
    if (_db == null || raw.isEmpty) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final revs = <String, int>{};
    try {
      final s = prefs.getString(_relayChDirRevPrefsKey);
      if (s != null && s.isNotEmpty) {
        final j = jsonDecode(s) as Map<String, dynamic>;
        for (final e in j.entries) {
          revs[e.key] = (e.value as num).toInt();
        }
      }
    } catch (_) {}

    var changed = false;
    for (final item in raw) {
      if (item is! Map) continue;
      final p = Map<String, dynamic>.from(item);
      final adminId = p['adminId'] as String?;
      final channelId = p['channelId'] as String?;
      if (adminId == null ||
          channelId == null ||
          adminId.isEmpty ||
          channelId.isEmpty) {
        continue;
      }
      if (adminId == myId) continue;

      final updatedAt = (p['updatedAt'] as num?)?.toInt() ?? 0;
      if (updatedAt <= 0) continue;
      if (updatedAt <= (revs[channelId] ?? 0)) continue;

      if ((p['isPublic'] as bool?) == false) continue;

      final name = p['name'] as String?;
      if (name == null || name.isEmpty) continue;

      await applyChannelMetaFromPayload(p);
      revs[channelId] = updatedAt;
      changed = true;
    }

    if (changed) {
      await prefs.setString(_relayChDirRevPrefsKey, jsonEncode(revs));
    }
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
      'link_admins': ch.linkAdminIds.join(','),
      'sign_staff_posts': ch.signStaffPosts ? 1 : 0,
      'staff_labels_json': _staffLabelsToDb(ch.staffLabels),
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
      'drive_backup_enabled': ch.driveBackupEnabled ? 1 : 0,
      'drive_backup_rev': ch.driveBackupRev,
      'drive_file_id': ch.driveFileId,
      'drive_file_url': ch.driveFileUrl,
      'drive_keys_url': ch.driveKeysUrl,
      'allow_mods_manage_drive_account':
          ch.allowModeratorsManageDriveAccount ? 1 : 0,
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
    unawaited(publishAccountChannelSubscriptions());
  }

  Future<void> unsubscribe(String channelId, String userId) async {
    final ch = await getChannel(channelId);
    if (ch == null) return;
    await updateChannel(ch.copyWith(
        subscriberIds: ch.subscriberIds.where((s) => s != userId).toList()));
    unawaited(publishAccountChannelSubscriptions());
  }

  /// Передача владения каналом (только текущий [adminId]).
  /// [newAdminId] должен быть в подписчиках. Бывший владелец остаётся в подписчиках.
  Future<Channel?> transferOwnership({
    required String channelId,
    required String newAdminId,
    required String currentAdminId,
  }) async {
    final ch = await getChannel(channelId);
    if (ch == null || ch.adminId != currentAdminId) return null;
    if (newAdminId == currentAdminId) return null;
    if (!ch.subscriberIds.contains(newAdminId)) return null;

    final subs = List<String>.from(ch.subscriberIds);
    if (!subs.contains(currentAdminId)) subs.add(currentAdminId);

    var mods = List<String>.from(ch.moderatorIds);
    mods.remove(newAdminId);
    mods.remove(currentAdminId);

    var links = List<String>.from(ch.linkAdminIds);
    links.remove(newAdminId);
    links.remove(currentAdminId);

    final staffLabels = Map<String, String>.from(ch.staffLabels);
    staffLabels.remove(newAdminId);

    final updated = ch.copyWith(
      adminId: newAdminId,
      subscriberIds: subs,
      moderatorIds: mods,
      linkAdminIds: links,
      staffLabels: staffLabels,
    );
    await updateChannel(updated);
    unawaited(updated.broadcastGossipMeta());
    unawaited(publishAccountChannelSubscriptions());
    return updated;
  }

  /// Каналы, где [userId] — подписчик или админ (для синхронизации аккаунта).
  Future<List<String>> subscribedChannelIdsForAccountSync(String userId) async {
    if (_db == null || userId.isEmpty) return [];
    final rows = await _db!.query('channels');
    final out = <String>[];
    for (final r in rows) {
      final ch = _channelFromRow(r);
      if (ch.adminId == userId || ch.subscriberIds.contains(userId)) {
        out.add(ch.id);
      }
    }
    return out;
  }

  /// Подписать на каналы из облачного снимка (канал уже должен быть в локальной БД).
  Future<void> mergeSubscriptionsFromSync(
      String userId, List<String> channelIds) async {
    var any = false;
    for (final id in channelIds.toSet()) {
      final ch = await getChannel(id);
      if (ch == null) continue;
      if (ch.adminId == userId || ch.subscriberIds.contains(userId)) continue;
      await updateChannel(
          ch.copyWith(subscriberIds: [...ch.subscriberIds, userId]));
      any = true;
    }
    if (any) _bump();
  }

  Future<void> incrementPostForwardCount(String postId) async {
    if (_db == null) return;
    await _db!.rawUpdate(
      'UPDATE channel_posts SET forward_count = COALESCE(forward_count, 0) + 1 WHERE id = ?',
      [postId],
    );
    _bump();
  }

  /// Посты и комментарии всех каналов (метаданные каналов остаются — можно запросить историю снова).
  Future<void> deleteAllPostsAndComments() async {
    if (_db == null) return;
    await _db!.delete('channel_post_viewers');
    await _db!.delete('channel_comments');
    await _db!.delete('channel_posts');
    await _db!.delete('channel_read_cursor');
    _bump();
  }

  Future<void> deleteChannel(String channelId) async {
    final existing = await getChannel(channelId);
    if (existing != null && existing.isPublic) {
      unawaited(ChannelDirectoryRelay.publishIfAdmin(
        existing.copyWith(isPublic: false),
      ));
    }
    final posts = await _db!.query('channel_posts',
        columns: ['id'], where: 'channel_id = ?', whereArgs: [channelId]);
    for (final post in posts) {
      await _db!.delete('channel_post_viewers',
          where: 'post_id = ?', whereArgs: [post['id']]);
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
    final updated = ch.copyWith(verified: true, verifiedBy: verifiedBy);
    await updateChannel(updated);
    if (updated.adminId == CryptoService.instance.publicKeyHex) {
      unawaited(updated.broadcastGossipMeta());
    }
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
      if (uc.isNotEmpty &&
          ch.universalCode.isNotEmpty &&
          ch.universalCode != uc) {
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

  /// Посты новее [sinceTs] в хронологическом порядке (для ответа на history_req).
  Future<List<ChannelPost>> getPostsNewerThan(
    String channelId,
    int sinceTs, {
    int limit = 300,
  }) async {
    if (_db == null) return [];
    final rows = await _db!.query(
      'channel_posts',
      where: 'channel_id = ? AND timestamp > ?',
      whereArgs: [channelId, sinceTs],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
    final posts = <ChannelPost>[];
    for (final r in rows) {
      final comments = await getComments(r['id'] as String);
      posts.add(ChannelPost.fromMap(r, comments: comments));
    }
    return posts;
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
    await _db!.delete('channel_post_viewers',
        where: 'post_id = ?', whereArgs: [postId]);
    await _db!.delete('channel_posts', where: 'id = ?', whereArgs: [postId]);
    await _db!
        .delete('channel_comments', where: 'post_id = ?', whereArgs: [postId]);
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
    await _db!
        .delete('channel_comments', where: 'id = ?', whereArgs: [commentId]);
    _bump();
  }

  /// Снимок постов и комментариев для шифрованного бэкапа (сырые поля БД, без resolve путей).
  Future<Map<String, dynamic>> buildChannelBackupSnapshot(
      String channelId) async {
    if (_db == null) throw StateError('ChannelService DB not initialized');
    final rows = await _db!.query(
      'channel_posts',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'timestamp ASC',
    );
    final posts = <Map<String, dynamic>>[];
    for (final r in rows) {
      final pid = r['id'] as String;
      final crows = await _db!.query(
        'channel_comments',
        where: 'post_id = ?',
        whereArgs: [pid],
        orderBy: 'timestamp ASC',
      );
      final postMap = Map<String, dynamic>.from(r);
      final postMedia = kIsWeb ? const <String, dynamic>{} : await _readRowMediaData(postMap);
      final commentsList = <Map<String, dynamic>>[];
      for (final c in crows) {
        final cm = Map<String, dynamic>.from(c);
        final commentMedia = kIsWeb ? const <String, dynamic>{} : await _readRowMediaData(cm);
        commentsList.add({...cm, ...commentMedia});
      }
      posts.add({
        'post': postMap,
        'comments': commentsList,
        ...postMedia,
      });
    }
    return {
      'v': 2,
      'type': 'rlink_channel_backup',
      'channelId': channelId,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'posts': posts,
    };
  }

  /// Читает медиафайлы поста/комментария и возвращает base64-данные для включения в снимок.
  Future<Map<String, dynamic>> _readRowMediaData(Map<String, dynamic> row) async {
    final result = <String, dynamic>{};
    await _attachMediaBytes(row, result, 'image_path', '_img', '_img_n');
    await _attachMediaBytes(row, result, 'video_path', '_vid', '_vid_n');
    await _attachMediaBytes(row, result, 'voice_path', '_voice', '_voice_n');
    await _attachMediaBytes(row, result, 'file_path', '_file', '_file_n');
    return result;
  }

  Future<void> _attachMediaBytes(Map<String, dynamic> row, Map<String, dynamic> out,
      String pathKey, String dataKey, String nameKey) async {
    final path = row[pathKey] as String?;
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();
      out[dataKey] = base64Encode(bytes);
      out[nameKey] = p.basename(path);
    } catch (e) {
      debugPrint('[RLINK][ChBak] skip media $path: $e');
    }
  }

  /// Слияние снимка в локальную БД: снимок полный — посты канала, которых нет в JSON, удаляются.
  /// Если снимок v2 — медиафайлы восстанавливаются из base64 прямо в Documents.
  Future<void> importChannelBackupSnapshot(
      String channelId, Map<String, dynamic> json) async {
    if (_db == null) return;
    final posts = json['posts'] as List<dynamic>?;
    if (posts == null) return;

    // Для v2 снимков — восстанавливаем медиафайлы ДО транзакции (IO вне TX).
    final restoredPostMedia = <String, Map<String, String>>{};
    final restoredCommentMedia = <String, Map<String, String>>{};
    if (!kIsWeb && (json['v'] as int? ?? 1) >= 2) {
      for (final item in posts) {
        final m = item as Map<String, dynamic>;
        final postId = (m['post'] as Map?)?['id'] as String?;
        if (postId != null) {
          restoredPostMedia[postId] = await _restoreRowMediaFiles(m);
        }
        final cl = m['comments'] as List<dynamic>? ?? const [];
        for (final c in cl) {
          final cm = c as Map<String, dynamic>;
          final cid = cm['id'] as String?;
          if (cid != null) {
            restoredCommentMedia[cid] = await _restoreRowMediaFiles(cm);
          }
        }
      }
    }

    await _db!.transaction((txn) async {
      final snapshotPostIds = <String>{};
      for (final item in posts) {
        final m = item as Map<String, dynamic>;
        final pmap = Map<String, dynamic>.from(m['post'] as Map);
        if (pmap['channel_id'] != channelId) continue;
        snapshotPostIds.add(pmap['id'] as String);
      }

      final localRows = await txn.query(
        'channel_posts',
        columns: ['id'],
        where: 'channel_id = ?',
        whereArgs: [channelId],
      );
      for (final r in localRows) {
        final id = r['id'] as String;
        if (!snapshotPostIds.contains(id)) {
          await txn.delete('channel_post_viewers',
              where: 'post_id = ?', whereArgs: [id]);
          await txn.delete('channel_comments',
              where: 'post_id = ?', whereArgs: [id]);
          await txn.delete('channel_posts', where: 'id = ?', whereArgs: [id]);
        }
      }

      for (final item in posts) {
        final m = item as Map<String, dynamic>;
        final pmap = Map<String, dynamic>.from(m['post'] as Map);
        if (pmap['channel_id'] != channelId) continue;
        final pid = pmap['id'] as String;
        // Применяем восстановленные пути медиа (v2) и убираем служебные поля.
        if (restoredPostMedia.containsKey(pid)) {
          pmap.addAll(restoredPostMedia[pid]!);
        }
        pmap.removeWhere((k, _) => k.startsWith('_'));
        await txn.insert(
          'channel_posts',
          pmap,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn
            .delete('channel_comments', where: 'post_id = ?', whereArgs: [pid]);
        final cl = m['comments'] as List<dynamic>? ?? const [];
        for (final c in cl) {
          final cm = Map<String, dynamic>.from(c as Map);
          final cid = cm['id'] as String?;
          if (cid != null && restoredCommentMedia.containsKey(cid)) {
            cm.addAll(restoredCommentMedia[cid]!);
          }
          // Убираем служебные поля перед записью в БД.
          cm.removeWhere((k, _) => k.startsWith('_'));
          await txn.insert(
            'channel_comments',
            cm,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });
    _bump();
  }

  /// Восстанавливает медиафайлы из base64-полей снимка, возвращает новые пути для DB.
  Future<Map<String, String>> _restoreRowMediaFiles(Map<String, dynamic> entry) async {
    final result = <String, String>{};
    final docsDir = await getApplicationDocumentsDirectory();
    await _restoreMediaField(entry, result, '_img', '_img_n', 'image_path',
        Directory(p.join(docsDir.path, 'images')));
    await _restoreMediaField(entry, result, '_vid', '_vid_n', 'video_path',
        Directory(p.join(docsDir.path, 'videos')));
    await _restoreMediaField(entry, result, '_voice', '_voice_n', 'voice_path',
        Directory(p.join(docsDir.path, 'voices')));
    await _restoreMediaField(entry, result, '_file', '_file_n', 'file_path',
        Directory(p.join(docsDir.path, 'files')));
    return result;
  }

  Future<void> _restoreMediaField(
    Map<String, dynamic> entry,
    Map<String, String> out,
    String dataKey,
    String nameKey,
    String pathKey,
    Directory dir,
  ) async {
    final data = entry[dataKey] as String?;
    if (data == null || data.isEmpty) return;
    try {
      final name = (entry[nameKey] as String?)?.isNotEmpty == true
          ? entry[nameKey] as String
          : _uuid.v4();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final filePath = p.join(dir.path, name);
      final file = File(filePath);
      if (!file.existsSync()) {
        await file.writeAsBytes(base64Decode(data));
      }
      out[pathKey] = filePath;
    } catch (e) {
      debugPrint('[RLINK][ChBak] restore media $pathKey failed: $e');
    }
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
    if (img == null && vid == null && vo == null && fp == null) {
      return;
    }
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
    final mergedImg = img ?? post.imagePath;
    final stickerFromName =
        mergedImg != null && p.basename(mergedImg).startsWith('stk_');
    await _db!.update(
      'channel_posts',
      {
        'image_path': mergedImg,
        'video_path': vid ?? post.videoPath,
        'voice_path': vo ?? post.voicePath,
        'file_path': fp ?? post.filePath,
        'file_name': fn ?? post.fileName,
        'file_size': fs ?? post.fileSize,
        'is_sticker': (post.isSticker || stickerFromName) ? 1 : 0,
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
        filePath == null) {
      return;
    }
    final post = await getPost(postId);
    if (post == null) {
      if (imagePath != null) _pendingPostImagePaths[postId] = imagePath;
      if (videoPath != null) _pendingPostVideoPaths[postId] = videoPath;
      if (voicePath != null) _pendingPostVoicePaths[postId] = voicePath;
      if (filePath != null) _pendingPostFilePaths[postId] = filePath;
      if (fileName != null) _pendingPostFileNames[postId] = fileName;
      if (fileSize != null) _pendingPostFileSizes[postId] = fileSize;
      return;
    }
    final mergedImg = imagePath ?? post.imagePath;
    final stickerFromName =
        mergedImg != null && p.basename(mergedImg).startsWith('stk_');
    await _db!.update(
      'channel_posts',
      {
        'image_path': mergedImg,
        'video_path': videoPath ?? post.videoPath,
        'voice_path': voicePath ?? post.voicePath,
        'file_path': filePath ?? post.filePath,
        'file_name': fileName ?? post.fileName,
        'file_size': fileSize ?? post.fileSize,
        'is_sticker': (post.isSticker || stickerFromName) ? 1 : 0,
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
    if (img == null && vid == null && vo == null && fp == null) {
      return;
    }
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
        filePath == null) {
      return;
    }
    final c = await getComment(commentId);
    if (c == null) {
      if (imagePath != null) {
        _pendingCommentImagePaths[commentId] = imagePath;
      }
      if (videoPath != null) {
        _pendingCommentVideoPaths[commentId] = videoPath;
      }
      if (voicePath != null) {
        _pendingCommentVoicePaths[commentId] = voicePath;
      }
      if (filePath != null) _pendingCommentFilePaths[commentId] = filePath;
      if (fileName != null) _pendingCommentFileNames[commentId] = fileName;
      if (fileSize != null) _pendingCommentFileSizes[commentId] = fileSize;
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
        isSticker: post.isSticker,
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
      final isSquareVideo = p.basename(vid).endsWith('_sq.mp4');
      await GossipRouter.instance.sendImgMeta(
        msgId: post.id,
        totalChunks: chunks.length,
        fromId: aid,
        isAvatar: false,
        isVideo: true,
        isSquare: isSquareVideo,
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
      final isSquareVideo = p.basename(vid).endsWith('_sq.mp4');
      await GossipRouter.instance.sendImgMeta(
        msgId: c.id,
        totalChunks: chunks.length,
        fromId: authorId,
        isAvatar: false,
        isVideo: true,
        isSquare: isSquareVideo,
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
    final list = updated[emoji];
    if (list != null && list.contains(reactorId)) {
      list.remove(reactorId);
      if (list.isEmpty) updated.remove(emoji);
    } else {
      if (!reactionAddAllowed(updated, emoji, reactorId)) return;
      updated.putIfAbsent(emoji, () => <String>[]).add(reactorId);
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
    final list = updated[emoji];
    if (list != null && list.contains(reactorId)) {
      list.remove(reactorId);
      if (list.isEmpty) updated.remove(emoji);
    } else {
      if (!reactionAddAllowed(updated, emoji, reactorId)) return;
      updated.putIfAbsent(emoji, () => <String>[]).add(reactorId);
    }
    await _db!.update(
      'channel_comments',
      {'reactions': updated.isEmpty ? null : jsonEncode(updated)},
      where: 'id = ?',
      whereArgs: [commentId],
    );
    _bump();
  }

  /// Учитывает просмотр поста [postId] пользователем [viewerId] (один раз на пару).
  /// При [rebroadcast] рассылает gossip, чтобы другие узлы увидели тот же счётчик.
  Future<void> recordPostView(String postId, String viewerId,
      {bool rebroadcast = true}) async {
    if (_db == null) return;
    if (viewerId.isEmpty) return;
    final postExists = await _db!.query(
      'channel_posts',
      columns: const ['id'],
      where: 'id = ?',
      whereArgs: [postId],
      limit: 1,
    );
    if (postExists.isEmpty) return;

    var inserted = false;
    await _db!.transaction((txn) async {
      final existing = await txn.query(
        'channel_post_viewers',
        columns: const ['post_id'],
        where: 'post_id = ? AND viewer_id = ?',
        whereArgs: [postId, viewerId],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      await txn.insert('channel_post_viewers', {
        'post_id': postId,
        'viewer_id': viewerId,
      });
      await txn.rawUpdate(
        'UPDATE channel_posts SET view_count = COALESCE(view_count, 0) + 1 WHERE id = ?',
        [postId],
      );
      inserted = true;
    });
    if (!inserted) return;
    _bump();
    if (rebroadcast) {
      for (var i = 0; i < 2; i++) {
        await GossipRouter.instance
            .sendChannelPostView(postId: postId, viewerId: viewerId);
        if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
      }
    }
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
    await _db?.delete('channel_post_viewers');
    await _db?.delete('channel_comments');
    await _db?.delete('channel_posts');
    await _db?.delete('channel_read_cursor');
    await _db?.delete('channels');
    await _db?.delete('verification_requests');
    pendingChannelInvites.value = [];
    pendingVerifications.value = [];
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
    final rows =
        await _db!.query('verification_requests', orderBy: 'requested_at DESC');
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

  /// Повторная рассылка аватара/баннера (новый подписчик мог пропустить старый broadcast).
  Future<void> rebroadcastChannelVisualAssets(Channel ch) async {
    final me = CryptoService.instance.publicKeyHex;
    if (me.isEmpty || ch.adminId != me) return;

    Future<void> send(String msgId, String? rawPath) async {
      if (rawPath == null) return;
      final rp = ImageService.instance.resolveStoredPath(rawPath);
      if (rp == null || !File(rp).existsSync()) return;
      final bytes = await File(rp).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      await GossipRouter.instance.sendImgMeta(
        msgId: msgId,
        totalChunks: chunks.length,
        fromId: me,
        isAvatar: false,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: msgId,
          index: i,
          base64Data: chunks[i],
          fromId: me,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }

    await send(channelAvatarBroadcastMsgId(ch.id), ch.avatarImagePath);
    await send(channelBannerBroadcastMsgId(ch.id), ch.bannerImagePath);
  }

  /// Вызывается при приходе gossip о новой подписке: устройство админа вновь шлёт обложки.
  Future<void> maybeRebroadcastChannelVisualsAfterRemoteSubscribe(
      String channelId) async {
    final me = CryptoService.instance.publicKeyHex;
    if (me.isEmpty) return;
    final ch = await getChannel(channelId);
    if (ch == null || ch.adminId != me) return;
    await rebroadcastChannelVisualAssets(ch);
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
