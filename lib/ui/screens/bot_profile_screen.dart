import 'package:flutter/material.dart';

import '../../services/relay_service.dart';
import '../widgets/avatar_widget.dart';

/// Публичный профиль relay-бота (каталог): метаданные, verified, команды.
class BotProfileScreen extends StatefulWidget {
  const BotProfileScreen({
    super.key,
    required this.botId,
    required this.handle,
  });

  final String botId;
  /// Нормализованный handle без @.
  final String handle;

  @override
  State<BotProfileScreen> createState() => _BotProfileScreenState();
}

class _BotProfileScreenState extends State<BotProfileScreen> {
  Future<Map<String, dynamic>?>? _load;

  @override
  void initState() {
    super.initState();
    _load = RelayService.instance.fetchBotInfo(widget.handle);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Бот')),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null || data['ok'] != true) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  data == null
                      ? 'Не удалось загрузить данные бота. Проверьте relay и ник.'
                      : 'Бот не найден: ${data['error'] ?? 'ошибка'}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final displayName =
              (data['displayName'] as String?)?.trim().isNotEmpty == true
                  ? data['displayName'] as String
                  : widget.handle;
          final desc = (data['description'] as String?)?.trim() ?? '';
          final verified = data['verified'] == true;
          final avatarUrl = (data['avatarUrl'] as String?)?.trim() ?? '';
          final cmds = data['commands'];
          final list = cmds is List
              ? cmds
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
              : <Map<String, dynamic>>[];

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Center(
                child: AvatarWidget(
                  initials: displayName.isNotEmpty
                      ? displayName[0].toUpperCase()
                      : '?',
                  color: 0xFF1E88E5,
                  emoji: '',
                  imagePath: avatarUrl.isNotEmpty ? avatarUrl : null,
                  size: 96,
                  isOnline: false,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      displayName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (verified) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.verified, size: 22, color: Colors.blue.shade700),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '@${widget.handle}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: cs.onSurface,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.chat_outlined),
                label: const Text('Написать'),
              ),
              if (list.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  'Команды',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                ...list.map((e) {
                  final cmd = (e['cmd'] as String?) ?? '';
                  final d = (e['desc'] as String?) ?? '';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.terminal, size: 20, color: cs.primary),
                    title: Text(
                      cmd,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontFamily: 'monospace',
                      ),
                    ),
                    subtitle:
                        d.isNotEmpty ? Text(d) : const SizedBox.shrink(),
                  );
                }),
              ],
            ],
          );
        },
      ),
    );
  }
}
