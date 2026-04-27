import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop (Windows/Linux/macOS): крестик окна не завершает процесс —
/// окно уходит в трей, relay и уведомления продолжают работать.
class DesktopTrayService with WindowListener, TrayListener {
  DesktopTrayService._();
  static final DesktopTrayService instance = DesktopTrayService._();

  bool _ready = false;
  bool _isDesktopPlatform = false;

  Future<void> init() async {
    _isDesktopPlatform =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (!_isDesktopPlatform || _ready) return;
    _ready = true;
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    await trayManager.setIcon('assets/branding/rlink_mark.png');
    await trayManager.setToolTip('Rlink');
    await trayManager.setContextMenu(Menu(
      items: [
        MenuItem(
          key: 'open',
          label: 'Открыть Rlink',
          onClick: (_) => unawaited(showWindow()),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Выход',
          onClick: (_) => unawaited(quitCompletely()),
        ),
      ],
    ));
    trayManager.addListener(this);
  }

  Future<void> showWindow() async {
    if (!_isDesktopPlatform) return;
    await windowManager.show();
    await windowManager.setSkipTaskbar(false);
    await windowManager.focus();
  }

  Future<void> quitCompletely() async {
    if (!_isDesktopPlatform) return;
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  @override
  void onWindowClose() {
    if (!_isDesktopPlatform) return;
    unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() {
    if (!_isDesktopPlatform) return;
    unawaited(showWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(showWindow());
        break;
      case 'quit':
        unawaited(quitCompletely());
        break;
    }
  }
}
