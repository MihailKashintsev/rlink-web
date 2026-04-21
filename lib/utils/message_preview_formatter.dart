import '../models/channel.dart';
import '../models/group.dart';
import '../models/message_poll.dart';
import '../models/shared_collab.dart';

/// Человекочитаемое превью последнего сообщения (список чатов и т.п.).
String formatMessagePreview(String? text, {String? pollJson}) {
  final p = MessagePoll.tryDecode(pollJson ?? '');
  if (p != null) {
    final q = p.question.trim();
    return q.isEmpty ? '📊 Опрос' : '📊 $q';
  }
  if (text == null || text.isEmpty) return '';

  final todo = SharedTodoPayload.tryDecode(text);
  if (todo != null) {
    final title = todo.title.trim();
    final head = title.isEmpty ? 'Список задач' : title;
    final n = todo.items.length;
    return '📋 $head${n > 0 ? ' · $n п.' : ''}';
  }

  final cal = SharedCalendarPayload.tryDecode(text);
  if (cal != null) {
    final title = cal.title.trim();
    return title.isEmpty ? '📅 Событие' : '📅 $title';
  }

  if (text == '📷' || text == '📷 Фото') return '📷 Фото';
  if (text == '🎤 Голосовое') return '🎤 Голосовое';
  if (text == '📹 Видео' || text == '⬛ Видео') return text;
  if (text.startsWith('📎 ')) return text;

  return text;
}

/// Превью последнего сообщения группы (учёт медиа без текста).
String formatGroupMessagePreview(GroupMessage m) {
  final t = formatMessagePreview(m.text, pollJson: m.pollJson);
  if (t.isNotEmpty) return t;
  final img = m.imagePath;
  if (img != null && img.isNotEmpty) {
    return img.toLowerCase().endsWith('.gif') ? '🎞 GIF' : '📷 Фото';
  }
  if (m.voicePath != null && m.voicePath!.isNotEmpty) return '🎤 Голосовое';
  if (m.videoPath != null && m.videoPath!.isNotEmpty) return '📹 Видео';
  return 'Сообщение';
}

/// Превью последнего поста канала.
String formatChannelPostPreview(ChannelPost p) {
  final t = formatMessagePreview(p.text, pollJson: p.pollJson);
  if (t.isNotEmpty) return t;
  final img = p.imagePath;
  if (img != null && img.isNotEmpty) {
    return img.toLowerCase().endsWith('.gif') ? '🎞 GIF' : '📷 Фото';
  }
  if (p.voicePath != null && p.voicePath!.isNotEmpty) return '🎤 Голосовое';
  if (p.videoPath != null && p.videoPath!.isNotEmpty) return '📹 Видео';
  if (p.filePath != null && p.filePath!.isNotEmpty) return '📎 Файл';
  return 'Пост';
}
