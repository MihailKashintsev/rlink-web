import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

import '../../l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/group_service.dart';
import '../../services/profile_service.dart';
import '../screens/onboarding_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/about_screen.dart';

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
      appBar: AppBar(title: Text(AppL10n.t('settings'))),
      body: ListView(
        children: [

          // ── Внешний вид ────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_appearance')),

          // Theme
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppL10n.t('settings_theme'),
                    style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 8),
                Row(children: [
                  _ThemeChip(
                    label: AppL10n.t('settings_theme_system'),
                    icon: Icons.brightness_auto,
                    selected: settings.themeMode == ThemeMode.system,
                    onTap: () => settings.setThemeMode(ThemeMode.system),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: AppL10n.t('settings_theme_light'),
                    icon: Icons.light_mode,
                    selected: settings.themeMode == ThemeMode.light,
                    onTap: () => settings.setThemeMode(ThemeMode.light),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: AppL10n.t('settings_theme_dark'),
                    icon: Icons.dark_mode,
                    selected: settings.themeMode == ThemeMode.dark,
                    onTap: () => settings.setThemeMode(ThemeMode.dark),
                  ),
                ]),

                const SizedBox(height: 20),

                // Accent color
                Text(AppL10n.t('settings_accent_color'),
                    style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: List.generate(AppSettings.accentColors.length, (i) {
                    final color = AppSettings.accentColors[i];
                    final selected = settings.accentColorIndex == i;
                    return GestureDetector(
                      onTap: () => settings.setAccentColor(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: selected
                              ? Border.all(color: cs.onSurface, width: 3)
                              : null,
                          boxShadow: selected
                              ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
                              : null,
                        ),
                        child: selected
                            ? const Icon(Icons.check, color: Colors.white, size: 18)
                            : null,
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),

          // Font size
          ListTile(
            leading: Icon(Icons.format_size, color: cs.primary),
            title: Text(AppL10n.t('settings_font_size')),
            subtitle: Text(
              [AppL10n.t('settings_font_small'),
               AppL10n.t('settings_font_medium'),
               AppL10n.t('settings_font_large')][settings.fontSize],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _SizeChip(
                label: 'A',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 0,
                onTap: () => settings.setFontSize(0),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: 'A',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 1,
                onTap: () => settings.setFontSize(1),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: 'A',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 2,
                onTap: () => settings.setFontSize(2),
              ),
            ]),
          ),

          // Compact mode
          SwitchListTile(
            secondary: Icon(Icons.compress_outlined, color: cs.primary),
            title: Text(AppL10n.t('settings_compact_mode')),
            subtitle: Text(AppL10n.t('settings_compact_mode_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.compactMode,
            onChanged: (v) => settings.setCompactMode(v),
          ),

          // Chat background
          _SectionHeader(AppL10n.t('settings_chat_bg')),
          _ChatBgTile(settings: settings),

          // Language
          _SectionHeader(AppL10n.t('settings_language')),
          ListTile(
            leading: Icon(Icons.translate_rounded, color: cs.primary),
            title: Text(AppL10n.t('settings_language')),
            subtitle: Text(
              AppL10n.supportedLocales
                  .firstWhere((l) => l.code == settings.locale,
                      orElse: () => AppL10n.supportedLocales.first)
                  .nativeName,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLanguagePicker(context, settings),
          ),

          // ── Уведомления ────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_notifications')),
          SwitchListTile(
            secondary: Icon(Icons.notifications_outlined,
                color: settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_messages')),
            subtitle: Text(AppL10n.t('settings_notif_messages_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.notificationsEnabled,
            onChanged: (v) => settings.setNotificationsEnabled(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.volume_up_outlined,
                color: settings.notifSound && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_sound')),
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
            title: Text(AppL10n.t('settings_notif_vibration')),
            value: settings.notifVibration,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifVibration(v)
                : null,
          ),

          // ── Конфиденциальность ─────────────────────────────────
          _SectionHeader(AppL10n.t('settings_privacy')),
          SwitchListTile(
            secondary: Icon(Icons.done_all_rounded,
                color: settings.showReadReceipts ? cs.primary : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_read_receipts')),
            subtitle: Text(AppL10n.t('settings_read_receipts_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showReadReceipts,
            onChanged: (v) => settings.setShowReadReceipts(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.circle,
                color: settings.showOnlineStatus
                    ? const Color(0xFF4CAF50)
                    : Theme.of(context).hintColor,
                size: 14),
            title: Text(AppL10n.t('settings_online_status')),
            subtitle: Text(AppL10n.t('settings_online_status_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showOnlineStatus,
            onChanged: (v) => settings.setShowOnlineStatus(v),
          ),

          // ── Статус в сети ──────────────────────────────────────
          const _SectionHeader('Статус в сети'),
          _OnlineStatusSelector(
            current: settings.onlineStatusMode,
            onChanged: (mode) => settings.setOnlineStatusMode(mode),
          ),

          // ── Разрешения ─────────────────────────────────────────
          const _SectionHeader('Разрешения'),
          const _PermissionsSection(),

          // ── Сообщения ──────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_messaging')),
          SwitchListTile(
            secondary: Icon(Icons.keyboard_return_rounded,
                color: settings.sendOnEnter ? cs.primary : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_send_on_enter')),
            subtitle: Text(AppL10n.t('settings_send_on_enter_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.sendOnEnter,
            onChanged: (v) => settings.setSendOnEnter(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.download_for_offline_outlined,
                color: settings.autoDownloadMedia ? cs.primary : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_auto_download')),
            subtitle: Text(AppL10n.t('settings_auto_download_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.autoDownloadMedia,
            onChanged: (v) => settings.setAutoDownloadMedia(v),
          ),

          // ── Профиль ────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_profile')),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(AppL10n.t('settings_public_key')),
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
                  SnackBar(content: Text(AppL10n.t('settings_key_copied'))),
                );
              },
            ),
          ),

          // ── Поиск по ID ────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_find_user')),
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(AppL10n.t('settings_search_by_id')),
            subtitle: Text(AppL10n.t('settings_search_by_id_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _showSearchById(context),
          ),

          // ── Сеть ──────────────────────────────────────────────
          const _SectionHeader('Сеть'),
          SwitchListTile(
            secondary: Icon(Icons.cell_tower,
                color: settings.relayEnabled ? cs.primary : Theme.of(context).hintColor),
            title: const Text('Интернет-ретранслятор'),
            subtitle: Text(
              settings.relayEnabled ? 'Сообщения идут через BLE + интернет' : 'Только BLE mesh',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: settings.relayEnabled,
            onChanged: (v) => settings.setRelayEnabled(v),
          ),
          if (settings.relayEnabled)
            ListTile(
              leading: Icon(Icons.dns_outlined, color: cs.primary),
              title: const Text('Сервер ретрансляции'),
              subtitle: Text(
                settings.relayServerUrl.isEmpty
                    ? 'По умолчанию (rlink-relay.onrender.com)'
                    : settings.relayServerUrl,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.edit, size: 18),
              onTap: () => _showRelayServerDialog(context, settings),
            ),

          // ── Данные ─────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_data')),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined, color: Colors.orange),
            title: Text(AppL10n.t('settings_clear_history')),
            subtitle: Text(AppL10n.t('settings_clear_history_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _confirmAction(
              context: context,
              title: AppL10n.t('settings_clear_history'),
              description: AppL10n.t('settings_clear_history_sub'),
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
            title: Text(AppL10n.t('settings_delete_contacts')),
            subtitle: Text(AppL10n.t('settings_delete_contacts_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _confirmAction(
              context: context,
              title: AppL10n.t('settings_delete_contacts'),
              description: AppL10n.t('settings_delete_contacts_sub'),
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
          _SectionHeader(AppL10n.t('settings_danger')),
          ListTile(
            leading: const Icon(Icons.restore, color: Colors.red),
            title: Text(AppL10n.t('settings_reset'),
                style: const TextStyle(color: Colors.red)),
            subtitle: Text(AppL10n.t('settings_reset_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _confirmAction(
              context: context,
              title: AppL10n.t('settings_reset'),
              description: AppL10n.t('settings_reset_sub'),
              destructive: true,
              action: () async {
                await _fullReset(context);
              },
            ),
          ),

          // ── О проекте ──────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_about')),
          ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.info_outline_rounded, color: cs.primary),
            ),
            title: Text(AppL10n.t('about_title')),
            subtitle: const Text('Mihail Kashintsev • Rendergames',
                style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AboutScreen())),
          ),

          const SizedBox(height: 32),

          Center(
            child: Text(
              'Rlink v0.0.2 • BLE mesh messenger',
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showRelayServerDialog(BuildContext context, AppSettings settings) {
    final controller = TextEditingController(text: settings.relayServerUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сервер ретрансляции'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'wss://your-server.com',
            labelText: 'URL сервера (пусто = по умолчанию)',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              settings.setRelayServerUrl(controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showLanguagePicker(BuildContext context, AppSettings settings) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text(AppL10n.t('settings_language'),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...AppL10n.supportedLocales.map((locale) {
              final selected = settings.locale == locale.code;
              return ListTile(
                title: Text(locale.nativeName),
                subtitle: locale.code != 'system'
                    ? Text(locale.name,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor))
                    : null,
                trailing: selected
                    ? Icon(Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () {
                  settings.setLocale(locale.code);
                  Navigator.pop(ctx);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showSearchById(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.t('settings_search_by_id')),
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
            child: Text(AppL10n.t('cancel')),
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
    await ChannelService.instance.resetAll();
    await GroupService.instance.resetAll();
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
            child: Text(AppL10n.t('cancel')),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () async {
              Navigator.pop(context);
              await action();
            },
            child: Text(destructive ? AppL10n.t('reset') : AppL10n.t('confirm')),
          ),
        ],
      ),
    );
  }
}

// ── Font size chip ────────────────────────────────────────────────

class _SizeChip extends StatelessWidget {
  final String label;
  final TextStyle style;
  final bool selected;
  final VoidCallback onTap;

  const _SizeChip({
    required this.label,
    required this.style,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: selected ? null : Border.all(color: cs.outlineVariant),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: style.copyWith(
                color: selected ? cs.onPrimary : cs.onSurfaceVariant)),
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

// ── Фон чата ─────────────────────────────────────────────────────

class _ChatBgTile extends StatelessWidget {
  final AppSettings settings;
  const _ChatBgTile({required this.settings});

  Future<void> _pickBg(BuildContext context) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final dest = File(join(appDir.path,
        'chat_bg_${DateTime.now().millisecondsSinceEpoch}.jpg'));
    await File(picked.path).copy(dest.path);
    await settings.setChatBgForPeer('__global__', dest.path);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bgPath = settings.chatBgForPeer('__global__');

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: bgPath != null && File(bgPath).existsSync()
            ? Image.file(File(bgPath), width: 44, height: 44, fit: BoxFit.cover)
            : Container(
                width: 44,
                height: 44,
                color: cs.surfaceContainerHigh,
                child: Icon(Icons.wallpaper_outlined, color: cs.onSurfaceVariant),
              ),
      ),
      title: Text(AppL10n.t('settings_chat_bg')),
      subtitle: Text(
        bgPath != null
            ? AppL10n.t('settings_chat_bg_custom')
            : AppL10n.t('settings_chat_bg_none'),
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (bgPath != null)
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: 'Убрать фон',
            onPressed: () => settings.setChatBgForPeer('__global__', null),
          ),
        IconButton(
          icon: const Icon(Icons.photo_library_outlined),
          tooltip: 'Выбрать из галереи',
          onPressed: () => _pickBg(context),
        ),
      ]),
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

// ── Статус в сети ─────────────────────────────────────────────────

class _OnlineStatusSelector extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;

  const _OnlineStatusSelector({required this.current, required this.onChanged});

  static const _statuses = [
    (icon: Icons.circle, color: Color(0xFF4CAF50), label: 'В сети', sub: 'Доступен для сообщений'),
    (icon: Icons.circle, color: Color(0xFFFFC107), label: 'Не беспокоить', sub: 'В сети, но занят'),
    (icon: Icons.circle, color: Color(0xFFF44336), label: 'Занят', sub: 'Не писать'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < _statuses.length; i++)
          RadioListTile<int>(
            value: i,
            groupValue: current,
            onChanged: (v) { if (v != null) onChanged(v); },
            secondary: Icon(_statuses[i].icon, color: _statuses[i].color, size: 14),
            title: Text(_statuses[i].label),
            subtitle: Text(_statuses[i].sub,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            dense: true,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Icon(Icons.circle, color: Colors.grey.shade500, size: 10),
            const SizedBox(width: 8),
            Text('Серый — автоматически, когда не в сети',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ]),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ── Разрешения ────────────────────────────────────────────────────

class _PermissionsSection extends StatefulWidget {
  const _PermissionsSection();

  @override
  State<_PermissionsSection> createState() => _PermissionsSectionState();
}

class _PermissionsSectionState extends State<_PermissionsSection> {
  final Map<Permission, PermissionStatus> _statuses = {};
  bool _loading = true;

  static const _permissions = <(Permission, String, IconData)>[
    (Permission.bluetooth, 'Bluetooth', Icons.bluetooth),
    (Permission.bluetoothScan, 'Bluetooth сканирование', Icons.bluetooth_searching),
    (Permission.bluetoothConnect, 'Bluetooth подключение', Icons.bluetooth_connected),
    (Permission.bluetoothAdvertise, 'Bluetooth реклама', Icons.settings_bluetooth),
    (Permission.location, 'Геолокация', Icons.location_on_outlined),
    (Permission.microphone, 'Микрофон', Icons.mic_outlined),
    (Permission.camera, 'Камера', Icons.camera_alt_outlined),
    (Permission.notification, 'Уведомления', Icons.notifications_outlined),
    (Permission.photos, 'Фото', Icons.photo_library_outlined),
    (Permission.storage, 'Хранилище', Icons.folder_outlined),
  ];

  @override
  void initState() {
    super.initState();
    _loadStatuses();
  }

  Future<void> _loadStatuses() async {
    final results = <Permission, PermissionStatus>{};
    for (final (perm, _, _) in _permissions) {
      try {
        results[perm] = await perm.status;
      } catch (_) {
        // Some permissions may not be available on this platform
      }
    }
    if (mounted) setState(() { _statuses.addAll(results); _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final cs = Theme.of(context).colorScheme;
    final items = <Widget>[];

    for (final (perm, label, icon) in _permissions) {
      final status = _statuses[perm];
      if (status == null) continue; // Not available on this platform

      final granted = status.isGranted || status.isLimited;
      final permanent = status.isPermanentlyDenied;
      final denied = status.isDenied;

      items.add(ListTile(
        leading: Icon(icon, color: granted ? cs.primary : Colors.grey),
        title: Text(label),
        subtitle: Text(
          granted
              ? 'Разрешено'
              : permanent
                  ? 'Запрещено (настройки)'
                  : 'Не разрешено',
          style: TextStyle(
            fontSize: 12,
            color: granted ? Colors.green : Colors.orange,
          ),
        ),
        trailing: granted
            ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
            : TextButton(
                onPressed: () async {
                  if (permanent) {
                    await openAppSettings();
                  } else if (denied) {
                    final result = await perm.request();
                    if (mounted) {
                      setState(() => _statuses[perm] = result);
                    }
                  }
                },
                child: Text(permanent ? 'Открыть' : 'Разрешить',
                    style: const TextStyle(fontSize: 12)),
              ),
        dense: true,
      ));
    }

    return Column(children: items);
  }
}
