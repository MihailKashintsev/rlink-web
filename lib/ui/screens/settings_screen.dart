import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/group_service.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../screens/onboarding_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/about_screen.dart';
import '../screens/admin_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Hidden admin panel — 15 taps on version text → password dialog
  int _versionTapCount = 0;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

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

          // Bubble style
          ListTile(
            leading: Icon(Icons.chat_bubble_outline, color: cs.primary),
            title: const Text('Стиль сообщений'),
            subtitle: Text(
              ['Скруглённый', 'Квадратный', 'Минимальный'][settings.bubbleStyle],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 3; i++) ...[
                GestureDetector(
                  onTap: () => settings.setBubbleStyle(i),
                  child: Container(
                    width: 28,
                    height: 20,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(
                          alpha: settings.bubbleStyle == i ? 0.85 : 0.25),
                      borderRadius: i == 0
                          ? BorderRadius.circular(10)
                          : i == 1
                              ? BorderRadius.circular(3)
                              : BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ]),
          ),

          // Message density
          ListTile(
            leading: Icon(Icons.density_medium, color: cs.primary),
            title: const Text('Плотность сообщений'),
            subtitle: Text(
              ['Свободная', 'Обычная', 'Компактная'][settings.messageDensity],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 3; i++) ...[
                _SizeChip(
                  label: ['≋', '≡', '-'][i],
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                  selected: settings.messageDensity == i,
                  onTap: () => settings.setMessageDensity(i),
                ),
                const SizedBox(width: 4),
              ],
            ]),
          ),

          // Clock format
          ListTile(
            leading: Icon(Icons.schedule, color: cs.primary),
            title: const Text('Формат времени'),
            subtitle: Text(
              settings.clockFormat == 0 ? '24-часовой' : '12-часовой (AM/PM)',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _SizeChip(
                label: '24',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700),
                selected: settings.clockFormat == 0,
                onTap: () => settings.setClockFormat(0),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: '12',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700),
                selected: settings.clockFormat == 1,
                onTap: () => settings.setClockFormat(1),
              ),
            ]),
          ),

          // Reaction quick bar toggle
          SwitchListTile(
            secondary: Icon(Icons.emoji_emotions_outlined, color: cs.primary),
            title: const Text('Быстрая панель реакций'),
            subtitle: Text(
                'Показывать 6 эмодзи по долгому нажатию вместо полного списка',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showReactionsQuickBar,
            onChanged: (v) => settings.setShowReactionsQuickBar(v),
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

          // Тип связи
          ListTile(
            leading: Icon(Icons.swap_horiz_rounded, color: cs.primary),
            title: const Text('Тип связи'),
            subtitle: Text(
              const ['Только Bluetooth', 'Только Интернет', 'Оба канала'][settings.connectionMode],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              _NetChip(
                icon: Icons.bluetooth,
                label: 'BLE',
                selected: settings.connectionMode == 0,
                onTap: () => settings.setConnectionMode(0),
              ),
              const SizedBox(width: 8),
              _NetChip(
                icon: Icons.wifi,
                label: 'Интернет',
                selected: settings.connectionMode == 1,
                onTap: () => settings.setConnectionMode(1),
              ),
              const SizedBox(width: 8),
              _NetChip(
                icon: Icons.sync_alt_rounded,
                label: 'Оба',
                selected: settings.connectionMode == 2,
                onTap: () => settings.setConnectionMode(2),
              ),
            ]),
          ),
          const SizedBox(height: 12),

          // Приоритет медиа / файлов
          if (settings.connectionMode == 2) ...[
            ListTile(
              leading: Icon(Icons.perm_media_outlined, color: cs.primary),
              title: const Text('Приоритет для медиа'),
              subtitle: Text(
                settings.mediaPriority == 0 ? 'Отправлять через Bluetooth' : 'Отправлять через Интернет',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                _NetChip(
                  icon: Icons.bluetooth,
                  label: 'BLE',
                  selected: settings.mediaPriority == 0,
                  onTap: () => settings.setMediaPriority(0),
                ),
                const SizedBox(width: 8),
                _NetChip(
                  icon: Icons.wifi,
                  label: 'Интернет',
                  selected: settings.mediaPriority == 1,
                  onTap: () => settings.setMediaPriority(1),
                ),
              ]),
            ),
            const SizedBox(height: 12),
          ],

          // Статус сервера
          if (settings.connectionMode >= 1)
            ValueListenableBuilder<RelayState>(
              valueListenable: RelayService.instance.state,
              builder: (_, relayState, __) {
                final connected = relayState == RelayState.connected;
                final connecting = relayState == RelayState.connecting;
                return ValueListenableBuilder<int>(
                  valueListenable: RelayService.instance.onlineCount,
                  builder: (_, count, __) => ListTile(
                    leading: Icon(
                      connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      color: connected
                          ? const Color(0xFF4CAF50)
                          : connecting
                              ? Colors.amber
                              : Colors.red,
                    ),
                    title: Text(connected
                        ? 'Сервер подключён'
                        : connecting
                            ? 'Подключение...'
                            : 'Сервер недоступен'),
                    subtitle: Text(
                      connected ? 'Онлайн: $count пользователей' : 'Нет соединения с ретранслятором',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    trailing: connecting
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: connected ? 'Переподключиться' : 'Подключиться',
                            onPressed: () => RelayService.instance.reconnect(),
                          ),
                  ),
                );
              },
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
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleVersionTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
                child: Text(
                  'Rlink v0.0.2 • BLE mesh messenger',
                  style: TextStyle(
                      color: Theme.of(context).hintColor, fontSize: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Hidden admin panel ───────────────────────────────────────
  void _handleVersionTap() {
    final now = DateTime.now();
    // Reset counter if gap between taps > 2s
    if (now.difference(_lastTapAt).inMilliseconds > 2000) {
      _versionTapCount = 0;
    }
    _lastTapAt = now;
    _versionTapCount++;

    // Quiet hints at 10+ taps so nothing leaks to non-admins
    if (_versionTapCount >= 15) {
      _versionTapCount = 0;
      _promptAdminPassword();
    }
  }

  void _promptAdminPassword() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Доступ'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Пароль',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _checkAdminPassword(ctx, ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => _checkAdminPassword(ctx, ctrl.text),
            child: const Text('Войти'),
          ),
        ],
      ),
    );
  }

  void _checkAdminPassword(BuildContext dialogCtx, String input) {
    final hash = sha256Hex(input);
    if (hash != AppSettings.instance.adminPasswordHash) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Неверный пароль'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    Navigator.pop(dialogCtx);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AdminScreen()),
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _PeerSearchSheet(
        onOpenChat: (publicKey, nickname, color, emoji) async {
          Navigator.pop(ctx);
          final contact = await ChatStorageService.instance.getContact(publicKey);
          final finalNick = contact?.nickname ?? nickname;
          final finalColor = contact?.avatarColor ?? color;
          final finalEmoji = contact?.avatarEmoji ?? emoji;
          final imagePath = contact?.avatarImagePath;
          if (contact == null) {
            await ChatStorageService.instance.saveContact(Contact(
              publicKeyHex: publicKey,
              nickname: finalNick,
              avatarColor: finalColor,
              avatarEmoji: finalEmoji,
              addedAt: DateTime.now(),
            ));
          }
          if (context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  peerId: publicKey,
                  peerNickname: finalNick,
                  peerAvatarColor: finalColor,
                  peerAvatarEmoji: finalEmoji,
                  peerAvatarImagePath: imagePath,
                ),
              ),
            );
          }
        },
      ),
    );
  }

  Future<Database> _getDb() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(p.join(dir.path, 'rlink.db'));
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

class _NetChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NetChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? cs.primary : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: selected ? null : Border.all(color: cs.outlineVariant),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(label,
              style: TextStyle(
                fontSize: 11,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ]),
        ),
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
    final dest = File(p.join(appDir.path,
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

class _PermissionsSectionState extends State<_PermissionsSection>
    with WidgetsBindingObserver {
  final Map<Permission, PermissionStatus> _statuses = {};
  bool _loading = true;

  static List<(Permission, String, IconData)> get _permissions => [
    if (Platform.isAndroid) ...[
      (Permission.bluetoothScan, 'Bluetooth сканирование', Icons.bluetooth_searching),
      (Permission.bluetoothConnect, 'Bluetooth подключение', Icons.bluetooth_connected),
      (Permission.bluetoothAdvertise, 'Bluetooth реклама', Icons.settings_bluetooth),
    ],
    if (Platform.isIOS)
      (Permission.bluetooth, 'Bluetooth', Icons.bluetooth),
    (Permission.locationWhenInUse, 'Геолокация', Icons.location_on_outlined),
    (Permission.microphone, 'Микрофон', Icons.mic_outlined),
    (Permission.camera, 'Камера', Icons.camera_alt_outlined),
    (Permission.notification, 'Уведомления', Icons.notifications_outlined),
    (Permission.photos, 'Фото', Icons.photo_library_outlined),
    if (Platform.isAndroid)
      (Permission.nearbyWifiDevices, 'Wi-Fi устройства', Icons.wifi),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Когда пользователь вернулся из системных настроек — перечитываем статусы.
    // Задержка 600 мс нужна на iOS: ОС не сразу обновляет кэш permission_handler.
    if (state == AppLifecycleState.resumed && mounted) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _loadStatuses();
      });
    }
  }

  Future<void> _loadStatuses() async {
    final results = <Permission, PermissionStatus>{};
    for (final (perm, _, _) in _permissions) {
      try {
        // Используем actual текущий статус от ОС (без кеша).
        results[perm] = await perm.status;
      } catch (_) {
        // Некоторые разрешения могут быть недоступны на платформе — пропускаем.
      }
    }
    if (!mounted) return;
    setState(() {
      // Полностью заменяем — чтобы устаревшие записи не остались.
      _statuses
        ..clear()
        ..addAll(results);
      _loading = false;
    });
  }

  /// Единая классификация статуса разрешения.
  /// Возвращает одно из: 'granted', 'limited', 'denied', 'permanent', 'restricted'.
  String _classify(PermissionStatus s) {
    // isProvisional (iOS тихие уведомления) считаем как выданное.
    if (s.isGranted || s.isProvisional) return 'granted';
    if (s.isLimited) return 'limited';
    if (s.isRestricted) return 'restricted';
    if (s.isPermanentlyDenied) return 'permanent';
    return 'denied';
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
      if (status == null) continue; // недоступно на этой платформе

      final kind = _classify(status);
      final allowed = kind == 'granted' || kind == 'limited';

      final String subtitleText;
      final Color subtitleColor;
      switch (kind) {
        case 'granted':
          subtitleText = 'Разрешено';
          subtitleColor = Colors.green;
          break;
        case 'limited':
          subtitleText = 'Разрешено частично';
          subtitleColor = Colors.green;
          break;
        case 'permanent':
          subtitleText = 'Запрещено — откройте настройки';
          subtitleColor = Colors.redAccent;
          break;
        case 'restricted':
          subtitleText = 'Недоступно (ограничено системой)';
          subtitleColor = Colors.grey;
          break;
        default:
          subtitleText = 'Не разрешено';
          subtitleColor = Colors.orange;
      }

      items.add(ListTile(
        leading: Icon(icon, color: allowed ? cs.primary : Colors.grey),
        title: Text(label),
        subtitle: Text(
          subtitleText,
          style: TextStyle(fontSize: 12, color: subtitleColor),
        ),
        trailing: allowed
            ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
            : kind == 'restricted'
                ? const Icon(Icons.block, color: Colors.grey, size: 20)
                : TextButton(
                    onPressed: () async {
                      // На iOS после первого denied повторный request() ничего не делает —
                      // единственный путь это openAppSettings(). Так же для permanent.
                      if (kind == 'permanent' ||
                          (Platform.isIOS && kind == 'denied')) {
                        await openAppSettings();
                        return;
                      }
                      final result = await perm.request();
                      if (mounted) {
                        setState(() => _statuses[perm] = result);
                      }
                    },
                    child: Text(
                      kind == 'permanent' ? 'Открыть' : 'Разрешить',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
        dense: true,
      ));
    }

    return Column(children: [
      ...items,
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _loadStatuses,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Проверить разрешения'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => openAppSettings(),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Настройки ОС'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 8),
    ]);
  }
}

// ── Поиск собеседника (relay + прямой ключ) ─────────────────────

class _PeerSearchSheet extends StatefulWidget {
  final void Function(String publicKey, String nickname, int color, String emoji) onOpenChat;

  const _PeerSearchSheet({required this.onOpenChat});

  @override
  State<_PeerSearchSheet> createState() => _PeerSearchSheetState();
}

class _PeerSearchSheetState extends State<_PeerSearchSheet> {
  final _ctrl = TextEditingController();
  bool _searching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    // Clear search results on close
    RelayService.instance.searchResults.value = [];
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final q = _ctrl.text.trim();
    if (q.isEmpty) {
      RelayService.instance.searchResults.value = [];
      setState(() => _searching = false);
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () {
      RelayService.instance.searchUsers(q);
      // Give server time to respond
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _searching = false);
      });
    });
  }

  void _openDirect() {
    final id = _ctrl.text.trim().toLowerCase();
    if (id.length < 8) return;
    widget.onOpenChat(id, '${id.substring(0, 8)}...', 0xFF607D8B, '');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final relayConnected = RelayService.instance.isConnected;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text('Найти собеседника',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              relayConnected
                  ? 'Поиск по никнейму, короткому коду или ключу'
                  : 'Введи полный публичный ключ (relay не подключён)',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 12),
            // Search field
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Никнейм, код или ключ...',
                  hintStyle: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontFamily: 'sans-serif',
                  ),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _ctrl.clear();
                            RelayService.instance.searchResults.value = [];
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Results
            ValueListenableBuilder<List<RelayPeer>>(
              valueListenable: RelayService.instance.searchResults,
              builder: (_, results, __) {
                if (_searching) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (results.isEmpty && _ctrl.text.trim().isNotEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Icon(Icons.person_search_rounded,
                            color: Theme.of(context).hintColor, size: 36),
                        const SizedBox(height: 8),
                        Text(
                          relayConnected
                              ? 'Никого не найдено в сети'
                              : 'Relay не подключён — поиск недоступен',
                          style: TextStyle(
                            color: Theme.of(context).hintColor, fontSize: 13),
                        ),
                        if (_ctrl.text.trim().length >= 8) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _openDirect,
                            icon: const Icon(Icons.chat_bubble_outline, size: 18),
                            label: const Text('Открыть чат по ключу'),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }
                if (results.isEmpty) {
                  return const SizedBox(height: 16);
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final peer = results[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.primary.withValues(alpha: 0.15),
                          child: Text(
                            peer.nick.isNotEmpty
                                ? peer.nick[0].toUpperCase()
                                : '#',
                            style: TextStyle(
                              color: cs.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          peer.nick.isNotEmpty ? peer.nick : peer.shortId,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          peer.shortId,
                          style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8, height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text('в сети',
                                style: TextStyle(
                                  fontSize: 11, color: cs.onSurfaceVariant)),
                          ],
                        ),
                        onTap: () => widget.onOpenChat(
                          peer.publicKey,
                          peer.nick.isNotEmpty ? peer.nick : peer.shortId,
                          0xFF607D8B,
                          '',
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            // Direct open button when results present
            if (_ctrl.text.trim().length >= 32)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextButton.icon(
                  onPressed: _openDirect,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text('Открыть чат напрямую по ключу'),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
