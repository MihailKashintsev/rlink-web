import 'package:flutter/material.dart';

import '../l10n/app_l10n.dart';
import '../services/app_settings.dart';
import 'rlink_nav_routes.dart';
import 'screens/admin_screen.dart';

/// Диалог пароля админ-панели. При успехе открывает [AdminScreen].
/// Хэш пароля хранится в [AppSettings] и синхронизируется на relay (admin_cfg2).
Future<void> showAdminPasswordDialog(BuildContext context) async {
  final input = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => const _AdminPasswordDialog(),
  );
  if (input == null) return;
  if (!context.mounted) return;
  final hash = sha256Hex(input);
  if (hash != AppSettings.instance.adminPasswordHash) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppL10n.t('admin_wrong_password')),
        backgroundColor: Colors.red,
      ),
    );
    return;
  }
  Navigator.push(context, rlinkPushRoute(const AdminScreen()));
}

class _AdminPasswordDialog extends StatefulWidget {
  const _AdminPasswordDialog();

  @override
  State<_AdminPasswordDialog> createState() => _AdminPasswordDialogState();
}

class _AdminPasswordDialogState extends State<_AdminPasswordDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppL10n.t('admin_access_title')),
      content: TextField(
        controller: _ctrl,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(
          labelText: AppL10n.t('admin_password_label'),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppL10n.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(AppL10n.t('admin_login')),
        ),
      ],
    );
  }
}
