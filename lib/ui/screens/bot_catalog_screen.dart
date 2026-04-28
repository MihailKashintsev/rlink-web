import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../services/ai_bot_constants.dart';
import '../../services/app_settings.dart';
import '../../services/chat_storage_service.dart';
import '../rlink_nav_routes.dart';
import 'chat_screen.dart';

class BotCatalogScreen extends StatefulWidget {
  const BotCatalogScreen({super.key});

  @override
  State<BotCatalogScreen> createState() => _BotCatalogScreenState();
}

class _BotCatalogScreenState extends State<BotCatalogScreen> {
  bool _starting = false;

  @override
  Widget build(BuildContext context) {
    final enabled = AppSettings.instance.enabledBotIds.toSet();
    const bots = kBuiltinAiBots;
    return Scaffold(
      appBar: AppBar(title: const Text('Боты')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Сторонние боты (из каталога relay) отвечают, когда запущен их процесс '
                'и есть связь с ретранслятором. В приложении с ними — как в обычной личке, '
                'но только текст: без файлов, голоса, видео и звонков. Сообщения идут по тем же '
                'E2E-правилам, что и с людьми; ваш профиль на них автоматически не «пушится» для проверки сети.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: bots.length,
              itemBuilder: (context, index) {
                final bot = bots[index];
                final isEnabled = enabled.contains(bot.id);
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Color(bot.avatarColor),
                      child: Text(bot.avatarEmoji),
                    ),
                    title: Text(bot.name),
                    subtitle: Text(
                      isEnabled
                          ? bot.description
                          : '${bot.description}\nНе активирован',
                    ),
                    trailing: FilledButton(
                      onPressed: _starting ? null : () => _startBot(bot),
                      child: Text(isEnabled ? 'Старт' : 'Активировать'),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startBot(AiBotDefinition bot) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final enabled = AppSettings.instance.enabledBotIds.toSet();
      if (!enabled.contains(bot.id)) {
        enabled.add(bot.id);
        await AppSettings.instance.setEnabledBotIds(enabled.toList());
      }
      final existing = await ChatStorageService.instance.getContact(bot.id);
      if (existing == null) {
        await ChatStorageService.instance.saveContact(Contact(
          publicKeyHex: bot.id,
          nickname: bot.name,
          avatarColor: bot.avatarColor,
          avatarEmoji: bot.avatarEmoji,
          addedAt: DateTime.now(),
        ));
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        rlinkChatRoute(ChatScreen(
          peerId: bot.id,
          peerNickname: bot.name,
          peerAvatarColor: bot.avatarColor,
          peerAvatarEmoji: bot.avatarEmoji,
        )),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
