import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Переходы в стиле iOS: свайп от левого края для возврата (на iOS и в типичной конфигурации).
Route<T> rlinkPushRoute<T>(Widget page) {
  return CupertinoPageRoute<T>(
    builder: (_) => page,
  );
}

bool get _rlinkSkipChatEnterFade {
  if (kIsWeb) return false;
  try {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  } catch (_) {
    return false;
  }
}

/// Открытие личного чата: Cupertino + плавное проявление от прозрачности.
Route<T> rlinkChatRoute<T>(Widget page) {
  if (_rlinkSkipChatEnterFade) {
    return CupertinoPageRoute<T>(builder: (_) => page);
  }
  return CupertinoPageRoute<T>(
    builder: (context) => _RlinkChatEnterFade(child: page),
  );
}

class _RlinkChatEnterFade extends StatelessWidget {
  final Widget child;

  const _RlinkChatEnterFade({required this.child});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (animation == null) return child;

    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      child: child,
    );
  }
}
