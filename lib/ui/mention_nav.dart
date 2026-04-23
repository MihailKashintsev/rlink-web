import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../services/chat_storage_service.dart';
import '../services/profile_service.dart';
import '../utils/channel_mentions.dart';
import 'rlink_nav_routes.dart';
import 'screens/chat_screen.dart';

/// Открыть личный чат с пользователем из токена упоминания `&hex`.
void openDmFromMentionKey(BuildContext context, String publicKeyHex) {
  final hexLower = publicKeyHex.toLowerCase();
  final contacts = ChatStorageService.instance.contactsNotifier.value;
  final self = ProfileService.instance.profile;
  final label = resolveChannelMentionDisplay(publicKeyHex, contacts, self);

  Contact? contact;
  for (final c in contacts) {
    if (c.publicKeyHex.toLowerCase() == hexLower) {
      contact = c;
      break;
    }
  }

  final peerId = contact?.publicKeyHex ?? publicKeyHex;
  final nick = contact?.nickname.trim().isNotEmpty == true
      ? contact!.nickname
      : label;

  Navigator.of(context).push(
    rlinkChatRoute(
      ChatScreen(
        peerId: peerId,
        peerNickname: nick,
        peerAvatarColor: contact?.avatarColor ?? 0xFF607D8B,
        peerAvatarEmoji: contact?.avatarEmoji ?? '',
        peerAvatarImagePath: contact?.avatarImagePath,
      ),
    ),
  );
}
