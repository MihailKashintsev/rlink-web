import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class StoryItem {
  final String id;
  final String authorId; // Ed25519 public key
  final String text;
  String? imagePath;
  String? videoPath; // local path to compressed video (if story has video)
  final int bgColor;
  final DateTime createdAt;
  bool viewed;
  // Text position in the story canvas (Alignment units: -1.0 to 1.0, 0=center)
  double textX;
  double textY;
  double textSize;
  // Emoji → list of reactor public keys. Хранится локально.
  Map<String, List<String>> reactions;
  // Viewer public key hexes (reported back from each viewer to the author).
  List<String> viewers;

  StoryItem({
    required this.id,
    required this.authorId,
    required this.text,
    this.imagePath,
    this.videoPath,
    required this.bgColor,
    required this.createdAt,
    this.viewed = false,
    this.textX = 0,
    this.textY = 0,
    this.textSize = 26,
    Map<String, List<String>>? reactions,
    List<String>? viewers,
  })  : reactions = reactions ?? <String, List<String>>{},
        viewers = viewers ?? <String>[];

  bool get isExpired =>
      DateTime.now().difference(createdAt).inHours >= 24;

  /// Суммарное число реакций (учитывает все эмодзи).
  int get totalReactions {
    var n = 0;
    for (final list in reactions.values) {
      n += list.length;
    }
    return n;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'text': text,
        'imagePath': imagePath,
        if (videoPath != null) 'videoPath': videoPath,
        'bgColor': bgColor,
        'createdAt': createdAt.toIso8601String(),
        'viewed': viewed,
        if (textX != 0) 'textX': textX,
        if (textY != 0) 'textY': textY,
        if (textSize != 26) 'textSize': textSize,
        if (reactions.isNotEmpty) 'reactions': reactions,
        if (viewers.isNotEmpty) 'viewers': viewers,
      };

  factory StoryItem.fromJson(Map<String, dynamic> j) {
    Map<String, List<String>> reactions = {};
    final raw = j['reactions'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is List) {
          reactions[k as String] = v.cast<String>();
        }
      });
    }
    final List<String> viewers = (j['viewers'] as List?)?.cast<String>() ?? [];
    return StoryItem(
      id: j['id'] as String,
      authorId: j['authorId'] as String,
      text: j['text'] as String? ?? '',
      imagePath: j['imagePath'] as String?,
      videoPath: j['videoPath'] as String?,
      bgColor: j['bgColor'] as int? ?? 0xFF6C5CE7,
      createdAt: DateTime.parse(j['createdAt'] as String),
      viewed: j['viewed'] as bool? ?? false,
      textX: (j['textX'] as num?)?.toDouble() ?? 0,
      textY: (j['textY'] as num?)?.toDouble() ?? 0,
      textSize: (j['textSize'] as num?)?.toDouble() ?? 26,
      reactions: reactions,
      viewers: viewers,
    );
  }
}

class StoryService {
  StoryService._();
  static final StoryService instance = StoryService._();

  // authorId → stories from the last 24 h
  final Map<String, List<StoryItem>> _stories = {};
  // storyId → pending image path (если картинка пришла раньше, чем сам story).
  final Map<String, String> _pendingImages = {};
  // storyId → pending video path (если видео пришло раньше, чем сам story).
  final Map<String, String> _pendingVideos = {};

  /// Fires whenever stories change
  final ValueNotifier<int> version = ValueNotifier(0);

  Future<void> init() async {
    await _load();
    _clearExpired();
  }

  List<StoryItem> storiesFor(String authorId) =>
      (_stories[authorId] ?? []).where((s) => !s.isExpired).toList();

  bool hasActiveStory(String authorId) => storiesFor(authorId).isNotEmpty;

  bool hasUnviewedStory(String authorId) =>
      storiesFor(authorId).any((s) => !s.viewed);

  /// Authors with at least one active story, sorted by most recent first
  List<String> get activeAuthors {
    final entries = _stories.entries
        .where((e) => e.value.any((s) => !s.isExpired))
        .toList();
    entries.sort((a, b) {
      final latestA = a.value
          .where((s) => !s.isExpired)
          .map((s) => s.createdAt)
          .reduce((x, y) => x.isAfter(y) ? x : y);
      final latestB = b.value
          .where((s) => !s.isExpired)
          .map((s) => s.createdAt)
          .reduce((x, y) => x.isAfter(y) ? x : y);
      return latestB.compareTo(latestA);
    });
    return entries.map((e) => e.key).toList();
  }

  void addStory(StoryItem story) {
    _clearExpired();
    final list = _stories.putIfAbsent(story.authorId, () => []);
    // Dedup: skip if story with this ID already exists
    if (list.any((s) => s.id == story.id)) return;
    list.add(story);
    // Keep at most 10 stories per author
    if (list.length > 10) list.removeRange(0, list.length - 10);
    // Если картинка/видео пришли раньше самого story — подцепляем их сейчас.
    final pendingImg = _pendingImages.remove(story.id);
    if (pendingImg != null && story.imagePath == null) {
      story.imagePath = pendingImg;
    }
    final pendingVid = _pendingVideos.remove(story.id);
    if (pendingVid != null && story.videoPath == null) {
      story.videoPath = pendingVid;
    }
    debugPrint('[Stories] Added story from ${story.authorId.substring(0, 16)}, total=${list.length}');
    version.value++;
    _save();
  }

  /// Запоминает путь к картинке для истории, которая ещё не дошла.
  void cachePendingImage(String storyId, String imagePath) {
    _pendingImages[storyId] = imagePath;
    // Если история уже есть — сразу применяем.
    final s = findStory(storyId);
    if (s != null && s.imagePath == null) {
      s.imagePath = imagePath;
      _pendingImages.remove(storyId);
      version.value++;
      _save();
    }
  }

  /// Запоминает путь к видео для истории, которая ещё не дошла.
  void cachePendingVideo(String storyId, String videoPath) {
    _pendingVideos[storyId] = videoPath;
    // Если история уже есть — сразу применяем.
    final s = findStory(storyId);
    if (s != null && s.videoPath == null) {
      s.videoPath = videoPath;
      _pendingVideos.remove(storyId);
      version.value++;
      _save();
    }
  }

  StoryItem? findStory(String storyId) {
    for (final list in _stories.values) {
      for (final s in list) {
        if (s.id == storyId) return s;
      }
    }
    return null;
  }

  void notifyUpdate() {
    version.value++;
    _save();
  }

  /// Переключает реакцию [emoji] от [reactorId] на истории [storyId].
  /// Возвращает обновлённый StoryItem или null если не найдено.
  StoryItem? toggleReaction(String storyId, String emoji, String reactorId) {
    final s = findStory(storyId);
    if (s == null) return null;
    final list = s.reactions.putIfAbsent(emoji, () => <String>[]);
    if (list.contains(reactorId)) {
      list.remove(reactorId);
      if (list.isEmpty) s.reactions.remove(emoji);
    } else {
      list.add(reactorId);
    }
    version.value++;
    _save();
    return s;
  }

  /// Применяет реакцию (set — не переключение) — для входящих пакетов.
  void applyIncomingReaction(String storyId, String emoji, String reactorId) {
    toggleReaction(storyId, emoji, reactorId);
  }

  /// Удаляет историю по [storyId] у автора [authorId].
  /// Возвращает true если история была найдена и удалена.
  bool deleteStory(String storyId, String authorId) {
    final list = _stories[authorId];
    if (list == null) return false;
    final before = list.length;
    list.removeWhere((s) => s.id == storyId);
    if (list.isEmpty) _stories.remove(authorId);
    if (list.length == before) return false;
    debugPrint('[Stories] Deleted story $storyId from $authorId');
    version.value++;
    _save();
    return true;
  }

  void markViewed(String authorId, String storyId) {
    final list = _stories[authorId];
    if (list == null) return;
    for (final s in list) {
      if (s.id == storyId) {
        s.viewed = true;
        break;
      }
    }
    version.value++;
    _save();
  }

  /// Registers a viewer public key for a story (called on author's device
  /// when a story_view gossip packet arrives from a viewer).
  void addViewer(String storyId, String viewerKey) {
    final s = findStory(storyId);
    if (s == null) return;
    if (!s.viewers.contains(viewerKey)) {
      s.viewers.add(viewerKey);
      version.value++;
      _save();
    }
  }

  /// Clears all in-memory stories and deletes the JSON file on disk.
  Future<void> reset() async {
    _stories.clear();
    _pendingImages.clear();
    version.value++;
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _clearExpired() {
    bool changed = false;
    for (final key in _stories.keys.toList()) {
      final before = _stories[key]!.length;
      _stories[key]!.removeWhere((s) => s.isExpired);
      if (_stories[key]!.isEmpty) _stories.remove(key);
      if ((_stories[key]?.length ?? 0) != before) changed = true;
    }
    if (changed) {
      version.value++;
      _save();
    }
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/rlink_stories.json');
  }

  Future<void> _save() async {
    try {
      final data = _stories.map(
        (k, v) => MapEntry(k, v.map((s) => s.toJson()).toList()),
      );
      final f = await _file();
      await f.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('[Stories] Save error: $e');
    }
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      for (final entry in raw.entries) {
        final list = (entry.value as List)
            .map((e) => StoryItem.fromJson(e as Map<String, dynamic>))
            .toList();
        _stories[entry.key] = list;
      }
      debugPrint('[Stories] Loaded ${_stories.length} author(s)');
    } catch (e) {
      debugPrint('[Stories] Load error: $e');
    }
  }
}
