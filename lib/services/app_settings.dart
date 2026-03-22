import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Глобальные настройки приложения — тема, уведомления, акцентный цвет.
/// Является ChangeNotifier: виджеты перестраиваются при изменениях.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _keyThemeMode = 'theme_mode';       // 0=system, 1=light, 2=dark
  static const _keyAccentColor = 'accent_color';   // 0–5
  static const _keyNotifications = 'notifications';
  static const _keyNotifSound = 'notif_sound';
  static const _keyNotifVibration = 'notif_vibration';

  late SharedPreferences _prefs;

  ThemeMode _themeMode = ThemeMode.system;
  int _accentColorIndex = 0;
  bool _notificationsEnabled = true;
  bool _notifSound = true;
  bool _notifVibration = true;

  ThemeMode get themeMode => _themeMode;
  int get accentColorIndex => _accentColorIndex;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get notifSound => _notifSound;
  bool get notifVibration => _notifVibration;

  /// Шесть акцентных цветов на выбор пользователя.
  static const List<Color> accentColors = [
    Color(0xFF1DB954), // Зелёный (по умолчанию)
    Color(0xFF2196F3), // Синий
    Color(0xFF9C27B0), // Фиолетовый
    Color(0xFFFF5722), // Оранжевый
    Color(0xFFF44336), // Красный
    Color(0xFF00BCD4), // Голубой
  ];

  Color get accentColor => accentColors[_accentColorIndex];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final modeIdx = _prefs.getInt(_keyThemeMode) ?? 0;
    _themeMode = ThemeMode.values[modeIdx.clamp(0, 2)];
    _accentColorIndex = (_prefs.getInt(_keyAccentColor) ?? 0).clamp(0, accentColors.length - 1);
    _notificationsEnabled = _prefs.getBool(_keyNotifications) ?? true;
    _notifSound = _prefs.getBool(_keyNotifSound) ?? true;
    _notifVibration = _prefs.getBool(_keyNotifVibration) ?? true;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _prefs.setInt(_keyThemeMode, mode.index);
    notifyListeners();
  }

  Future<void> setAccentColor(int index) async {
    _accentColorIndex = index.clamp(0, accentColors.length - 1);
    await _prefs.setInt(_keyAccentColor, _accentColorIndex);
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    _notificationsEnabled = value;
    await _prefs.setBool(_keyNotifications, value);
    notifyListeners();
  }

  Future<void> setNotifSound(bool value) async {
    _notifSound = value;
    await _prefs.setBool(_keyNotifSound, value);
    notifyListeners();
  }

  Future<void> setNotifVibration(bool value) async {
    _notifVibration = value;
    await _prefs.setBool(_keyNotifVibration, value);
    notifyListeners();
  }
}
