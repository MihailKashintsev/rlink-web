import 'package:flutter/services.dart';

/// Смена иконки приложения: классическая, моно, ИИ.
/// На iOS — alternate icons; на Android — activity-alias.
class AppIconService {
  AppIconService._();
  static const _ch = MethodChannel('com.rendergames.rlink/app_icon');

  /// 0 = default (классическая), 1 = mono, 2 = ai
  static Future<void> setVariant(int index) async {
    final v = index.clamp(0, 2);
    final name = switch (v) {
      1 => 'mono',
      2 => 'ai',
      _ => 'default',
    };
    try {
      await _ch.invokeMethod('setIcon', {'variant': name});
    } on MissingPluginException {
      // Desktop / неподдерживаемая платформа
    }
  }
}
