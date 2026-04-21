import 'package:flutter/material.dart';

import '../../services/update_service.dart';
import 'update_progress_dialog.dart';

/// Подписка на [pendingUpdateNotifier] и показ баннера «доступно обновление».
mixin UpdateAvailableBannerMixin<T extends StatefulWidget> on State<T> {
  void registerUpdateBannerListener() {
    pendingUpdateNotifier.addListener(_onPendingUpdateNotifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final u = pendingUpdateNotifier.value;
      if (u != null) showUpdateAvailableBanner(u);
    });
  }

  void unregisterUpdateBannerListener() {
    pendingUpdateNotifier.removeListener(_onPendingUpdateNotifier);
  }

  void _onPendingUpdateNotifier() {
    if (!mounted) return;
    final u = pendingUpdateNotifier.value;
    if (u != null) {
      showUpdateAvailableBanner(u);
    }
  }

  void showUpdateAvailableBanner(UpdateInfo update) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text('Доступно обновление ${update.version}'),
        leading: const Icon(Icons.system_update, color: Colors.green),
        actions: [
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              openUpdateFlow(update);
            },
            child: Text(
              update.openExternalDownloadPage ? 'Сайт загрузки' : 'Обновить',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> openUpdateFlow(UpdateInfo update) async {
    if (!mounted) return;
    if (update.openExternalDownloadPage) {
      await UpdateService.instance.downloadAndInstall(update);
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateProgressDialog(update: update),
    );
  }
}
