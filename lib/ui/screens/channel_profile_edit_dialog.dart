import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../../services/channel_backup_service.dart';
import '../../services/channel_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../widgets/desktop_image_picker.dart';

const _accentColors = [
  0xFF42A5F5,
  0xFF66BB6A,
  0xFFEF5350,
  0xFFAB47BC,
  0xFFFFA726,
  0xFF26C6DA,
  0xFFEC407A,
  0xFF8D6E63,
  0xFF78909C,
];

Future<void> _broadcastVisualAssetBytes({
  required String msgId,
  required Uint8List rawFileBytes,
  required String fromId,
}) async {
  final chunks = ImageService.instance.splitToBase64Chunks(rawFileBytes);
  await GossipRouter.instance.sendImgMeta(
    msgId: msgId,
    totalChunks: chunks.length,
    fromId: fromId,
    isAvatar: false,
  );
  for (var i = 0; i < chunks.length; i++) {
    await GossipRouter.instance.sendImgChunk(
      msgId: msgId,
      index: i,
      base64Data: chunks[i],
      fromId: fromId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Рассылка новых аватара/баннера канала после сохранения профиля.
Future<void> syncChannelVisualsAfterEdit({
  required Channel updated,
  required String? prevAvatarPath,
  required String? prevBannerPath,
  required String gossipFromId,
}) async {
  if (updated.avatarImagePath != prevAvatarPath &&
      updated.avatarImagePath != null) {
    final rp = ImageService.instance.resolveStoredPath(updated.avatarImagePath);
    if (rp != null && File(rp).existsSync()) {
      final bytes = await File(rp).readAsBytes();
      await _broadcastVisualAssetBytes(
        msgId: ChannelService.channelAvatarBroadcastMsgId(updated.id),
        rawFileBytes: bytes,
        fromId: gossipFromId,
      );
    }
  }
  if (updated.bannerImagePath != prevBannerPath &&
      updated.bannerImagePath != null) {
    final rp = ImageService.instance.resolveStoredPath(updated.bannerImagePath);
    if (rp != null && File(rp).existsSync()) {
      final bytes = await File(rp).readAsBytes();
      await _broadcastVisualAssetBytes(
        msgId: ChannelService.channelBannerBroadcastMsgId(updated.id),
        rawFileBytes: bytes,
        fromId: gossipFromId,
      );
    }
  }
}

/// [showPolicyToggles]: полные настройки (комментарии, публичность) — только владелец.
Future<void> showChannelProfileEditDialog(
  BuildContext context, {
  required Channel channel,
  required bool showPolicyToggles,
  required String myId,
  required void Function(Channel updated) onChannelUpdated,
}) async {
  final nameCtrl = TextEditingController(text: channel.name);
  final descCtrl = TextEditingController(text: channel.description ?? '');
  final emojiCtrl = TextEditingController(text: channel.avatarEmoji);
  String? pickedImagePath = channel.avatarImagePath;
  String? pickedBannerPath = channel.bannerImagePath;
  int pickedColor = channel.avatarColor;
  bool commentsEnabled = channel.commentsEnabled;
  bool isPublic = channel.isPublic;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Настройки канала'),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          content: Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: () async {
                        final raw = await pickImagePathDesktopAware();
                        if (raw == null) return;
                        final saved =
                            await ImageService.instance.compressAndSave(
                          raw,
                          isAvatar: true,
                        );
                        if (!ctx.mounted) return;
                        setDialogState(() => pickedImagePath = saved);
                      },
                      child: CircleAvatar(
                        radius: 36,
                        backgroundColor: Color(pickedColor),
                        backgroundImage: () {
                          if (pickedImagePath == null) return null;
                          final rp = ImageService.instance
                              .resolveStoredPath(pickedImagePath);
                          if (rp != null && File(rp).existsSync()) {
                            return FileImage(File(rp));
                          }
                          return null;
                        }(),
                        child: () {
                          if (pickedImagePath == null) {
                            return Text(
                                emojiCtrl.text.isEmpty ? '📢' : emojiCtrl.text,
                                style: const TextStyle(fontSize: 28));
                          }
                          final rp = ImageService.instance
                              .resolveStoredPath(pickedImagePath);
                          if (rp != null && File(rp).existsSync()) {
                            return null;
                          }
                          return Text(
                              emojiCtrl.text.isEmpty ? '📢' : emojiCtrl.text,
                              style: const TextStyle(fontSize: 28));
                        }(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Баннер профиля',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: GestureDetector(
                      onTap: () async {
                        final raw = await pickImagePathDesktopAware();
                        if (raw == null) return;
                        final saved =
                            await ImageService.instance.compressAndSave(
                          raw,
                          isAvatar: false,
                          maxSize: 1200,
                          quality: 82,
                        );
                        if (!ctx.mounted) return;
                        setDialogState(() => pickedBannerPath = saved);
                      },
                      child: SizedBox(
                        width: math.min(MediaQuery.sizeOf(ctx).width - 48, 520),
                        height: 100,
                        child: ColoredBox(
                          color: cs.surfaceContainerHighest,
                          child: pickedBannerPath == null
                              ? Center(
                                  child: Text(
                                    'Нажмите, чтобы выбрать баннер',
                                    style:
                                        TextStyle(color: cs.onSurfaceVariant),
                                  ),
                                )
                              : Builder(builder: (_) {
                                  final bp = ImageService.instance
                                      .resolveStoredPath(pickedBannerPath);
                                  if (bp != null && File(bp).existsSync()) {
                                    return Image.file(
                                      File(bp),
                                      fit: BoxFit.cover,
                                      width: math.min(
                                          MediaQuery.sizeOf(ctx).width - 48,
                                          520),
                                      height: 100,
                                      errorBuilder: (_, __, ___) => Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    );
                                  }
                                  return Center(
                                    child: Icon(
                                        Icons.add_photo_alternate_outlined,
                                        color: cs.onSurfaceVariant),
                                  );
                                }),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () =>
                          setDialogState(() => pickedBannerPath = null),
                      child: const Text('Убрать баннер'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    maxLength: 30,
                    autofocus: false,
                    decoration: const InputDecoration(
                      labelText: 'Название канала',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.drive_file_rename_outline),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: descCtrl,
                    maxLength: 200,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Описание',
                      hintText: 'Краткое описание канала...',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.info_outline),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emojiCtrl,
                    maxLength: 2,
                    decoration: const InputDecoration(
                      labelText: 'Эмодзи',
                      hintText: '📢',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.emoji_emotions_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Цвет канала',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _accentColors.map((c) {
                      final sel = c == pickedColor;
                      return GestureDetector(
                        onTap: () => setDialogState(() => pickedColor = c),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: sel
                                ? Border.all(color: cs.onSurface, width: 2.5)
                                : null,
                          ),
                          child: sel
                              ? const Icon(Icons.check,
                                  color: Colors.white, size: 16)
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                  if (showPolicyToggles) ...[
                    const SizedBox(height: 12),
                    SwitchListTile(
                      value: commentsEnabled,
                      onChanged: (v) =>
                          setDialogState(() => commentsEnabled = v),
                      title: const Text('Комментарии'),
                      subtitle: const Text(
                        'Подписчики могут комментировать посты',
                        style: TextStyle(fontSize: 12),
                      ),
                      secondary: const Icon(Icons.comment_outlined),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    SwitchListTile(
                      value: isPublic,
                      onChanged: (v) => setDialogState(() => isPublic = v),
                      title: const Text('Публичный канал'),
                      subtitle: Text(
                        isPublic
                            ? 'Найдётся в поиске'
                            : 'Скрытый — только по прямой ссылке',
                        style: const TextStyle(fontSize: 12),
                      ),
                      secondary:
                          Icon(isPublic ? Icons.public : Icons.lock_outline),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    ListTile(
                      leading: const Icon(Icons.sync),
                      title: const Text('Синхронизировать историю сейчас'),
                      subtitle: const Text(
                        'Сохранить настройки и разослать снимок подписчикам',
                        style: TextStyle(fontSize: 12),
                      ),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      onTap: () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        final prevAvatar = channel.avatarImagePath;
                        final prevBanner = channel.bannerImagePath;
                        final updated = channel.copyWith(
                          name: name,
                          description: descCtrl.text.trim().isEmpty
                              ? null
                              : descCtrl.text.trim(),
                          avatarEmoji: emojiCtrl.text.trim().isEmpty
                              ? channel.avatarEmoji
                              : emojiCtrl.text.trim(),
                          avatarImagePath: pickedImagePath,
                          bannerImagePath: pickedBannerPath,
                          avatarColor: pickedColor,
                          commentsEnabled: commentsEnabled,
                          isPublic: isPublic,
                        );
                        await ChannelService.instance.updateChannel(updated);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        onChannelUpdated(updated);
                        unawaited(updated.broadcastGossipMeta());
                        unawaited(syncChannelVisualsAfterEdit(
                          updated: updated,
                          prevAvatarPath: prevAvatar,
                          prevBannerPath: prevBanner,
                          gossipFromId: myId,
                        ));
                        try {
                          await ChannelBackupService.instance
                              .publishBackup(updated);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Резерв разослан подписчикам (без уведомлений)'),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ошибка резерва: $e')),
                            );
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final prevAvatar = channel.avatarImagePath;
                final prevBanner = channel.bannerImagePath;
                final updated = channel.copyWith(
                  name: name,
                  description: descCtrl.text.trim().isEmpty
                      ? null
                      : descCtrl.text.trim(),
                  avatarEmoji: emojiCtrl.text.trim().isEmpty
                      ? channel.avatarEmoji
                      : emojiCtrl.text.trim(),
                  avatarImagePath: pickedImagePath,
                  bannerImagePath: pickedBannerPath,
                  avatarColor: pickedColor,
                  commentsEnabled: showPolicyToggles
                      ? commentsEnabled
                      : channel.commentsEnabled,
                  isPublic: showPolicyToggles ? isPublic : channel.isPublic,
                );
                await ChannelService.instance.updateChannel(updated);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                onChannelUpdated(updated);
                unawaited(updated.broadcastGossipMeta());
                unawaited(syncChannelVisualsAfterEdit(
                  updated: updated,
                  prevAvatarPath: prevAvatar,
                  prevBannerPath: prevBanner,
                  gossipFromId: myId,
                ));
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    ),
  );

  nameCtrl.dispose();
  descCtrl.dispose();
  emojiCtrl.dispose();
}
