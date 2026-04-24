import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/channel.dart';
import '../models/chat_message.dart';
import '../models/group.dart';
import '../services/image_service.dart';
import 'rlink_deep_link.dart';

class _ShareAttachment {
  final String rawPath;
  final String? fileName;

  const _ShareAttachment(this.rawPath, {this.fileName});
}

void _showShareSnack(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(text)),
  );
}

List<XFile> _collectExistingFiles(List<_ShareAttachment> attachments) {
  final out = <XFile>[];
  final seen = <String>{};
  for (final item in attachments) {
    final raw = item.rawPath.trim();
    if (raw.isEmpty) continue;
    final resolved = ImageService.instance.resolveStoredPath(raw) ?? raw;
    final f = File(resolved);
    if (!f.existsSync()) continue;
    final key = f.absolute.path;
    if (seen.contains(key)) continue;
    seen.add(key);
    final name = item.fileName?.trim();
    if (name != null && name.isNotEmpty) {
      out.add(XFile(key, name: name));
    } else {
      out.add(XFile(key));
    }
  }
  return out;
}

Future<void> _sharePayload(
  BuildContext context, {
  required String text,
  required List<_ShareAttachment> attachments,
  required String subject,
}) async {
  final trimmed = text.trim();
  final files = _collectExistingFiles(attachments);
  final hadAttachment = attachments.isNotEmpty;
  final shareOrigin = RlinkDeepLink.sharePositionOriginFromContext(context);

  try {
    if (files.isNotEmpty) {
      await Share.shareXFiles(
        files,
        text: trimmed.isNotEmpty ? trimmed : null,
        subject: subject,
        sharePositionOrigin: shareOrigin,
      );
      return;
    }
    if (trimmed.isNotEmpty) {
      await Share.share(
        trimmed,
        subject: subject,
        sharePositionOrigin: shareOrigin,
      );
      return;
    }
    if (!context.mounted) return;
    _showShareSnack(
      context,
      hadAttachment
          ? 'Локальные вложения недоступны для экспорта'
          : 'Нечего экспортировать',
    );
  } catch (_) {
    if (!context.mounted) return;
    _showShareSnack(context, 'Не удалось открыть меню «Поделиться»');
  }
}

Future<void> shareChatMessageExternally(
  BuildContext context,
  ChatMessage msg,
) {
  final attachments = <_ShareAttachment>[
    if (msg.imagePath != null) _ShareAttachment(msg.imagePath!),
    if (msg.videoPath != null) _ShareAttachment(msg.videoPath!),
    if (msg.voicePath != null) _ShareAttachment(msg.voicePath!),
    if (msg.filePath != null)
      _ShareAttachment(msg.filePath!, fileName: msg.fileName),
  ];
  return _sharePayload(
    context,
    text: msg.text,
    attachments: attachments,
    subject: 'Rlink: сообщение',
  );
}

Future<void> shareGroupMessageExternally(
  BuildContext context,
  GroupMessage msg,
) {
  final attachments = <_ShareAttachment>[
    if (msg.imagePath != null) _ShareAttachment(msg.imagePath!),
    if (msg.videoPath != null) _ShareAttachment(msg.videoPath!),
    if (msg.voicePath != null) _ShareAttachment(msg.voicePath!),
  ];
  return _sharePayload(
    context,
    text: msg.text,
    attachments: attachments,
    subject: 'Rlink: сообщение из группы',
  );
}

Future<void> shareChannelPostExternally(
  BuildContext context,
  ChannelPost post,
) {
  final attachments = <_ShareAttachment>[
    if (post.imagePath != null) _ShareAttachment(post.imagePath!),
    if (post.videoPath != null) _ShareAttachment(post.videoPath!),
    if (post.voicePath != null) _ShareAttachment(post.voicePath!),
    if (post.filePath != null)
      _ShareAttachment(post.filePath!, fileName: post.fileName),
  ];
  return _sharePayload(
    context,
    text: post.text,
    attachments: attachments,
    subject: 'Rlink: пост канала',
  );
}

Future<void> shareChannelCommentExternally(
  BuildContext context,
  ChannelComment comment,
) {
  final attachments = <_ShareAttachment>[
    if (comment.imagePath != null) _ShareAttachment(comment.imagePath!),
    if (comment.videoPath != null) _ShareAttachment(comment.videoPath!),
    if (comment.voicePath != null) _ShareAttachment(comment.voicePath!),
    if (comment.filePath != null)
      _ShareAttachment(comment.filePath!, fileName: comment.fileName),
  ];
  return _sharePayload(
    context,
    text: comment.text,
    attachments: attachments,
    subject: 'Rlink: комментарий канала',
  );
}
