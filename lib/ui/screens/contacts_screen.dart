import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../services/chat_storage_service.dart';
import '../widgets/avatar_widget.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Contact>>(
      valueListenable: ChatStorageService.instance.contactsNotifier,
      builder: (_, contacts, __) {
        if (contacts.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.people_outline, size: 64, color: Colors.grey.shade700),
              const SizedBox(height: 16),
              Text('Нет контактов',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
              const SizedBox(height: 8),
              Text('Найди устройства на вкладке "Рядом"\nи добавь их в контакты',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            ]),
          );
        }

        return ListView.separated(
          itemCount: contacts.length,
          separatorBuilder: (_, __) =>
              Divider(height: 1, indent: 72, color: Colors.grey.shade800),
          itemBuilder: (_, i) {
            final c = contacts[i];
            return _ContactTile(contact: c);
          },
        );
      },
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Contact contact;
  const _ContactTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: AvatarWidget(
        initials: contact.nickname.isNotEmpty
            ? contact.nickname[0].toUpperCase()
            : '?',
        color: contact.avatarColor,
        emoji: contact.avatarEmoji,
        size: 48,
      ),
      title: Text(contact.nickname,
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        '${contact.publicKeyHex.substring(0, 16)}...',
        style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.chat_outlined),
          tooltip: 'Написать',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerId: contact.publicKeyHex,
                peerNickname: contact.nickname,
                peerAvatarColor: contact.avatarColor,
                peerAvatarEmoji: contact.avatarEmoji,
              ),
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
          tooltip: 'Удалить',
          onPressed: () => _confirmDelete(context),
        ),
      ]),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            peerId: contact.publicKeyHex,
            peerNickname: contact.nickname,
            peerAvatarColor: contact.avatarColor,
            peerAvatarEmoji: contact.avatarEmoji,
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить контакт?'),
        content: Text('${contact.nickname} будет удалён из контактов.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await ChatStorageService.instance
                  .deleteContact(contact.publicKeyHex);
            },
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}
