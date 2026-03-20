import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

import '../../models/contact.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/profile_service.dart';
import '../screens/onboarding_screen.dart';
import '../screens/chat_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          // ── Профиль ────────────────────────────────────────────
          const _SectionHeader('Профиль'),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Мой публичный ключ'),
            subtitle: Text(
              profile?.publicKeyHex ?? '—',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                if (profile == null) return;
                Clipboard.setData(ClipboardData(text: profile.publicKeyHex));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ключ скопирован')),
                );
              },
            ),
          ),

          // ── Поиск по ID ────────────────────────────────────────
          const _SectionHeader('Найти пользователя'),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Поиск по уникальному ID'),
            subtitle: const Text('Открыть чат зная публичный ключ собеседника'),
            onTap: () => _showSearchById(context),
          ),

          // ── Данные ─────────────────────────────────────────────
          const _SectionHeader('Данные'),
          ListTile(
            leading:
                const Icon(Icons.delete_sweep_outlined, color: Colors.orange),
            title: const Text('Очистить историю чатов'),
            subtitle: const Text('Удалит все сообщения, контакты останутся'),
            onTap: () => _confirmAction(
              context: context,
              title: 'Очистить историю?',
              description: 'Все сообщения будут удалены. Контакты останутся.',
              action: () async {
                final db = await _getDb();
                await db.delete('messages');
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('История очищена')),
                  );
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.contacts_outlined, color: Colors.orange),
            title: const Text('Удалить все контакты'),
            subtitle: const Text('Контакты будут удалены, сообщения останутся'),
            onTap: () => _confirmAction(
              context: context,
              title: 'Удалить контакты?',
              description: 'Все контакты будут удалены.',
              action: () async {
                final db = await _getDb();
                await db.delete('contacts');
                await ChatStorageService.instance.loadContacts();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Контакты удалены')),
                  );
                }
              },
            ),
          ),

          // ── Опасная зона ───────────────────────────────────────
          const _SectionHeader('Опасная зона'),
          ListTile(
            leading: const Icon(Icons.restore, color: Colors.red),
            title: const Text('Сбросить приложение',
                style: TextStyle(color: Colors.red)),
            subtitle:
                const Text('Удалит профиль, все чаты и контакты. Необратимо.'),
            onTap: () => _confirmAction(
              context: context,
              title: 'Сбросить всё?',
              description: 'Будут удалены профиль, все сообщения и контакты. '
                  'Приложение вернётся к экрану регистрации. '
                  'Это действие необратимо.',
              destructive: true,
              action: () async {
                await _fullReset(context);
              },
            ),
          ),

          const SizedBox(height: 32),

          // ── Версия ─────────────────────────────────────────────
          Center(
            child: Text(
              'Rlink v1.0.0 • BLE mesh messenger',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showSearchById(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Поиск по ID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Введи публичный ключ собеседника (hex). '
              'Его можно найти в Профиле → Публичный ключ.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                hintText: '1e326bb1a4f2...',
                hintStyle: TextStyle(color: Colors.grey.shade600),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final id = ctrl.text.trim().toLowerCase();
              if (id.length < 8) return;
              Navigator.pop(ctx);
              // Ищем контакт по этому ID
              final contact = await ChatStorageService.instance.getContact(id);
              final nickname = contact?.nickname ?? '${id.substring(0, 8)}...';
              final color = contact?.avatarColor ?? 0xFF607D8B;
              final emoji = contact?.avatarEmoji ?? '';
              final imagePath = contact?.avatarImagePath;
              // Если контакта нет — создаём временный
              if (contact == null) {
                await ChatStorageService.instance.saveContact(Contact(
                  publicKeyHex: id,
                  nickname: nickname,
                  avatarColor: color,
                  avatarEmoji: emoji,
                  addedAt: DateTime.now(),
                ));
              }
              if (context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      peerId: id,
                      peerNickname: nickname,
                      peerAvatarColor: color,
                      peerAvatarEmoji: emoji,
                      peerAvatarImagePath: imagePath,
                    ),
                  ),
                );
              }
            },
            child: const Text('Открыть чат'),
          ),
        ],
      ),
    );
  }

  Future<Database> _getDb() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(join(dir.path, 'rlink.db'));
  }

  Future<void> _fullReset(BuildContext context) async {
    // 1. Останавливаем BLE (безопасно)
    try {
      await BleService.instance.stop();
    } catch (_) {}

    // 1b. Очищаем BLE маппинги ключей
    BleService.instance.clearMappings();

    // 2. Сбрасываем БД через сервис (закрываем соединение, чистим кэш, удаляем файл)
    await ChatStorageService.instance.resetAll();

    // 3. Удаляем профиль из secure storage (включая iOS Keychain)
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
        synchronizable: false,
      ),
    );
    await storage.deleteAll();

    if (!context.mounted) return;

    // 4. Переходим на онбординг, очищаем стек навигации
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const OnboardingScreen()),
      (route) => false,
    );
  }

  Future<void> _confirmAction({
    required BuildContext context,
    required String title,
    required String description,
    required Future<void> Function() action,
    bool destructive = false,
  }) {
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () async {
              Navigator.pop(context);
              await action();
            },
            child: Text(destructive ? 'Сбросить' : 'Подтвердить'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Colors.grey.shade500,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
