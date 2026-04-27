import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'group_service.dart';
import 'image_service.dart';
import 'runtime_platform.dart';
import 'story_service.dart';

/// Один сегмент круговой диаграммы «Данные».
class AppStorageSegment {
  final String id;
  final String title;
  final String subtitle;
  final int bytes;
  final int argbColor;

  const AppStorageSegment({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.bytes,
    required this.argbColor,
  });
}

class AppStorageBreakdown {
  final List<AppStorageSegment> segments;
  final int totalBytes;
  final bool isWebPlaceholder;

  const AppStorageBreakdown({
    required this.segments,
    required this.totalBytes,
    this.isWebPlaceholder = false,
  });

  static AppStorageBreakdown web() {
    return const AppStorageBreakdown(
      segments: [],
      totalBytes: 0,
      isWebPlaceholder: true,
    );
  }
}

Future<int> _statOne(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) return await f.length();
  } catch (_) {}
  return 0;
}

Future<int> _sqliteBundleBytes(String basePath) async {
  var n = await _statOne(basePath);
  n += await _statOne('$basePath-wal');
  n += await _statOne('$basePath-shm');
  return n;
}

Future<int> _documentsDirTotalBytes(Directory root) async {
  var n = 0;
  try {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          n += await entity.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return n;
}

/// Сканирование локального хранилища для экрана «Данные».
Future<AppStorageBreakdown> scanAppStorageBreakdown() async {
  if (kIsWeb || RuntimePlatform.isWeb) {
    return AppStorageBreakdown.web();
  }

  final dir = await getApplicationDocumentsDirectory();
  final docRoot = dir.path;

  final rlinkDb = p.join(docRoot, 'rlink.db');
  final groupsDb = p.join(docRoot, 'groups.db');
  final channelsDb = p.join(docRoot, 'channels.db');
  final outboxDb = p.join(docRoot, 'outbox_broadcast.db');
  final uploadDb = p.join(await getDatabasesPath(), 'rlink_upload_queue.db');

  final dbRlink = await _sqliteBundleBytes(rlinkDb);
  final dbGroups = await _sqliteBundleBytes(groupsDb);
  final dbChannels = await _sqliteBundleBytes(channelsDb);
  final dbOutbox = await _sqliteBundleBytes(outboxDb);
  final dbUpload = await _sqliteBundleBytes(uploadDb);
  final databasesTotal =
      dbRlink + dbGroups + dbChannels + dbOutbox + dbUpload;

  final dm = ChatStorageService.instance;
  final grp = GroupService.instance;
  final ch = ChannelService.instance;

  final imgDm = await dm.sumDistinctMessageMediaBytes('image_path');
  final vidDm = await dm.sumDistinctMessageMediaBytes('video_path');
  final voiceDm = await dm.sumDistinctMessageMediaBytes('voice_path');
  final fileDm = await dm.sumDistinctMessageMediaBytes('file_path');

  final imgGr = await grp.sumDistinctGroupMediaBytes('image_path');
  final vidGr = await grp.sumDistinctGroupMediaBytes('video_path');
  final voiceGr = await grp.sumDistinctGroupMediaBytes('voice_path');

  final imgCh = await ch.sumDistinctChannelMediaBytes('image_path');
  final vidCh = await ch.sumDistinctChannelMediaBytes('video_path');
  final voiceCh = await ch.sumDistinctChannelMediaBytes('voice_path');
  final fileCh = await ch.sumDistinctChannelMediaBytes('file_path');

  final imagesTotal = imgDm + imgGr + imgCh;
  final videoTotal = vidDm + vidGr + vidCh;
  final voiceTotal = voiceDm + voiceGr + voiceCh;
  final filesTotal = fileDm + fileCh;

  final storiesFile = File(p.join(docRoot, 'rlink_stories.json'));
  var storiesJson = 0;
  var storiesMedia = 0;
  final storyPaths = <String>{};
  if (await storiesFile.exists()) {
    storiesJson = await storiesFile.length();
    try {
      final raw = jsonDecode(await storiesFile.readAsString()) as Map<String, dynamic>;
      for (final entry in raw.entries) {
        final list = entry.value;
        if (list is! List) continue;
        for (final item in list) {
          if (item is! Map) continue;
          final s = StoryItem.fromJson(Map<String, dynamic>.from(item));
          for (final path in [s.imagePath, s.videoPath]) {
            if (path == null || path.isEmpty || path.startsWith('data:')) {
              continue;
            }
            final resolved =
                ImageService.instance.resolveStoredPath(path) ?? path;
            if (storyPaths.contains(resolved)) continue;
            storyPaths.add(resolved);
            try {
              final f = File(resolved);
              if (await f.exists()) storiesMedia += await f.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
  final storiesTotal = storiesJson + storiesMedia;

  final mediaTotal = imagesTotal + videoTotal + voiceTotal + filesTotal;
  final accountedForWalk =
      databasesTotal + mediaTotal + storiesTotal;

  final walkTotal = await _documentsDirTotalBytes(Directory(docRoot));
  final otherTotal = (walkTotal - accountedForWalk).clamp(0, 1 << 62);

  const cDb = 0xFF607D8B;
  const cImg = 0xFFE91E63;
  const cVid = 0xFF9C27B0;
  const cVoice = 0xFF00BCD4;
  const cFile = 0xFFFF9800;
  const cStory = 0xFF4CAF50;
  const cOther = 0xFF9E9E9E;

  final segments = <AppStorageSegment>[
    AppStorageSegment(
      id: 'databases',
      title: 'Базы SQLite',
      subtitle:
          'Личные чаты, группы, каналы, очередь загрузок, outbox — ${_fmtMb(databasesTotal)}',
      bytes: databasesTotal,
      argbColor: cDb,
    ),
    AppStorageSegment(
      id: 'images',
      title: 'Изображения',
      subtitle: 'ЛС, группы, каналы — ${_fmtMb(imagesTotal)}',
      bytes: imagesTotal,
      argbColor: cImg,
    ),
    AppStorageSegment(
      id: 'video',
      title: 'Видео',
      subtitle: 'ЛС, группы, каналы — ${_fmtMb(videoTotal)}',
      bytes: videoTotal,
      argbColor: cVid,
    ),
    AppStorageSegment(
      id: 'voice',
      title: 'Аудио / голос',
      subtitle: 'ЛС, группы, каналы — ${_fmtMb(voiceTotal)}',
      bytes: voiceTotal,
      argbColor: cVoice,
    ),
    AppStorageSegment(
      id: 'files',
      title: 'Файлы',
      subtitle: 'Вложения в ЛС и каналах — ${_fmtMb(filesTotal)}',
      bytes: filesTotal,
      argbColor: cFile,
    ),
    AppStorageSegment(
      id: 'stories',
      title: 'Истории',
      subtitle: 'JSON и медиа — ${_fmtMb(storiesTotal)}',
      bytes: storiesTotal,
      argbColor: cStory,
    ),
    AppStorageSegment(
      id: 'other',
      title: 'Прочее',
      subtitle: 'Аватары, фоны, кэш в папке приложения — ${_fmtMb(otherTotal)}',
      bytes: otherTotal,
      argbColor: cOther,
    ),
  ];

  final total = segments.fold<int>(0, (a, s) => a + s.bytes);

  return AppStorageBreakdown(segments: segments, totalBytes: total);
}

String _fmtMb(int bytes) {
  if (bytes <= 0) return '0 МБ';
  final mb = bytes / (1024 * 1024);
  if (mb < 0.01) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  return '${mb.toStringAsFixed(2)} МБ';
}

/// Очистка по идентификатору сегмента (см. [AppStorageSegment.id]).
Future<void> clearStorageSegment(
  String id, {
  required void Function(String message) onMessage,
}) async {
  switch (id) {
    case 'images':
      await ChatStorageService.instance.clearAllMessageMediaColumn('image_path');
      await GroupService.instance.clearAllGroupMessagesMediaColumn('image_path');
      await ChannelService.instance.clearAllChannelMediaColumn('image_path');
      onMessage('Изображения удалены из базы и с диска');
      return;
    case 'video':
      await ChatStorageService.instance.clearAllMessageMediaColumn('video_path');
      await GroupService.instance.clearAllGroupMessagesMediaColumn('video_path');
      await ChannelService.instance.clearAllChannelMediaColumn('video_path');
      onMessage('Видео удалены');
      return;
    case 'voice':
      await ChatStorageService.instance.clearAllMessageMediaColumn('voice_path');
      await GroupService.instance.clearAllGroupMessagesMediaColumn('voice_path');
      await ChannelService.instance.clearAllChannelMediaColumn('voice_path');
      onMessage('Аудио удалены');
      return;
    case 'files':
      await ChatStorageService.instance.clearAllMessageMediaColumn('file_path');
      await ChannelService.instance.clearAllChannelMediaColumn('file_path');
      onMessage('Файлы-вложения удалены');
      return;
    case 'stories':
      await StoryService.instance.reset();
      onMessage('Истории очищены');
      return;
    case 'databases':
      throw UnsupportedError('databases');
    case 'other':
      throw UnsupportedError('other');
    default:
      throw ArgumentError(id);
  }
}
