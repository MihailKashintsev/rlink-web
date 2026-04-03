import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class StoryItem {
  final String id;
  final String authorId; // Ed25519 public key
  final String text;
  String? imagePath;
  final int bgColor;
  final DateTime createdAt;
  bool viewed;

  StoryItem({
    required this.id,
    required this.authorId,
    required this.text,
    this.imagePath,
    required this.bgColor,
    required this.createdAt,
    this.viewed = false,
  });

  bool get isExpired =>
      DateTime.now().difference(createdAt).inHours >= 24;

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'text': text,
        'imagePath': imagePath,
        'bgColor': bgColor,
        'createdAt': createdAt.toIso8601String(),
        'viewed': viewed,
      };

  factory StoryItem.fromJson(Map<String, dynamic> j) => StoryItem(
        id: j['id'] as String,
        authorId: j['authorId'] as String,
        text: j['text'] as String? ?? '',
        imagePath: j['imagePath'] as String?,
        bgColor: j['bgColor'] as int? ?? 0xFF6C5CE7,
        createdAt: DateTime.parse(j['createdAt'] as String),
        viewed: j['viewed'] as bool? ?? false,
      );
}

class StoryService {
  StoryService._();
  static final StoryService instance = StoryService._();

  // authorId → stories from the last 24 h
  final Map<String, List<StoryItem>> _stories = {};

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
    debugPrint('[Stories] Added story from ${story.authorId.substring(0, 16)}, total=${list.length}');
    version.value++;
    _save();
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
