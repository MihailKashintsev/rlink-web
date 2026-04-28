import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../app_version.dart';
import '../../l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../models/user_profile.dart';
import '../../services/app_settings.dart';
import '../../services/app_icon_service.dart';
import '../widgets/message_cache_clear_dialog.dart';
import '../../services/ble_service.dart';
import '../../services/connection_transport.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../../services/runtime_platform.dart';
import '../../services/sound_effects_service.dart';
import '../../services/web_identity_portable.dart';
import '../screens/stickers_hub_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../widgets/avatar_widget.dart';
import '../screens/about_screen.dart';
import '../screens/documentation_screen.dart';
import '../screens/settings_data_page.dart';
import '../../main.dart' show sendProfileToAllContacts;
import '../widgets/reactions.dart';
import '../rlink_nav_routes.dart';

// ─────────────────────────────────────────────────────────────────────
// Shared top-level helpers
// ─────────────────────────────────────────────────────────────────────

/// Returns a consistently styled Scaffold for settings sub-screens.
Scaffold _subScaffold({
  required BuildContext context,
  required String title,
  required Widget body,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Scaffold(
    backgroundColor:
        isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8),
    appBar: AppBar(
      title: Text(title),
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF2F2F2),
    ),
    body: body,
  );
}

/// Unlink linked device — used from both NetworkPage and child-device mode.
Future<void> _doUnlinkDevice(BuildContext context) async {
  final settings = AppSettings.instance;
  final linkedKey = settings.linkedDevicePublicKey;
  final myProfile = ProfileService.instance.profile;
  if (linkedKey.isNotEmpty &&
      myProfile != null &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(linkedKey)) {
    await RelayService.instance.connect();
    await GossipRouter.instance.sendDeviceUnlink(
      publicKey: myProfile.publicKeyHex,
      recipientId: linkedKey,
    );
  }
  await settings.unlinkDevice();
  await applyConnectionTransport();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Связка устройств снята')),
  );
}

// ─────────────────────────────────────────────────────────────────────
// Main Settings Screen — category tiles
// ─────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (settings.isLinkedChildDevice && !RuntimePlatform.isWeb) {
      return _buildChildLinkedScreen(context, settings, isDark);
    }

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8),
      appBar: AppBar(
        title: Text(AppL10n.t('settings')),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor:
            isDark ? const Color(0xFF121212) : const Color(0xFFF2F2F2),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          // ── Profile mini-card ────────────────────────────────────
          _ProfileMiniCard(
            onTap: () => _push(context, const _ProfilePage()),
          ),
          const SizedBox(height: 12),

          const SettingsCategoryCards(),

          const SizedBox(height: 32),

          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
              child: Text(
                'Rlink v${AppVersion.label} • ${AppL10n.t('footer_ble_mesh')}',
                style: TextStyle(
                    color: Theme.of(context).hintColor, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, rlinkPushRoute(page));
  }

  // ── Child linked-device restricted settings ────────────────────────

  Widget _buildChildLinkedScreen(
    BuildContext context,
    AppSettings settings,
    bool isDark,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8),
      appBar: AppBar(
        title: Text(AppL10n.t('settings')),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor:
            isDark ? const Color(0xFF121212) : const Color(0xFFF2F2F2),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          const _SectionHeader('Режим дочернего устройства'),
          ListTile(
            leading: Icon(Icons.lock_person_outlined, color: cs.primary),
            title: const Text('Доступ ограничен'),
            subtitle: const Text(
              'В этом режиме доступны только переписка и отвязка устройства.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('Связано с'),
            subtitle: Text(
              settings.linkedDeviceNickname.isNotEmpty
                  ? settings.linkedDeviceNickname
                  : settings.linkedDevicePublicKey,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link_off_rounded, color: Colors.red),
            title: const Text(
              'Отвязаться от главного устройства',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () => _doUnlinkDevice(context),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Profile mini-card shown at the top of Settings
// ─────────────────────────────────────────────────────────────────────

class _ProfileMiniCard extends StatelessWidget {
  final VoidCallback onTap;
  const _ProfileMiniCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            if (profile != null)
              AvatarWidget(
                initials: profile.initials,
                color: profile.avatarColor,
                emoji: profile.avatarEmoji,
                imagePath: profile.avatarImagePath,
                size: 52,
              )
            else
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person, color: cs.primary, size: 28),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile?.nickname.isNotEmpty == true
                        ? profile!.nickname
                        : 'Без имени',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profile != null
                        ? (profile.username.isNotEmpty
                            ? '@${profile.username}'
                            : '${profile.publicKeyHex.substring(0, 12)}...')
                        : 'Настройте профиль',
                    style: TextStyle(
                      fontSize: 12,
                      color: profile?.username.isNotEmpty == true
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      fontFamily: profile?.username.isNotEmpty == true
                          ? null
                          : 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Category group / item widgets
// ─────────────────────────────────────────────────────────────────────

class _CategoryItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _CategoryItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
}

class _CategoryGroup extends StatelessWidget {
  final bool isDark;
  final List<_CategoryItem> items;

  const _CategoryGroup({
    required this.isDark,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 58,
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
            _buildTile(context, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, _CategoryItem item) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: item.color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(item.icon, size: 19, color: item.color),
      ),
      title: Text(item.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400)),
      subtitle: Text(
        item.subtitle,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right,
          color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
      onTap: item.onTap,
    );
  }
}

/// Те же карточки категорий, что на корне [SettingsScreen] — для вкладки «Я» и единообразия.
class SettingsCategoryCards extends StatelessWidget {
  const SettingsCategoryCards({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.push(context, rlinkPushRoute(page));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CategoryGroup(isDark: isDark, items: [
          _CategoryItem(
            icon: Icons.palette_outlined,
            color: const Color(0xFF9C27B0),
            title: AppL10n.t('settings_appearance'),
            subtitle: 'Тема, цвета, шрифт, фон',
            onTap: () => _open(context, const _AppearancePage()),
          ),
          _CategoryItem(
            icon: Icons.notifications_outlined,
            color: const Color(0xFFF44336),
            title: AppL10n.t('settings_notifications'),
            subtitle: 'Звуки, рингтон, вибрация',
            onTap: () => _open(context, const _NotificationsPage()),
          ),
        ]),
        const SizedBox(height: 8),
        _CategoryGroup(isDark: isDark, items: [
          _CategoryItem(
            icon: Icons.chat_bubble_outline,
            color: const Color(0xFF2196F3),
            title: AppL10n.t('settings_messaging'),
            subtitle: 'Отправка, медиа, память',
            onTap: () => _open(context, const _MessagingPage()),
          ),
          _CategoryItem(
            icon: Icons.lock_outline,
            color: const Color(0xFF4CAF50),
            title: AppL10n.t('settings_privacy'),
            subtitle: 'Прочтение, статус онлайн',
            onTap: () => _open(context, const _PrivacyPage()),
          ),
        ]),
        const SizedBox(height: 8),
        _CategoryGroup(isDark: isDark, items: [
          _CategoryItem(
            icon: Icons.wifi_tethering_rounded,
            color: const Color(0xFF009688),
            title: AppL10n.t('settings_section_network'),
            subtitle: 'BLE, интернет, ретранслятор',
            onTap: () => _open(context, const _NetworkPage()),
          ),
        ]),
        const SizedBox(height: 8),
        _CategoryGroup(isDark: isDark, items: [
          _CategoryItem(
            icon: Icons.storage_outlined,
            color: const Color(0xFF795548),
            title: AppL10n.t('settings_data'),
            subtitle: 'История, контакты, сброс',
            onTap: () => _open(context, const SettingsDataPage()),
          ),
          _CategoryItem(
            icon: Icons.menu_book_outlined,
            color: const Color(0xFF3949AB),
            title: 'Документация',
            subtitle: 'Rlink, боты Lib, python -m rlink_bot onboard — RU / EN',
            onTap: () => DocumentationScreen.open(context),
          ),
          _CategoryItem(
            icon: Icons.info_outline_rounded,
            color: const Color(0xFF607D8B),
            title: AppL10n.t('about_title'),
            subtitle: 'Rlink v${AppVersion.label}',
            onTap: () => _open(context, const AboutScreen()),
          ),
        ]),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Appearance
// ─────────────────────────────────────────────────────────────────────

class _AppearancePage extends StatefulWidget {
  const _AppearancePage();

  @override
  State<_AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<_AppearancePage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_appearance'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          // ── Язык ─────────────────────────────────────────────────
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

          // ── Тема ─────────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_appearance')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppL10n.t('settings_theme'),
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
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
                Text(AppL10n.t('settings_accent_color'),
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children:
                      List.generate(AppSettings.accentColors.length, (i) {
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
                              ? [
                                  BoxShadow(
                                      color: color.withValues(alpha: 0.5),
                                      blurRadius: 8)
                                ]
                              : null,
                        ),
                        child: selected
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 18)
                            : null,
                      ),
                    );
                  }),
                ),
                if (RuntimePlatform.isIos || RuntimePlatform.isAndroid) ...[
                  const SizedBox(height: 20),
                  Text(AppL10n.t('settings_app_icon'),
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).hintColor)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _AppIconChoiceChip(
                        label: AppL10n.t('settings_app_icon_variant_classic'),
                        selected: settings.appIconVariant == 0,
                        onTap: () async {
                          await settings.setAppIconVariant(0);
                          await AppIconService.setVariant(0);
                        },
                      ),
                      _AppIconChoiceChip(
                        label: 'Mono',
                        selected: settings.appIconVariant == 1,
                        onTap: () async {
                          await settings.setAppIconVariant(1);
                          await AppIconService.setVariant(1);
                        },
                      ),
                      _AppIconChoiceChip(
                        label: AppL10n.t('settings_app_icon_variant_ai'),
                        selected: settings.appIconVariant == 2,
                        onTap: () async {
                          await settings.setAppIconVariant(2);
                          await AppIconService.setVariant(2);
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // Font size
          ListTile(
            leading: Icon(Icons.format_size, color: cs.primary),
            title: Text(AppL10n.t('settings_font_size')),
            subtitle: Text(
              [
                AppL10n.t('settings_font_small'),
                AppL10n.t('settings_font_medium'),
                AppL10n.t('settings_font_large')
              ][settings.fontSize],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _SizeChip(
                label: 'A',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 0,
                onTap: () => settings.setFontSize(0),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: 'A',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 1,
                onTap: () => settings.setFontSize(1),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: 'A',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 2,
                onTap: () => settings.setFontSize(2),
              ),
            ]),
          ),

          if (RuntimePlatform.isAndroid)
            SwitchListTile(
              secondary:
                  Icon(Icons.emoji_emotions_outlined, color: cs.primary),
              title: Text(AppL10n.t('settings_ios_emoji')),
              subtitle: Text(AppL10n.t('settings_ios_emoji_sub'),
                  style: const TextStyle(fontSize: 12)),
              value: settings.useIosStyleEmoji,
              onChanged: (v) => settings.setUseIosStyleEmoji(v),
            ),

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
            title: Text(AppL10n.t('settings_message_style')),
            subtitle: Text(
              [
                AppL10n.t('settings_bubble_rounded'),
                AppL10n.t('settings_bubble_square'),
                AppL10n.t('settings_bubble_minimal'),
              ][settings.bubbleStyle],
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
            title: Text(AppL10n.t('settings_message_density')),
            subtitle: Text(
              [
                AppL10n.t('settings_density_relaxed'),
                AppL10n.t('settings_density_normal'),
                AppL10n.t('settings_density_compact'),
              ][settings.messageDensity],
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
            title: Text(AppL10n.t('settings_time_format')),
            subtitle: Text(
              settings.clockFormat == 0
                  ? AppL10n.t('settings_clock_24h')
                  : AppL10n.t('settings_clock_12h'),
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

          // Reactions
          SwitchListTile(
            secondary:
                Icon(Icons.emoji_emotions_outlined, color: cs.primary),
            title: Text(AppL10n.t('settings_reaction_quick_bar')),
            subtitle: Text(AppL10n.t('settings_reaction_quick_bar_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showReactionsQuickBar,
            onChanged: (v) => settings.setShowReactionsQuickBar(v),
          ),

          ListTile(
            leading: Icon(Icons.touch_app_outlined, color: cs.primary),
            title: Text(AppL10n.t('settings_quick_reaction_double_tap')),
            subtitle: Text(
              '${AppL10n.t('settings_quick_reaction_now')}${settings.quickReactionEmoji}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Text(settings.quickReactionEmoji,
                style: const TextStyle(fontSize: 22)),
            onTap: () async {
              final picked = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(AppL10n.t('settings_quick_reaction_title')),
                  content: SizedBox(
                    width: 320,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      alignment: WrapAlignment.center,
                      children: kReactionEmojis.map((e) {
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.pop(ctx, e),
                          child: Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: e == settings.quickReactionEmoji
                                    ? Theme.of(ctx).colorScheme.primary
                                    : Theme.of(ctx)
                                        .colorScheme
                                        .outlineVariant,
                                width:
                                    e == settings.quickReactionEmoji ? 2 : 1,
                              ),
                            ),
                            child: Text(e,
                                style: const TextStyle(fontSize: 26)),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(AppL10n.t('cancel')),
                    ),
                  ],
                ),
              );
              final e = (picked ?? '').trim();
              if (e.isNotEmpty) {
                await settings.setQuickReactionEmoji(e);
              }
            },
          ),

          // ── Фон чата ─────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_chat_bg')),
          _ChatBgTile(settings: settings),
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
              final cs = Theme.of(context).colorScheme;
              final Widget? subtitle;
              if (locale.showPartialUiHint) {
                subtitle = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppL10n.t('locale_ui_partial_note'),
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.25,
                            color: cs.tertiary)),
                    const SizedBox(height: 2),
                    Text(locale.name,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor)),
                  ],
                );
              } else if (locale.code != 'system') {
                subtitle = Text(locale.name,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor));
              } else {
                subtitle = null;
              }
              return ListTile(
                title: Text(locale.nativeName),
                subtitle: subtitle,
                isThreeLine: locale.showPartialUiHint,
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
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Notifications
// ─────────────────────────────────────────────────────────────────────

class _NotificationsPage extends StatefulWidget {
  const _NotificationsPage();

  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<_NotificationsPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_notifications'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
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
          ListTile(
            leading: Icon(
              Icons.ring_volume_rounded,
              color: settings.notificationsEnabled
                  ? cs.primary
                  : Theme.of(context).hintColor,
            ),
            title: const Text('Рингтон звонка'),
            subtitle: Text(
              _ringtoneLabel(settings.callRingtone),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: settings.notificationsEnabled,
            onTap: settings.notificationsEnabled
                ? () => _pickRingtone(context, settings)
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
          SwitchListTile(
            secondary: Icon(Icons.chat_bubble_outline,
                color: settings.notifyPersonal && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_personal')),
            value: settings.notifyPersonal,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifyPersonal(v)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.groups_2_outlined,
                color: settings.notifyGroups && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_groups')),
            value: settings.notifyGroups,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifyGroups(v)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.campaign_outlined,
                color:
                    settings.notifyChannels && settings.notificationsEnabled
                        ? cs.primary
                        : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_channels')),
            value: settings.notifyChannels,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifyChannels(v)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.45)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 20, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        AppL10n.t('settings_notif_background_warning'),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _ringtoneLabel(int ringtone) {
    switch (ringtone.clamp(0, 2)) {
      case 1:
        return 'Digital Pulse';
      case 2:
        return 'Soft Bell';
      case 0:
      default:
        return 'Classic Ring';
    }
  }

  Future<void> _pickRingtone(
      BuildContext context, AppSettings settings) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Выберите рингтон'),
              subtitle: Text('Будет проигрываться при входящем звонке',
                  style: TextStyle(fontSize: 12)),
            ),
            for (final idx in const [0, 1, 2])
              RadioListTile<int>(
                value: idx,
                groupValue: settings.callRingtone,
                title: Text(_ringtoneLabel(idx)),
                onChanged: (v) => Navigator.pop(ctx, v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await settings.setCallRingtone(picked);
    // Short preview of selected ringtone
    await SoundEffectsService.instance.startIncomingRingtone();
    await Future.delayed(const Duration(milliseconds: 1200));
    await SoundEffectsService.instance.stopIncomingRingtone();
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Privacy
// ─────────────────────────────────────────────────────────────────────

class _PrivacyPage extends StatefulWidget {
  const _PrivacyPage();

  @override
  State<_PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<_PrivacyPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_privacy'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_privacy')),
          SwitchListTile(
            secondary: Icon(Icons.done_all_rounded,
                color: settings.showReadReceipts
                    ? cs.primary
                    : Theme.of(context).hintColor),
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
          _SectionHeader(AppL10n.t('settings_section_presence')),
          _OnlineStatusSelector(
            current: settings.onlineStatusMode,
            onChanged: (mode) => settings.setOnlineStatusMode(mode),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Messaging
// ─────────────────────────────────────────────────────────────────────

class _MessagingPage extends StatefulWidget {
  const _MessagingPage();

  @override
  State<_MessagingPage> createState() => _MessagingPageState();
}

class _MessagingPageState extends State<_MessagingPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_messaging'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_messaging')),
          SwitchListTile(
            secondary: Icon(Icons.keyboard_return_rounded,
                color: settings.sendOnEnter
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_send_on_enter')),
            subtitle: Text(AppL10n.t('settings_send_on_enter_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.sendOnEnter,
            onChanged: (v) => settings.setSendOnEnter(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.download_for_offline_outlined,
                color: settings.autoDownloadMedia
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_auto_download')),
            subtitle: Text(AppL10n.t('settings_auto_download_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.autoDownloadMedia,
            onChanged: (v) => settings.setAutoDownloadMedia(v),
          ),
          _SectionHeader(AppL10n.t('settings_section_memory')),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined, color: cs.error),
            title: Text(AppL10n.t('settings_clear_convo_cache')),
            subtitle: Text(
              AppL10n.t('settings_clear_convo_cache_sub'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            onTap: () => showMessageCacheClearDialog(context),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Profile
// ─────────────────────────────────────────────────────────────────────

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_profile'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_profile')),
          if (profile != null)
            ListTile(
              leading:
                  Icon(Icons.emoji_emotions_outlined, color: cs.primary),
              title: const Text('Эмодзи-статус'),
              subtitle: Text(
                profile.statusEmoji.isEmpty
                    ? 'Рядом с именем в меню; виден контактам в сети'
                    : profile.statusEmoji,
                style: TextStyle(
                  fontSize: profile.statusEmoji.isEmpty ? 12 : 20,
                  color: profile.statusEmoji.isEmpty
                      ? cs.onSurfaceVariant
                      : cs.onSurface,
                ),
              ),
              trailing: profile.statusEmoji.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Убрать',
                      onPressed: () => _clearEmojiStatus(),
                    )
                  : null,
              onTap: () => _pickEmojiStatus(context),
            ),
          ListTile(
            leading:
                Icon(Icons.auto_awesome_motion_outlined, color: cs.primary),
            title: const Text('Стикеры и наборы'),
            subtitle: const Text(
              'Свои наборы и добавление стикеров из переписки',
              style: TextStyle(fontSize: 12),
            ),
            onTap: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const StickersHubScreen()),
            ),
          ),
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
                  SnackBar(
                      content: Text(AppL10n.t('settings_key_copied'))),
                );
              },
            ),
          ),
          _SectionHeader(AppL10n.t('settings_find_user')),
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(AppL10n.t('settings_search_by_id')),
            subtitle: Text(AppL10n.t('settings_search_by_id_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _showSearchById(context),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEmojiStatus(BuildContext context) async {
    final prof = ProfileService.instance.profile;
    if (prof == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Эмодзи-статус',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SizedBox(
                height: 300,
                child: SingleChildScrollView(
                  child: AvatarEmojiPicker(
                    selected: prof.statusEmoji.isNotEmpty
                        ? prof.statusEmoji
                        : UserProfile.avatarEmojis.first,
                    onSelected: (e) async {
                      Navigator.pop(ctx);
                      await ProfileService.instance.updateProfile(
                        statusEmoji: UserProfile.normalizeStatusEmoji(e),
                      );
                      if (!context.mounted) return;
                      setState(() {});
                      await sendProfileToAllContacts();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _clearEmojiStatus() async {
    await ProfileService.instance.updateProfile(statusEmoji: '');
    if (mounted) setState(() {});
    await sendProfileToAllContacts();
  }

  void _showSearchById(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _PeerSearchSheet(
        onOpenChat: (publicKey, nickname, color, emoji,
            {String? relayX25519Key, String? relayUsername}) async {
          Navigator.pop(ctx);
          if (relayX25519Key != null && relayX25519Key.isNotEmpty) {
            BleService.instance
                .registerPeerX25519Key(publicKey, relayX25519Key);
            unawaited(ChatStorageService.instance
                .updateContactX25519Key(publicKey, relayX25519Key));
          }
          var contact =
              await ChatStorageService.instance.getContact(publicKey);
          final finalNick = contact?.nickname ?? nickname;
          final finalColor = contact?.avatarColor ?? color;
          final finalEmoji = contact?.avatarEmoji ?? emoji;
          final imagePath = contact?.avatarImagePath;
          final mergedUsername =
              (relayUsername != null && relayUsername.isNotEmpty)
                  ? relayUsername
                  : (contact?.username ?? '');
          final mergedX25519 =
              (relayX25519Key != null && relayX25519Key.isNotEmpty)
                  ? relayX25519Key
                  : contact?.x25519Key;
          if (contact == null) {
            await ChatStorageService.instance.saveContact(Contact(
              publicKeyHex: publicKey,
              nickname: finalNick,
              username: mergedUsername,
              avatarColor: finalColor,
              avatarEmoji: finalEmoji,
              x25519Key: mergedX25519,
              addedAt: DateTime.now(),
            ));
          } else if (mergedUsername != contact.username ||
              mergedX25519 != contact.x25519Key ||
              finalNick != contact.nickname) {
            await ChatStorageService.instance.saveContact(contact.copyWith(
              nickname: finalNick,
              username: mergedUsername,
              x25519Key: mergedX25519,
            ));
          }
          contact =
              await ChatStorageService.instance.getContact(publicKey);
          final openNick = contact?.nickname ?? finalNick;
          final openColor = contact?.avatarColor ?? finalColor;
          final openEmoji = contact?.avatarEmoji ?? finalEmoji;
          final openImage = contact?.avatarImagePath ?? imagePath;
          if (context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  peerId: publicKey,
                  peerNickname: openNick,
                  peerAvatarColor: openColor,
                  peerAvatarEmoji: openEmoji,
                  peerAvatarImagePath: openImage,
                ),
              ),
            );
          }
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Network
// ─────────────────────────────────────────────────────────────────────

class _NetworkPage extends StatefulWidget {
  const _NetworkPage();

  @override
  State<_NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<_NetworkPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_section_network'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          // ── Связка устройств ──────────────────────────────────────
          _SectionHeader('Связка устройств'),
          if (settings.isDeviceLinked) ...[
            ListTile(
              leading: Icon(
                settings.isPrimaryDevice
                    ? Icons.admin_panel_settings_outlined
                    : Icons.phone_iphone_rounded,
                color: cs.primary,
              ),
              title: Text(settings.isPrimaryDevice
                  ? 'Главное устройство'
                  : 'Дочернее устройство'),
              subtitle: Text(
                settings.linkedDeviceNickname.isNotEmpty
                    ? 'Связано: ${settings.linkedDeviceNickname}'
                    : settings.linkedDevicePublicKey,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.link_off_rounded, color: Colors.red),
              title: const Text('Отвязать устройство',
                  style: TextStyle(color: Colors.red)),
              subtitle: const Text(
                  'Связка будет снята на обоих устройствах',
                  style: TextStyle(fontSize: 12)),
              onTap: () => _doUnlinkDevice(context),
            ),
          ] else ...[
            ListTile(
              leading: Icon(Icons.link_rounded, color: cs.primary),
              title: const Text('Привязать дочернее устройство'),
              subtitle: const Text(
                  'Выберите контакт и отправьте запрос на связку',
                  style: TextStyle(fontSize: 12)),
              onTap: _requestDeviceLink,
            ),
          ],

          // ── Тип связи ──────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_connection_type')),
          ListTile(
            leading: Icon(Icons.swap_horiz_rounded, color: cs.primary),
            title: Text(AppL10n.t('settings_connection_type')),
            subtitle: Text(
              [
                AppL10n.t('conn_mode_ble_only'),
                AppL10n.t('conn_mode_internet_only'),
                AppL10n.t('conn_mode_all'),
              ][settings.connectionMode],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: RuntimePlatform.isWeb
                ? Row(children: [
                    _NetChip(
                      icon: Icons.wifi,
                      label: AppL10n.t('net_label_internet'),
                      selected: true,
                      onTap: () => _setConnectionMode(1),
                    ),
                  ])
                : Row(children: [
                    _NetChip(
                      icon: Icons.bluetooth,
                      label: 'BLE',
                      selected: settings.connectionMode == 0,
                      onTap: () => _setConnectionMode(0),
                    ),
                    const SizedBox(width: 8),
                    _NetChip(
                      icon: Icons.wifi,
                      label: AppL10n.t('net_label_internet'),
                      selected: settings.connectionMode == 1,
                      onTap: () => _setConnectionMode(1),
                    ),
                    const SizedBox(width: 8),
                    _NetChip(
                      icon: Icons.sync_alt_rounded,
                      label: AppL10n.t('net_label_both'),
                      selected: settings.connectionMode == 2,
                      onTap: () => _setConnectionMode(2),
                    ),
                  ]),
          ),
          if (RuntimePlatform.isWeb)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text('В web-версии доступен только интернет-режим.',
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          if (RuntimePlatform.isWeb)
            ListTile(
              leading: Icon(Icons.key_rounded, color: cs.primary),
              title: const Text('Скачать файл ключа входа'),
              subtitle: const Text(
                'Сохраните JSON в надёжное место — это ваш ID и логин для web. '
                'Восстановление — на экране регистрации.',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () async {
                await WebIdentityPortable.exportIdentityKeyDownload();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Файл скачан')),
                  );
                }
              },
            ),
          if (settings.isDeviceLinked)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'В режиме связки Bluetooth автоматически выключен, '
                'используется только интернет.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          if (RuntimePlatform.isAndroid && settings.connectionMode == 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                AppL10n.t('wifi_direct_note_android'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 12),

          // Media priority
          if (settings.connectionMode == 2) ...[
            ListTile(
              leading: Icon(Icons.perm_media_outlined, color: cs.primary),
              title: Text(AppL10n.t('settings_media_priority')),
              subtitle: Text(
                settings.mediaPriority == 0
                    ? AppL10n.t('media_send_via_bt')
                    : AppL10n.t('media_send_via_internet'),
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
                  label: AppL10n.t('net_label_internet'),
                  selected: settings.mediaPriority == 1,
                  onTap: () => settings.setMediaPriority(1),
                ),
              ]),
            ),
            const SizedBox(height: 12),
          ],

          // ── Ретранслятор ───────────────────────────────────────────
          if (settings.connectionMode >= 1) ...[
            _SectionHeader('Ретранслятор'),
            ValueListenableBuilder<RelayState>(
              valueListenable: RelayService.instance.state,
              builder: (_, relayState, __) {
                final connected = relayState == RelayState.connected;
                final connecting = relayState == RelayState.connecting;
                return ValueListenableBuilder<int>(
                  valueListenable: RelayService.instance.onlineCount,
                  builder: (_, count, __) =>
                      ValueListenableBuilder<String?>(
                    valueListenable: RelayService.instance.lastError,
                    builder: (_, lastErr, __) => ListTile(
                      leading: Icon(
                        connected
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        color: connected
                            ? const Color(0xFF4CAF50)
                            : connecting
                                ? Colors.amber
                                : Colors.red,
                      ),
                      title: Text(connected
                          ? AppL10n.t('relay_server_connected')
                          : connecting
                              ? AppL10n.t('relay_server_connecting')
                              : AppL10n.t('relay_server_unavailable')),
                      subtitle: Text(
                        connected
                            ? AppL10n.t('relay_online')
                                .replaceAll('{n}', '$count')
                            : ((lastErr != null && lastErr.isNotEmpty)
                                ? '${AppL10n.t('relay_no_connection')}\n$lastErr'
                                : AppL10n.t('relay_no_connection')),
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      trailing: connecting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : IconButton(
                              icon: const Icon(Icons.refresh, size: 20),
                              tooltip: connected
                                  ? AppL10n.t('tool_reconnect')
                                  : AppL10n.t('tool_connect'),
                              onPressed: () =>
                                  RelayService.instance.reconnect(),
                            ),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.bug_report_outlined, color: cs.primary),
              title: const Text('Диагностика связи'),
              subtitle: ValueListenableBuilder<String?>(
                valueListenable: RelayService.instance.lastError,
                builder: (_, lastErr, __) {
                  final pk = CryptoService.instance.publicKeyHex;
                  final shortPk =
                      pk.isEmpty ? 'empty' : '${pk.substring(0, 8)}...';
                  final relayState =
                      RelayService.instance.state.value.name;
                  final online = RelayService.instance.onlineCount.value;
                  final err = (lastErr == null || lastErr.isEmpty)
                      ? '-'
                      : lastErr.replaceAll('\n', ' ');
                  return Text(
                    'pk=$shortPk, relay=$relayState, online=$online, err=$err',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant),
                  );
                },
              ),
              trailing: const Icon(Icons.copy_rounded, size: 18),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final pk = CryptoService.instance.publicKeyHex;
                final relayState =
                    RelayService.instance.state.value.name;
                final online = RelayService.instance.onlineCount.value;
                final err =
                    RelayService.instance.lastError.value ?? '-';
                final diag = [
                  'pk=${pk.isEmpty ? 'empty' : pk}',
                  'relay=$relayState',
                  'online=$online',
                  'err=$err',
                  'url=${RelayService.instance.serverUrl ?? '-'}',
                ].join('\n');
                await Clipboard.setData(ClipboardData(text: diag));
                if (!context.mounted) return;
                messenger.showSnackBar(
                  const SnackBar(
                      content: Text('Диагностика скопирована')),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.list_alt_rounded, color: cs.primary),
              title: const Text('Живой лог доставки'),
              subtitle: const Text(
                'TX/RX/DROP трассировка сообщений и запросов',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const DiagnosticsScreen()),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _setConnectionMode(int mode) async {
    final settings = AppSettings.instance;
    if (RuntimePlatform.isWeb && mode != 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('В web-версии доступен только интернет-режим')),
      );
      return;
    }
    if (settings.isDeviceLinked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'В режиме связки устройств доступен только интернет-режим')),
      );
      return;
    }
    await settings.setConnectionMode(mode);
    await applyConnectionTransport();
  }

  Future<void> _requestDeviceLink() async {
    final settings = AppSettings.instance;
    final myProfile = ProfileService.instance.profile;
    if (myProfile == null) return;
    final contact = await _pickContactForLink(context);
    if (contact == null) return;

    await settings.setConnectionMode(1);
    await applyConnectionTransport();
    await RelayService.instance.connect();
    if (!RelayService.instance.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Не удалось подключиться к интернет-ретранслятору')),
        );
      }
      return;
    }
    await GossipRouter.instance.sendDeviceLinkRequest(
      publicKey: myProfile.publicKeyHex,
      nick: myProfile.nickname,
      username: myProfile.username,
      recipientId: contact.publicKeyHex,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Запрос на связку отправлен: ${contact.nickname}')),
    );
  }

  Future<Contact?> _pickContactForLink(BuildContext context) async {
    final contacts = await ChatStorageService.instance.getContacts();
    if (!context.mounted) return null;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Нет контактов для связки устройств')),
      );
      return null;
    }
    return showModalBottomSheet<Contact>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Выберите устройство'),
              subtitle: Text(
                'Выбранный контакт получит запрос на привязку как дочернего устройства.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            for (final c in contacts)
              ListTile(
                leading: AvatarWidget(
                  initials: c.initials,
                  color: c.avatarColor,
                  emoji: c.avatarEmoji,
                  imagePath: c.avatarImagePath,
                  size: 40,
                ),
                title: Text(c.nickname),
                subtitle: Text(
                  c.username.isNotEmpty ? '#${c.username}' : c.shortId,
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Helper widgets (unchanged)
// ─────────────────────────────────────────────────────────────────────

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
              fontWeight:
                  selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ]),
      ),
    );
  }
}

class _AppIconChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Future<void> Function() onTap;

  const _AppIconChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onTap(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: cs.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? cs.onPrimary : cs.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
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
            Icon(icon,
                size: 20,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Фон чата ──────────────────────────────────────────────────────────

class _ChatBgTile extends StatelessWidget {
  final AppSettings settings;
  const _ChatBgTile({required this.settings});

  Future<void> _pickBg(BuildContext context) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !context.mounted) return;
    if (RuntimePlatform.isWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Фон чата на web пока не поддерживается')),
      );
      return;
    }
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
    final hasBg = !RuntimePlatform.isWeb &&
        bgPath != null &&
        File(bgPath).existsSync();

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: hasBg
            ? Image.file(File(bgPath), width: 44, height: 44, fit: BoxFit.cover)
            : Container(
                width: 44,
                height: 44,
                color: cs.surfaceContainerHigh,
                child: Icon(Icons.wallpaper_outlined,
                    color: cs.onSurfaceVariant),
              ),
      ),
      title: Text(AppL10n.t('settings_chat_bg')),
      subtitle: Text(
        RuntimePlatform.isWeb
            ? 'Недоступно в web-версии'
            : bgPath != null
                ? AppL10n.t('settings_chat_bg_custom')
                : AppL10n.t('settings_chat_bg_none'),
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (bgPath != null)
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: AppL10n.t('settings_chat_bg_remove_tooltip'),
            onPressed: () =>
                settings.setChatBgForPeer('__global__', null),
          ),
        IconButton(
          icon: const Icon(Icons.photo_library_outlined),
          tooltip: AppL10n.t('settings_chat_bg_pick_tooltip'),
          onPressed: () => _pickBg(context),
        ),
      ]),
    );
  }
}

// ── Заголовок секции ───────────────────────────────────────────────────

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

// ── Статус в сети ─────────────────────────────────────────────────────

class _OnlineStatusSelector extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;

  const _OnlineStatusSelector(
      {required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final statuses = [
      (
        icon: Icons.circle,
        color: const Color(0xFF4CAF50),
        label: AppL10n.t('online_status_green'),
        sub: AppL10n.t('online_status_green_sub'),
      ),
      (
        icon: Icons.circle,
        color: const Color(0xFFFFC107),
        label: AppL10n.t('online_status_yellow'),
        sub: AppL10n.t('online_status_yellow_sub'),
      ),
      (
        icon: Icons.circle,
        color: const Color(0xFFF44336),
        label: AppL10n.t('online_status_red'),
        sub: AppL10n.t('online_status_red_sub'),
      ),
    ];
    return Column(
      children: [
        for (var i = 0; i < statuses.length; i++)
          RadioListTile<int>(
            value: i,
            groupValue: current,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            secondary: Icon(statuses[i].icon,
                color: statuses[i].color, size: 14),
            title: Text(statuses[i].label),
            subtitle: Text(statuses[i].sub,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant)),
            dense: true,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Icon(Icons.circle, color: Colors.grey.shade500, size: 10),
            const SizedBox(width: 8),
            Text(AppL10n.t('online_status_gray_hint'),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor)),
          ]),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ── Поиск собеседника (relay + прямой ключ) ────────────────────────────

class _PeerSearchSheet extends StatefulWidget {
  final void Function(
    String publicKey,
    String nickname,
    int color,
    String emoji, {
    String? relayX25519Key,
    String? relayUsername,
  }) onOpenChat;

  const _PeerSearchSheet({required this.onOpenChat});

  @override
  State<_PeerSearchSheet> createState() => _PeerSearchSheetState();
}

class _PeerSearchSheetState extends State<_PeerSearchSheet> {
  final _ctrl = TextEditingController();
  bool _searching = false;
  Timer? _debounce;
  static final RegExp _pubKey64 = RegExp(r'^[0-9a-fA-F]{64}$');

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
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
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _searching = false);
      });
    });
  }

  void _openDirect() {
    final raw = _ctrl.text.trim();
    if (raw.isEmpty) return;
    String? id;
    if (_pubKey64.hasMatch(raw)) {
      id = raw.toLowerCase();
    } else if (raw.length >= 8) {
      id = RelayService.instance.findPeerByPrefix(raw.toLowerCase());
    }
    if (id == null || !_pubKey64.hasMatch(id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Нужен полный ключ (64 hex) или онлайн-пир по короткому коду'),
        ),
      );
      return;
    }
    widget.onOpenChat(id, '${id.substring(0, 8)}...', 0xFF607D8B, '');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final relayConnected = RelayService.instance.isConnected;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
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
            Text(AppL10n.t('peer_search_title'),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              relayConnected
                  ? AppL10n.t('peer_search_sub_connected')
                  : AppL10n.t('peer_search_sub_disconnected'),
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: AppL10n.t('peer_search_hint'),
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
                            RelayService.instance.searchResults.value =
                                [];
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
            ValueListenableBuilder<List<RelayPeer>>(
              valueListenable: RelayService.instance.searchResults,
              builder: (_, results, __) {
                if (_searching) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
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
                              ? AppL10n.t('peer_not_found_online')
                              : AppL10n.t('peer_relay_off_no_search'),
                          style: TextStyle(
                              color: Theme.of(context).hintColor,
                              fontSize: 13),
                        ),
                        if (_ctrl.text.trim().length >= 8) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _openDirect,
                            icon: const Icon(Icons.chat_bubble_outline,
                                size: 18),
                            label: Text(
                                AppL10n.t('peer_open_chat_by_key')),
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
                          backgroundColor:
                              cs.primary.withValues(alpha: 0.15),
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
                          style:
                              const TextStyle(fontWeight: FontWeight.w500),
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
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(AppL10n.t('peer_online'),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant)),
                          ],
                        ),
                        onTap: () => widget.onOpenChat(
                          peer.publicKey,
                          peer.nick.isNotEmpty
                              ? peer.nick
                              : peer.shortId,
                          0xFF607D8B,
                          '',
                          relayX25519Key: peer.x25519Key.isNotEmpty
                              ? peer.x25519Key
                              : null,
                          relayUsername: peer.username.isNotEmpty
                              ? peer.username
                              : null,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            if (_ctrl.text.trim().length >= 32)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextButton.icon(
                  onPressed: _openDirect,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(AppL10n.t('peer_open_direct_by_key')),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
