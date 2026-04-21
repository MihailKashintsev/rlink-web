import 'package:flutter/services.dart';

/// Смена иконки приложения (как в Telegram): классическая, монохром, зеркало, ИИ.
/// На iOS — alternate icons; на Android — activity-alias.
class AppIconService {
  AppIconService._();
  static const _ch = MethodChannel('com.rendergames.rlink/app_icon');

  /// 0 = default, 1 = mono, 2 = mirror, 3 = ai (ИИ Rlink)
  static Future<void> setVariant(int index) async {
    final v = index.clamp(0, 3);
    final name = switch (v) {
      1 => 'mono',
      2 => 'mirror',
      3 => 'ai',
      _ => 'default',
    };
    try {
      await _ch.invokeMethod('setIcon', {'variant': name});
    } on MissingPluginException {
      // Desktop / неподдерживаемая платформа
    }
  }
}
