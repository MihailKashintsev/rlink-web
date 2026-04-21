import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../../models/chat_message.dart';
import '../../models/group.dart';
import '../../models/message_poll.dart';
import '../../models/shared_collab.dart';
import '../../services/image_service.dart';

bool _hasLocalFile(String? storedPath) {
  final r = ImageService.instance.resolveStoredPath(storedPath);
  return r != null && File(r).existsSync();
}

/// Подписи к медиа, которые остаются в БД после «только медиа».
bool isSyntheticMediaCaption(String t) =>
    t == '🎤 Голосовое' ||
    t == '📹 Видео' ||
    t == '⬛ Видео' ||
    t == '📷' ||
    t.startsWith('📎 ') ||
    t.isEmpty;

bool dmMessageMissingLocalMedia(ChatMessage msg) {
  if (_hasLocalFile(msg.imagePath) ||
      _hasLocalFile(msg.videoPath) ||
      _hasLocalFile(msg.voicePath) ||
      _hasLocalFile(msg.filePath)) {
    return false;
  }
  if (msg.replyToMessageId != null) return false;
  if (msg.latitude != null) return false;
  if (SharedTodoPayload.tryDecode(msg.text) != null) return false;
  if (SharedCalendarPayload.tryDecode(msg.text) != null) return false;
  return isSyntheticMediaCaption(msg.text);
}

bool groupMessageMissingLocalMedia(GroupMessage msg) {
  if (_hasLocalFile(msg.imagePath) ||
      _hasLocalFile(msg.videoPath) ||
      _hasLocalFile(msg.voicePath)) {
    return false;
  }
  if (SharedTodoPayload.tryDecode(msg.text) != null) return false;
  if (SharedCalendarPayload.tryDecode(msg.text) != null) return false;
  if (MessagePoll.tryDecode(msg.pollJson ?? '') != null) return false;
  return isSyntheticMediaCaption(msg.text);
}

bool channelPostMissingLocalMedia(ChannelPost post) {
  if (_hasLocalFile(post.imagePath) ||
      _hasLocalFile(post.videoPath) ||
      _hasLocalFile(post.voicePath) ||
      _hasLocalFile(post.filePath)) {
    return false;
  }
  if (MessagePoll.tryDecode(post.pollJson ?? '') != null) return false;
  return isSyntheticMediaCaption(post.text);
}

bool channelCommentMissingLocalMedia(ChannelComment c) {
  if (_hasLocalFile(c.imagePath) ||
      _hasLocalFile(c.videoPath) ||
      _hasLocalFile(c.voicePath) ||
      _hasLocalFile(c.filePath)) {
    return false;
  }
  return isSyntheticMediaCaption(c.text);
}

/// Кнопка на месте удалённого из кэша вложения.
class ClearedMediaPlaceholder extends StatelessWidget {
  final bool isOutgoing;
  /// Личный чат: для входящих — «от собеседника».
  final bool isDirectChat;
  final ColorScheme colorScheme;
  final VoidCallback onPressed;

  const ClearedMediaPlaceholder({
    super.key,
    required this.isOutgoing,
    required this.isDirectChat,
    required this.colorScheme,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isOutgoing ? colorScheme.onPrimary : colorScheme.primary;
    final label = (isDirectChat && !isOutgoing)
        ? 'Загрузить от собеседника'
        : 'Загрузить';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(Icons.cloud_download_outlined, size: 18, color: fg),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: fg,
            side: BorderSide(color: fg.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }
}
