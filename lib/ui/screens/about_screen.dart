import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_l10n.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _websiteUrl = 'https://rendergames.online/rlink';
  static const _telegramUrl  = 'https://t.me/rendergm';
  static const _boostyUrl    = 'https://boosty.to/rendergamesru/purchase/3242287?ssource=DIRECT&share=subscription_link';
  static const _githubUrl    = 'https://github.com/MihailKashintsev/';

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppL10n.t('error')}: $url')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t('about_title'))),
      body: ListView(
        children: [
          // ── App hero ──────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32),
            alignment: Alignment.center,
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) {
                final version = snap.data?.version ?? '0.0.5';
                return Column(children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: cs.primary.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.bluetooth_rounded,
                    color: Colors.white, size: 48),
              ),
              const SizedBox(height: 16),
              Text(
                'Rlink',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${AppL10n.t('about_version')} $version',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  AppL10n.t('about_description'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    height: 1.5,
                  ),
                ),
              ),
                ]);
              },
            ),
          ),

          // ── Social links ─────────────────────────────────────────
          _SectionHeader(AppL10n.t('about_links')),

          _LinkTile(
            icon: Icons.language_rounded,
            iconColor: const Color(0xFF2196F3),
            title: AppL10n.t('about_website'),
            subtitle: 'rendergames.online/rlink',
            onTap: () => _open(context, _websiteUrl),
          ),
          _LinkTile(
            icon: Icons.send_rounded,
            iconColor: const Color(0xFF0088CC),
            title: AppL10n.t('about_telegram'),
            subtitle: '@rendergm',
            onTap: () => _open(context, _telegramUrl),
          ),
          _LinkTile(
            icon: Icons.favorite_rounded,
            iconColor: const Color(0xFFE91E63),
            title: AppL10n.t('about_support'),
            subtitle: 'boosty.to/rendergamesru',
            onTap: () => _open(context, _boostyUrl),
          ),
          _LinkTile(
            icon: Icons.code_rounded,
            iconColor: const Color(0xFF333333),
            title: AppL10n.t('about_github'),
            subtitle: 'github.com/MihailKashintsev',
            onTap: () => _open(context, _githubUrl),
          ),

          // ── Developer ────────────────────────────────────────────
          _SectionHeader(AppL10n.t('about_developer')),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.primary.withValues(alpha: 0.15),
              child: Text('M',
                  style: TextStyle(
                      color: cs.primary, fontWeight: FontWeight.w700)),
            ),
            title: const Text('Mihail Kashintsev'),
            subtitle: const Text('Rendergames'),
          ),

          const SizedBox(height: 32),

          // ── Tech info ────────────────────────────────────────────
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) {
              final version = snap.data?.version ?? '0.0.5';
              return Center(
                child: Text(
                  'Rlink v$version • BLE Mesh Messenger\nFlutter • Dart • Ed25519 + ChaCha20',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LinkTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title),
      subtitle: Text(subtitle,
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).hintColor)),
      trailing: Icon(Icons.open_in_new_rounded,
          size: 16, color: Theme.of(context).hintColor),
      onTap: onTap,
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
          color: Theme.of(context).hintColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
