import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

import '../../models/contact.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/profile_service.dart';
import '../screens/onboarding_screen.dart';
import '../screens/chat_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          // ── Внешний вид ────────────────────────────────────────
          const _SectionHeader('Внешний вид'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Тема',
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 8),
                Row(children: [
                  _ThemeChip(
                    label: 'Системная',
                    icon: Icons.brightness_auto,
                    selected: settings.themeMode == ThemeMode.system,
                    onTap: () => settings.setThemeMode(ThemeMode.system),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: 'Светлая',
                    icon: Icons.light_mode,
                    selected: settings.themeMode == ThemeMode.light,
                    onTap: () => settings.setThemeMode(ThemeMode.light),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: 'Тёмная',
                    icon: Icons.dark_mode,
                    selected: settings.themeMode == ThemeMode.dark,
                    onTap: () => settings.setThemeMode(ThemeMode.dark),
                  ),
                ]),
                const SizedBox(height: 16),
                Text('Акцентный цвет',
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 10),
                Row(
                  children: List.generate(
                    AppSettings.accentColors.length,
                    (i) {
                      final color = AppSettings.accentColors[i];
                      final selected = settings.accentColorIndex == i;
                      return GestureDetector(
                        onTap: () => settings.setAccentColor(i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.only(right: 12),
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(
                                    color: cs.onSurface, width: 3)
                                : null,
                            boxShadow: selected
                                ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
                                : null,
                          ),
                          child: selected
                              ? const Icon(Icons.check,
                                  color: Colors.white, size: 18)
                              : null,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── Уведомления ────────────────────────────────────────
          const _SectionHeader('Уведомления'),
          SwitchListTile(
            secondary: Icon(Icons.notifications_outlined,
                color: settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: const Text('Уведомления о сообщениях'),
            subtitle: const Text('Показывать уведомление при новом сообщении'),
            value: settings.notificationsEnabled,
            onChanged: (v) => settings.setNotificationsEnabled(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.volume_up_outlined,
                color: settings.notifSound && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: const Text('Звук'),
            value: settings.notifSound,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifSound(v)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.vibration,
                color: settings.notifVibration && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: const Text('Вибрация'),
            value: settings.notifVibration,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifVibration(v)
                : null,
          ),

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
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
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
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                hintText: '1e326bb1a4f2...',
                hintStyle: TextStyle(color: Theme.of(context).hintColor),
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
              final contact = await ChatStorageService.instance.getContact(id);
              final nickname = contact?.nickname ?? '${id.substring(0, 8)}...';
              final color = contact?.avatarColor ?? 0xFF607D8B;
              final emoji = contact?.avatarEmoji ?? '';
              final imagePath = contact?.avatarImagePath;
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
    try {
      await BleService.instance.stop();
    } catch (_) {}
    BleService.instance.clearMappings();
    await ChatStorageService.instance.resetAll();
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
        synchronizable: false,
      ),
    );
    await storage.deleteAll();
    if (!context.mounted) return;
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

// ── Тема-чип ─────────────────────────────────────────────────────

class _ThemeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: cs.outlineVariant),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 16,
              color: selected ? cs.onPrimary : cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? cs.onPrimary : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Секция-заголовок ──────────────────────────────────────────────

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
          color: Theme.of(context).hintColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
