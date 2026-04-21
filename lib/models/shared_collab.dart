import 'dart:convert';

import 'chat_message.dart';
import 'group.dart';

/// Префикс структурированных сообщений (список дел / событие) в поле `text`.
const String kRlinkCollabPrefix = '__RLINK_COLLAB_v1__';

class SharedTodoItem {
  final String id;
  final String text;
  final bool done;

  const SharedTodoItem({
    required this.id,
    required this.text,
    this.done = false,
  });

  factory SharedTodoItem.fromJson(Map<String, dynamic> j) => SharedTodoItem(
        id: j['id'] as String? ?? '',
        text: j['t'] as String? ?? '',
        done: j['d'] == true || j['d'] == 1,
      );

  Map<String, dynamic> toJson() => {'id': id, 't': text, 'd': done};

  SharedTodoItem copyWith({String? text, bool? done}) => SharedTodoItem(
        id: id,
        text: text ?? this.text,
        done: done ?? this.done,
      );
}

class SharedTodoPayload {
  final int ver;
  final String title;
  final List<SharedTodoItem> items;

  const SharedTodoPayload({
    required this.ver,
    required this.title,
    required this.items,
  });

  static bool isPayload(String? s) {
    if (s == null || s.isEmpty) return false;
    return s.startsWith(kRlinkCollabPrefix);
  }

  static SharedTodoPayload? tryDecode(String? s) {
    if (!isPayload(s)) return null;
    try {
      final j =
          jsonDecode(s!.substring(kRlinkCollabPrefix.length)) as Map<String, dynamic>;
      if (j['k'] != 'todo') return null;
      final raw = j['items'] as List<dynamic>? ?? const [];
      final items = raw
          .map((e) => SharedTodoItem.fromJson(e as Map<String, dynamic>))
          .where((e) => e.id.isNotEmpty)
          .toList();
      return SharedTodoPayload(
        ver: (j['v'] as num?)?.toInt() ?? 0,
        title: j['title'] as String? ?? '',
        items: items,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => kRlinkCollabPrefix +
      jsonEncode({
        'k': 'todo',
        'v': ver,
        'title': title,
        'items': items.map((e) => e.toJson()).toList(),
      });

  SharedTodoPayload withToggled(String itemId) {
    final next = items
        .map((e) => e.id == itemId ? e.copyWith(done: !e.done) : e)
        .toList();
    return SharedTodoPayload(ver: ver + 1, title: title, items: next);
  }

  /// При синхронизации из сети оставляем документ с большей версией.
  static String mergeRemote(String localText, String remoteText) {
    final a = tryDecode(localText);
    final b = tryDecode(remoteText);
    if (a == null) return remoteText;
    if (b == null) return localText;
    return b.ver >= a.ver ? remoteText : localText;
  }
}

class SharedCalendarPayload {
  final int ver;
  final String title;
  final int startMs;
  final String? note;

  const SharedCalendarPayload({
    required this.ver,
    required this.title,
    required this.startMs,
    this.note,
  });

  static bool isPayload(String? s) {
    if (s == null || s.isEmpty) return false;
    return s.startsWith(kRlinkCollabPrefix);
  }

  static SharedCalendarPayload? tryDecode(String? s) {
    if (!isPayload(s)) return null;
    try {
      final j =
          jsonDecode(s!.substring(kRlinkCollabPrefix.length)) as Map<String, dynamic>;
      if (j['k'] != 'cal') return null;
      return SharedCalendarPayload(
        ver: (j['v'] as num?)?.toInt() ?? 0,
        title: j['title'] as String? ?? '',
        startMs: (j['start'] as num?)?.toInt() ?? 0,
        note: j['note'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => kRlinkCollabPrefix +
      jsonEncode({
        'k': 'cal',
        'v': ver,
        'title': title,
        'start': startMs,
        if (note != null && note!.isNotEmpty) 'note': note,
      });

  static String mergeRemote(String localText, String remoteText) {
    final a = tryDecode(localText);
    final b = tryDecode(remoteText);
    if (a == null) return remoteText;
    if (b == null) return localText;
    return b.ver >= a.ver ? remoteText : localText;
  }

  /// События из списка сообщений личного чата (для экрана «календарь чата»).
  static List<SharedCalendarPayload> collectFromChatMessages(
      Iterable<ChatMessage> msgs) {
    final out = <SharedCalendarPayload>[];
    for (final m in msgs) {
      final c = tryDecode(m.text);
      if (c != null && c.startMs > 0) out.add(c);
    }
    out.sort((a, b) => a.startMs.compareTo(b.startMs));
    return out;
  }

  static List<SharedCalendarPayload> collectFromGroupMessages(
      Iterable<GroupMessage> msgs) {
    final out = <SharedCalendarPayload>[];
    for (final m in msgs) {
      final c = tryDecode(m.text);
      if (c != null && c.startMs > 0) out.add(c);
    }
    out.sort((a, b) => a.startMs.compareTo(b.startMs));
    return out;
  }
}
