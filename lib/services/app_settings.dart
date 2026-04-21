import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Глобальные настройки приложения — тема, уведомления, акцентный цвет.
/// Является ChangeNotifier: виджеты перестраиваются при изменениях.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _keyThemeMode       = 'theme_mode';
  static const _keyAccentColor     = 'accent_color';
  static const _keyNotifications   = 'notifications';
  static const _keyNotifSound      = 'notif_sound';
  static const _keyNotifVibration  = 'notif_vibration';
  static const _keyChatBgPrefix    = 'chat_bg_';
  static const _keyLocale          = 'locale';           // 'system','ru','en','es','de','fr'
  static const _keyFontSize        = 'font_size';        // 0=small,1=medium,2=large
  static const _keySendOnEnter     = 'send_on_enter';
  static const _keyShowReadReceipts = 'show_read_receipts';
  static const _keyShowOnlineStatus = 'show_online_status';
  static const _keyAutoDownloadMedia = 'auto_download_media';
  static const _keyCompactMode     = 'compact_mode';
  static const _keyEtherRulesAccepted = 'ether_rules_accepted';
  static const _keyOnlineStatusMode  = 'online_status_mode'; // 0=online,1=dnd,2=busy
  static const _keyRelayEnabled      = 'relay_enabled';
  static const _keyRelayServerUrl    = 'relay_server_url';
  static const _keyConnectionMode    = 'connection_mode';   // 0=BLE only, 1=Internet, 2=BLE+Wi‑Fi Direct+Internet
  static const _keyMediaPriority     = 'media_priority';    // 0=BLE, 1=Internet
  static const _keyAdminPasswordHash = 'admin_password_hash';
  static const _keyBubbleStyle       = 'bubble_style';       // 0=rounded,1=square,2=minimal
  static const _keyClockFormat       = 'clock_format';       // 0=24h,1=12h
  static const _keyMessageDensity    = 'message_density';    // 0=comfortable,1=cozy,2=compact
  static const _keyShowReactionsQuickBar = 'show_reactions_quickbar';
  static const _keyQuickReactionEmoji = 'quick_reaction_emoji';
  static const _keyNotifyPersonal  = 'notify_personal';
  static const _keyNotifyGroups    = 'notify_groups';
  static const _keyNotifyChannels  = 'notify_channels';
  static const _keyAppIconVariant  = 'app_icon_variant';   // 0=classic,1=mono,2=mirror,3=ai
  static const _keyUseIosStyleEmoji = 'use_ios_style_emoji'; // Android: Noto Color Emoji fallback

  late SharedPreferences _prefs;

  ThemeMode _themeMode = ThemeMode.system;
  int _accentColorIndex = 0;
  bool _notificationsEnabled = true;
  bool _notifSound = true;
  bool _notifVibration = true;
  final Map<String, String> _chatBgMap = {};
  String _locale = 'system';
  int _fontSize = 1;            // 0=small, 1=medium, 2=large
  bool _sendOnEnter = false;    // false = send button, true = Enter sends
  bool _showReadReceipts = true;
  bool _showOnlineStatus = true;
  bool _autoDownloadMedia = true;
  bool _compactMode = false;
  bool _etherRulesAccepted = false;
  int _onlineStatusMode = 0; // 0=online(green), 1=dnd(yellow), 2=busy(red)
  bool _relayEnabled = true;
  String _relayServerUrl = '';
  int _connectionMode = 2;   // 0=BLE only, 1=Internet only, 2=Both
  int _mediaPriority = 1;    // 0=BLE first, 1=Internet first
  int _bubbleStyle = 0;      // 0=rounded, 1=square, 2=minimal
  int _clockFormat = 0;      // 0=24h, 1=12h
  int _messageDensity = 1;   // 0=comfortable, 1=cozy, 2=compact
  bool _showReactionsQuickBar = true;
  String _quickReactionEmoji = '👍';
  bool _notifyPersonal = true;
  bool _notifyGroups = true;
  bool _notifyChannels = true;
  int _appIconVariant = 0;
  bool _useIosStyleEmoji = false;

  ThemeMode get themeMode => _themeMode;
  int get accentColorIndex => _accentColorIndex;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get notifSound => _notifSound;
  bool get notifVibration => _notifVibration;
  String? chatBgForPeer(String peerId) => _chatBgMap[peerId];
  String get locale => _locale;
  int get fontSize => _fontSize;
  bool get sendOnEnter => _sendOnEnter;
  bool get showReadReceipts => _showReadReceipts;
  bool get showOnlineStatus => _showOnlineStatus;
  bool get autoDownloadMedia => _autoDownloadMedia;
  bool get compactMode => _compactMode;
  bool get etherRulesAccepted => _etherRulesAccepted;
  int get onlineStatusMode => _onlineStatusMode;
  bool get relayEnabled => _relayEnabled;
  String get relayServerUrl => _relayServerUrl;
  int get connectionMode => _connectionMode;
  int get mediaPriority => _mediaPriority;
  int get bubbleStyle => _bubbleStyle;
  int get clockFormat => _clockFormat;
  int get messageDensity => _messageDensity;
  bool get showReactionsQuickBar => _showReactionsQuickBar;
  String get quickReactionEmoji => _quickReactionEmoji;
  bool get notifyPersonal => _notifyPersonal;
  bool get notifyGroups => _notifyGroups;
  bool get notifyChannels => _notifyChannels;
  int get appIconVariant => _appIconVariant;
  /// На Android включает шрифт Noto Color Emoji (ближе к единому виду с iOS).
  bool get useIosStyleEmoji => _useIosStyleEmoji;

  /// Форматирует время по настройке часового формата.
  String formatTime(DateTime dt) {
    if (_clockFormat == 1) {
      final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final ampm = dt.hour < 12 ? 'AM' : 'PM';
      return '$h12:${dt.minute.toString().padLeft(2, '0')} $ampm';
    }
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// BorderRadius для сообщения/карточки в соответствии с выбранным стилем.
  /// [isMe] меняет «хвост» пузыря.
  BorderRadius bubbleRadius({bool isMe = false}) {
    switch (_bubbleStyle) {
      case 1: // square
        return BorderRadius.circular(6);
      case 2: // minimal
        return BorderRadius.circular(10);
      case 0: // rounded (default)
      default:
        return BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMe ? 18 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 18),
        );
    }
  }

  /// Вертикальный padding для сообщения с учётом плотности.
  double get messageVerticalPadding {
    switch (_messageDensity) {
      case 0:
        return 10;
      case 2:
        return 4;
      case 1:
      default:
        return 7;
    }
  }

  /// Цвет статуса: 0=зелёный(онлайн), 1=жёлтый(DND), 2=красный(занят), 3=серый(офлайн — авто)
  Color get onlineStatusColor => const [
    Color(0xFF4CAF50), // green
    Color(0xFFFFC107), // yellow/amber
    Color(0xFFF44336), // red
    Color(0xFF9E9E9E), // gray
  ][_onlineStatusMode.clamp(0, 3)];

  String get onlineStatusLabel => const [
    'В сети',
    'Не беспокоить',
    'Занят — не писать',
    'Не в сети',
  ][_onlineStatusMode.clamp(0, 3)];

  /// Расширенная палитра акцентных цветов (16 оттенков).
  static const List<Color> accentColors = [
    Color(0xFF1DB954), // Зелёный (по умолчанию)
    Color(0xFF2196F3), // Синий
    Color(0xFF9C27B0), // Фиолетовый
    Color(0xFFFF5722), // Оранжевый
    Color(0xFFF44336), // Красный
    Color(0xFF00BCD4), // Голубой
    Color(0xFFE91E63), // Розовый
    Color(0xFF4CAF50), // Светло-зелёный
    Color(0xFFFFC107), // Янтарный
    Color(0xFF673AB7), // Индиго
    Color(0xFF009688), // Бирюзовый
    Color(0xFFFF9800), // Оранж
    Color(0xFF795548), // Коричневый
    Color(0xFF607D8B), // Сталь
    Color(0xFF8BC34A), // Лайм
    Color(0xFF00E5FF), // Неон-голубой
  ];

  Color get accentColor => accentColors[_accentColorIndex];

  /// Возвращает Locale для MaterialApp на основе настройки
  Locale? get resolvedLocale {
    if (_locale == 'system') return null;
    return Locale(_locale);
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final modeIdx = _prefs.getInt(_keyThemeMode) ?? 0;
    _themeMode = ThemeMode.values[modeIdx.clamp(0, 2)];
    _accentColorIndex = (_prefs.getInt(_keyAccentColor) ?? 0).clamp(0, accentColors.length - 1);
    _notificationsEnabled = _prefs.getBool(_keyNotifications) ?? true;
    _notifSound = _prefs.getBool(_keyNotifSound) ?? true;
    _notifVibration = _prefs.getBool(_keyNotifVibration) ?? true;
    for (final key in _prefs.getKeys()) {
      if (key.startsWith(_keyChatBgPrefix)) {
        final peerId = key.substring(_keyChatBgPrefix.length);
        final path = _prefs.getString(key);
        if (path != null) _chatBgMap[peerId] = path;
      }
    }
    _locale = _prefs.getString(_keyLocale) ?? 'system';
    _fontSize = (_prefs.getInt(_keyFontSize) ?? 1).clamp(0, 2);
    _sendOnEnter = _prefs.getBool(_keySendOnEnter) ?? false;
    _showReadReceipts = _prefs.getBool(_keyShowReadReceipts) ?? true;
    _showOnlineStatus = _prefs.getBool(_keyShowOnlineStatus) ?? true;
    _autoDownloadMedia = _prefs.getBool(_keyAutoDownloadMedia) ?? true;
    _compactMode = _prefs.getBool(_keyCompactMode) ?? false;
    _etherRulesAccepted = _prefs.getBool(_keyEtherRulesAccepted) ?? false;
    _onlineStatusMode = (_prefs.getInt(_keyOnlineStatusMode) ?? 0).clamp(0, 2);
    _relayEnabled = _prefs.getBool(_keyRelayEnabled) ?? true;
    _relayServerUrl = _prefs.getString(_keyRelayServerUrl) ?? '';
    _connectionMode = (_prefs.getInt(_keyConnectionMode) ?? 2).clamp(0, 2);
    _mediaPriority = (_prefs.getInt(_keyMediaPriority) ?? 1).clamp(0, 1);
    _bubbleStyle = (_prefs.getInt(_keyBubbleStyle) ?? 0).clamp(0, 2);
    _clockFormat = (_prefs.getInt(_keyClockFormat) ?? 0).clamp(0, 1);
    _messageDensity = (_prefs.getInt(_keyMessageDensity) ?? 1).clamp(0, 2);
    _showReactionsQuickBar = _prefs.getBool(_keyShowReactionsQuickBar) ?? true;
    _quickReactionEmoji = _prefs.getString(_keyQuickReactionEmoji) ?? '👍';
    _notifyPersonal = _prefs.getBool(_keyNotifyPersonal) ?? true;
    _notifyGroups = _prefs.getBool(_keyNotifyGroups) ?? true;
    _notifyChannels = _prefs.getBool(_keyNotifyChannels) ?? true;
    _appIconVariant = (_prefs.getInt(_keyAppIconVariant) ?? 0).clamp(0, 3);
    _useIosStyleEmoji = Platform.isAndroid
        ? (_prefs.getBool(_keyUseIosStyleEmoji) ?? true)
        : false;
  }

  Future<void> setNotifyPersonal(bool v) async {
    _notifyPersonal = v;
    await _prefs.setBool(_keyNotifyPersonal, v);
    notifyListeners();
  }

  Future<void> setNotifyGroups(bool v) async {
    _notifyGroups = v;
    await _prefs.setBool(_keyNotifyGroups, v);
    notifyListeners();
  }

  Future<void> setNotifyChannels(bool v) async {
    _notifyChannels = v;
    await _prefs.setBool(_keyNotifyChannels, v);
    notifyListeners();
  }

  Future<void> setAppIconVariant(int v) async {
    _appIconVariant = v.clamp(0, 3);
    await _prefs.setInt(_keyAppIconVariant, _appIconVariant);
    notifyListeners();
  }

  Future<void> setUseIosStyleEmoji(bool v) async {
    if (!Platform.isAndroid) return;
    _useIosStyleEmoji = v;
    await _prefs.setBool(_keyUseIosStyleEmoji, v);
    notifyListeners();
  }

  Future<void> setQuickReactionEmoji(String emoji) async {
    final e = emoji.trim();
    if (e.isEmpty) return;
    _quickReactionEmoji = e;
    await _prefs.setString(_keyQuickReactionEmoji, _quickReactionEmoji);
    notifyListeners();
  }

  Future<void> setBubbleStyle(int style) async {
    _bubbleStyle = style.clamp(0, 2);
    await _prefs.setInt(_keyBubbleStyle, _bubbleStyle);
    notifyListeners();
  }

  Future<void> setClockFormat(int fmt) async {
    _clockFormat = fmt.clamp(0, 1);
    await _prefs.setInt(_keyClockFormat, _clockFormat);
    notifyListeners();
  }

  Future<void> setMessageDensity(int d) async {
    _messageDensity = d.clamp(0, 2);
    await _prefs.setInt(_keyMessageDensity, _messageDensity);
    notifyListeners();
  }

  Future<void> setShowReactionsQuickBar(bool value) async {
    _showReactionsQuickBar = value;
    await _prefs.setBool(_keyShowReactionsQuickBar, value);
    notifyListeners();
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

  Future<void> setChatBgForPeer(String peerId, String? path) async {
    if (path == null) {
      _chatBgMap.remove(peerId);
      await _prefs.remove('$_keyChatBgPrefix$peerId');
    } else {
      _chatBgMap[peerId] = path;
      await _prefs.setString('$_keyChatBgPrefix$peerId', path);
    }
    notifyListeners();
  }

  Future<void> setLocale(String locale) async {
    _locale = locale;
    await _prefs.setString(_keyLocale, locale);
    notifyListeners();
  }

  Future<void> setFontSize(int size) async {
    _fontSize = size.clamp(0, 2);
    await _prefs.setInt(_keyFontSize, _fontSize);
    notifyListeners();
  }

  Future<void> setSendOnEnter(bool value) async {
    _sendOnEnter = value;
    await _prefs.setBool(_keySendOnEnter, value);
    notifyListeners();
  }

  Future<void> setShowReadReceipts(bool value) async {
    _showReadReceipts = value;
    await _prefs.setBool(_keyShowReadReceipts, value);
    notifyListeners();
  }

  Future<void> setShowOnlineStatus(bool value) async {
    _showOnlineStatus = value;
    await _prefs.setBool(_keyShowOnlineStatus, value);
    notifyListeners();
  }

  Future<void> setAutoDownloadMedia(bool value) async {
    _autoDownloadMedia = value;
    await _prefs.setBool(_keyAutoDownloadMedia, value);
    notifyListeners();
  }

  Future<void> setCompactMode(bool value) async {
    _compactMode = value;
    await _prefs.setBool(_keyCompactMode, value);
    notifyListeners();
  }

  Future<void> setEtherRulesAccepted(bool value) async {
    _etherRulesAccepted = value;
    await _prefs.setBool(_keyEtherRulesAccepted, value);
    notifyListeners();
  }

  Future<void> setOnlineStatusMode(int mode) async {
    _onlineStatusMode = mode.clamp(0, 2);
    await _prefs.setInt(_keyOnlineStatusMode, _onlineStatusMode);
    notifyListeners();
  }

  Future<void> setRelayEnabled(bool value) async {
    _relayEnabled = value;
    await _prefs.setBool(_keyRelayEnabled, value);
    notifyListeners();
  }

  Future<void> setRelayServerUrl(String url) async {
    _relayServerUrl = url;
    await _prefs.setString(_keyRelayServerUrl, url);
    notifyListeners();
  }

  Future<void> setConnectionMode(int mode) async {
    _connectionMode = mode.clamp(0, 2);
    // Sync relayEnabled based on connection mode
    _relayEnabled = mode >= 1; // Internet or Both
    await _prefs.setInt(_keyConnectionMode, _connectionMode);
    await _prefs.setBool(_keyRelayEnabled, _relayEnabled);
    notifyListeners();
  }

  Future<void> setMediaPriority(int priority) async {
    _mediaPriority = priority.clamp(0, 1);
    await _prefs.setInt(_keyMediaPriority, _mediaPriority);
    notifyListeners();
  }

  // ── Admin password (SHA-256 hash) ─────────────────────────────
  // Default password: "1234"
  static const _defaultAdminHash = '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4';
  static const _keyAdminCfgRev = 'admin_cfg_rev';
  static const _keyAdminCfgSealed = 'admin_cfg_sealed_box';

  String get adminPasswordHash =>
      _prefs.getString(_keyAdminPasswordHash) ?? _defaultAdminHash;

  int get adminPasswordSyncRev => _prefs.getInt(_keyAdminCfgRev) ?? 0;

  String? get adminPasswordSealedBox => _prefs.getString(_keyAdminCfgSealed);

  Future<void> setAdminPasswordHash(String hash) async {
    await _prefs.setString(_keyAdminPasswordHash, hash);
  }

  /// Атомарно: хэш, монотонная ревизия и sealed-бокс для офлайн-восстановления на этом устройстве.
  Future<void> completeAdminPasswordRollout(
      String hash, int revision, String sealedBoxJson) async {
    await _prefs.setString(_keyAdminPasswordHash, hash);
    await _prefs.setInt(_keyAdminCfgRev, revision);
    await _prefs.setString(_keyAdminCfgSealed, sealedBoxJson);
    notifyListeners();
  }

  /// Применить только если [revision] новее сохранённой ревизии.
  Future<void> applyAdminPasswordSyncIfNewer(
      String hash, int revision, String sealedBoxJson) async {
    final cur = _prefs.getInt(_keyAdminCfgRev) ?? 0;
    if (revision <= cur) return;
    await _prefs.setString(_keyAdminPasswordHash, hash);
    await _prefs.setInt(_keyAdminCfgRev, revision);
    await _prefs.setString(_keyAdminCfgSealed, sealedBoxJson);
    notifyListeners();
  }
}
