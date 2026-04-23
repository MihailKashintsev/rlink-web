import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import 'avatar_widget.dart';

/// Строка списка «переслать в…» (личные чаты + избранное), в духе вкладки «Чаты».
class ForwardDmTargetPick {
  final String peerId;
  final String nickname;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;
  final DateTime lastTime;
  final bool isSavedMessages;

  const ForwardDmTargetPick({
    required this.peerId,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    required this.lastTime,
    this.isSavedMessages = false,
  });
}

Future<List<ForwardDmTargetPick>> loadForwardDmTargets({
  String? excludePeerId,
}) async {
  final items = <ForwardDmTargetPick>[];
  final myId = CryptoService.instance.publicKeyHex;

  final summaries = await ChatStorageService.instance.getChatSummaries();
  final summaryIds = <String>{};
  for (final s in summaries) {
    if (myId.isNotEmpty && s.peerId == myId) continue;
    if (excludePeerId != null && s.peerId == excludePeerId) continue;
    summaryIds.add(s.peerId);
    items.add(ForwardDmTargetPick(
      peerId: s.peerId,
      nickname: s.nickname ??
          '${s.peerId.substring(0, s.peerId.length.clamp(0, 8))}...',
      avatarColor: s.avatarColor ?? 0xFF607D8B,
      avatarEmoji: s.avatarEmoji ?? '',
      avatarImagePath: s.avatarImagePath,
      lastTime: s.timestamp,
    ));
  }

  final contacts = await ChatStorageService.instance.getContacts();
  for (final c in contacts) {
    if (myId.isNotEmpty && c.publicKeyHex == myId) continue;
    if (summaryIds.contains(c.publicKeyHex)) continue;
    if (excludePeerId != null && c.publicKeyHex == excludePeerId) continue;
    items.add(ForwardDmTargetPick(
      peerId: c.publicKeyHex,
      nickname: c.nickname.isNotEmpty
          ? c.nickname
          : '${c.publicKeyHex.substring(0, 8)}...',
      avatarColor: c.avatarColor,
      avatarEmoji: c.avatarEmoji,
      avatarImagePath: c.avatarImagePath,
      lastTime: c.addedAt,
    ));
  }

  items.sort((a, b) => b.lastTime.compareTo(a.lastTime));

  if (myId.isNotEmpty &&
      (excludePeerId == null || excludePeerId != myId)) {
    final savedLast = await ChatStorageService.instance.getLastMessage(myId);
    final savedTime =
        savedLast?.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
    items.insert(
      0,
      ForwardDmTargetPick(
        peerId: myId,
        nickname: AppL10n.t('chat_saved_messages'),
        avatarColor: 0xFF26A69A,
        avatarEmoji: '⭐',
        avatarImagePath: null,
        lastTime: savedTime,
        isSavedMessages: true,
      ),
    );
  }

  return items;
}

/// Модальное окно выбора чата для пересылки (Telegram-style).
Future<ForwardDmTargetPick?> showForwardDmTargetSheet(
  BuildContext context, {
  String? excludePeerId,
}) async {
  final targets = await loadForwardDmTargets(excludePeerId: excludePeerId);
  if (!context.mounted) return null;
  if (targets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          excludePeerId != null
              ? 'Нет других чатов для пересылки'
              : 'Нет чатов для пересылки',
        ),
      ),
    );
    return null;
  }

  return showModalBottomSheet<ForwardDmTargetPick>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final h = MediaQuery.sizeOf(ctx).height * 0.55;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: SizedBox(
            height: h,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            'Переслать в…',
                            style: Theme.of(ctx)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: targets.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      indent: 72,
                      endIndent: 12,
                      color: Theme.of(ctx)
                          .dividerColor
                          .withValues(alpha: 0.22),
                    ),
                    itemBuilder: (_, i) {
                      final t = targets[i];
                      final cs = Theme.of(ctx).colorScheme;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        leading: AvatarWidget(
                          initials: t.nickname.isNotEmpty
                              ? t.nickname[0].toUpperCase()
                              : '?',
                          color: t.avatarColor,
                          emoji: t.avatarEmoji,
                          imagePath: t.avatarImagePath,
                          size: 48,
                        ),
                        title: Row(
                          children: [
                            if (t.isSavedMessages)
                              Padding(
                                padding:
                                    const EdgeInsets.only(right: 6, top: 1),
                                child: Icon(
                                  Icons.bookmark_outline_rounded,
                                  size: 18,
                                  color:
                                      cs.primary.withValues(alpha: 0.85),
                                ),
                              ),
                            Expanded(
                              child: Text(
                                t.nickname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                        onTap: () => Navigator.pop(ctx, t),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
