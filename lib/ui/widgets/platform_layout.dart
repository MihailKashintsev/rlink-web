import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// «ПК» в смысле десктопных встраиваемых платформ Flutter (не мобильный shell).
bool isDesktopShell() {
  if (kIsWeb) return false;
  try {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  } catch (_) {
    return false;
  }
}
