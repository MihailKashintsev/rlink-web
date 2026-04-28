import 'package:flutter/material.dart';

import '../l10n/app_l10n.dart';
import '../services/app_settings.dart';
import 'rlink_nav_routes.dart';
import 'screens/admin_screen.dart';

/// Диалог пароля админ-панели. При успехе открывает [AdminScreen].
/// Хэш пароля хранится в [AppSettings] и синхронизируется на relay (admin_cfg2).
Future<void> showAdminPasswordDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(AppL10n.t('admin_access_title')),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: AppL10n.t('admin_password_label'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _tryAdminUnlock(context, dialogCtx, ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppL10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => _tryAdminUnlock(context, dialogCtx, ctrl.text),
            child: Text(AppL10n.t('admin_login')),
          ),
        ],
      ),
    );
  } finally {
    ctrl.dispose();
  }
}

void _tryAdminUnlock(
  BuildContext hostContext,
  BuildContext dialogCtx,
  String input,
) {
  final hash = sha256Hex(input);
  if (hash != AppSettings.instance.adminPasswordHash) {
    ScaffoldMessenger.of(hostContext).showSnackBar(
      SnackBar(
        content: Text(AppL10n.t('admin_wrong_password')),
        backgroundColor: Colors.red,
      ),
    );
    return;
  }
  Navigator.pop(dialogCtx);
  if (!hostContext.mounted) return;
  Navigator.push(hostContext, rlinkPushRoute(const AdminScreen()));
}
