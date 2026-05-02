import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_bot_constants.dart';
import 'runtime_platform.dart';
import 'web_account_bundle.dart';
import 'web_identity_portable.dart';
import '../utils/reaction_emoji_key.dart';

/// Глобальные настройки приложения — тема, уведомления, акцентный цвет.
/// Является ChangeNotifier: виджеты перестраиваются при изменениях.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _keyThemeMode = 'theme_mode';
  static const _keyAccentColor = 'accent_color';
  static const _keyNotifications = 'notifications';
  static const _keyNotifSound = 'notif_sound';
  static const _keyNotifVibration = 'notif_vibration';
  static const _keyChatBgPrefix = 'chat_bg_';
  static const _keyLocale = 'locale'; // 'system','ru','en','es','de','fr'
  static const _keyFontSize = 'font_size'; // 0=small,1=medium,2=large
  static const _keySendOnEnter = 'send_on_enter';
  static const _keyShowReadReceipts = 'show_read_receipts';
  static const _keyShowOnlineStatus = 'show_online_status';
  static const _keyAutoDownloadMedia = 'auto_download_media';
  static const _keyCompactMode = 'compact_mode';
  static const _keyEtherRulesAccepted = 'ether_rules_accepted';
  static const _keyOnlineStatusMode =
      'online_status_mode'; // 0=online,1=dnd,2=busy
  static const _keyRelayEnabled = 'relay_enabled';
  static const _keyRelayServerUrl = 'relay_server_url';
  static const _keyConnectionMode =
      'connection_mode'; // 0=BLE only, 1=Internet, 2=BLE+Wi‑Fi Direct+Internet
  static const _keyMediaPriority = 'media_priority'; // 0=BLE, 1=Internet
  /// v2: предыдущий ключ мог содержать устаревший хэш после смены настроек;
  /// без миграции — снова действует заводской пароль до смены в админке.
  static const _keyAdminPasswordHash = 'admin_password_hash_v2';
  static const _keyBubbleStyle = 'bubble_style'; // 0=rounded,1=square,2=minimal
  static const _keyClockFormat = 'clock_format'; // 0=24h,1=12h
  static const _keyMessageDensity =
      'message_density'; // 0=comfortable,1=cozy,2=compact
  static const _keyShowReactionsQuickBar = 'show_reactions_quickbar';
  static const _keyQuickReactionEmoji = 'quick_reaction_emoji';
  static const _keyNotifyPersonal = 'notify_personal';
  static const _keyNotifyGroups = 'notify_groups';
  static const _keyNotifyChannels = 'notify_channels';
  static const _keyCallRingtone = 'call_ringtone'; // 0=classic,1=digital,2=soft
  static const _keyAppIconVariant = 'app_icon_variant'; // 0=classic,1=mono,2=ai
  static const _keyUseIosStyleEmoji =
      'use_ios_style_emoji'; // Android: Noto Color Emoji fallback
  static const _keyDeviceLinkRole =
      'device_link_role'; // 0=none,1=primary,2=child
  static const _keyLinkedDevicePublicKey = 'linked_device_public_key';
  static const _keyLinkedDeviceNickname = 'linked_device_nickname';
  static const _keyPreLinkConnectionMode = 'pre_link_connection_mode';
  static const _keyEnabledBotIds = 'enabled_bot_ids';

  late SharedPreferences _prefs;
  bool _prefsReady = false;

  Future<void> _runPrefsWrite(
    Future<void> Function(SharedPreferences prefs) action,
  ) async {
    try {
      if (!_prefsReady) {
        _prefs = await SharedPreferences.getInstance();
        _prefsReady = true;
      }
      await action(_prefs);
    } catch (_) {}
  }

  void _notifySettingsChanged() {
    if (RuntimePlatform.isWeb) {
      unawaited(_persistWebBackupSnapshot());
    }
    notifyListeners();
    if (RuntimePlatform.isWeb) {
      unawaited(WebIdentityPortable.exportIdentityKeyDownload());
    }
  }

  Future<void> _persistWebBackupSnapshot() async {
    final json = <String, dynamic>{
      'themeMode': _themeMode.index,
      'accentColorIndex': _accentColorIndex,
      'notificationsEnabled': _notificationsEnabled,
      'notifSound': _notifSound,
      'notifVibration': _notifVibration,
      'chatBgMap': _chatBgMap,
      'locale': _locale,
      'fontSize': _fontSize,
      'sendOnEnter': _sendOnEnter,
      'showReadReceipts': _showReadReceipts,
      'showOnlineStatus': _showOnlineStatus,
      'autoDownloadMedia': _autoDownloadMedia,
      'compactMode': _compactMode,
      'onlineStatusMode': _onlineStatusMode,
      'relayEnabled': _relayEnabled,
      'relayServerUrl': _relayServerUrl,
      'connectionMode': _connectionMode,
      'mediaPriority': _mediaPriority,
      'bubbleStyle': _bubbleStyle,
      'clockFormat': _clockFormat,
      'messageDensity': _messageDensity,
      'showReactionsQuickBar': _showReactionsQuickBar,
      'quickReactionEmoji': _quickReactionEmoji,
      'notifyPersonal': _notifyPersonal,
      'notifyGroups': _notifyGroups,
      'notifyChannels': _notifyChannels,
      'callRingtone': _callRingtone,
      'appIconVariant': _appIconVariant,
      'useIosStyleEmoji': _useIosStyleEmoji,
      'deviceLinkRole': _deviceLinkRole,
      'linkedDevicePublicKey': _linkedDevicePublicKey,
      'linkedDeviceNickname': _linkedDeviceNickname,
      'preLinkConnectionMode': _preLinkConnectionMode,
      'enabledBotIds': _enabledBotIds,
    };
    await WebAccountBundle.layeredWrite(kAppSettingsBackup, jsonEncode(json));
  }

  ThemeMode _themeMode = ThemeMode.system;
  int _accentColorIndex = 0;
  bool _notificationsEnabled = true;
  bool _notifSound = true;
  bool _notifVibration = true;
  final Map<String, String> _chatBgMap = {};
  String _locale = 'system';
  int _fontSize = 1; // 0=small, 1=medium, 2=large
  bool _sendOnEnter = false; // false = send button, true = Enter sends
  bool _showReadReceipts = true;
  bool _showOnlineStatus = true;
  bool _autoDownloadMedia = true;
  bool _compactMode = false;
  bool _etherRulesAccepted = false;
  int _onlineStatusMode = 0; // 0=online(green), 1=dnd(yellow), 2=busy(red)
  bool _relayEnabled = true;
  String _relayServerUrl = '';
  int _connectionMode = 2; // 0=BLE only, 1=Internet only, 2=Both
  int _mediaPriority = 1; // 0=BLE first, 1=Internet first
  int _bubbleStyle = 0; // 0=rounded, 1=square, 2=minimal
  int _clockFormat = 0; // 0=24h, 1=12h
  int _messageDensity = 1; // 0=comfortable, 1=cozy, 2=compact
  bool _showReactionsQuickBar = true;
  String _quickReactionEmoji = '👍';
  bool _notifyPersonal = true;
  bool _notifyGroups = true;
  bool _notifyChannels = true;
  int _callRingtone = 0;
  int _appIconVariant = 0;
  bool _useIosStyleEmoji = false;
  int _deviceLinkRole = 0;
  String _linkedDevicePublicKey = '';
  String _linkedDeviceNickname = '';
  int? _preLinkConnectionMode;
  List<String> _enabledBotIds = const [];

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
  int get connectionMode =>
      RuntimePlatform.isWeb ? 1 : (isDeviceLinked ? 1 : _connectionMode);
  int get configuredConnectionMode => _connectionMode;
  int get mediaPriority => _mediaPriority;
  int get bubbleStyle => _bubbleStyle;
  int get clockFormat => _clockFormat;
  int get messageDensity => _messageDensity;
  bool get showReactionsQuickBar => _showReactionsQuickBar;
  String get quickReactionEmoji => _quickReactionEmoji;
  bool get notifyPersonal => _notifyPersonal;
  bool get notifyGroups => _notifyGroups;
  bool get notifyChannels => _notifyChannels;
  int get callRingtone => _callRingtone.clamp(0, 2);
  int get appIconVariant => _appIconVariant;
  int get deviceLinkRole => _deviceLinkRole.clamp(0, 2);
  bool get isPrimaryDevice => deviceLinkRole == 1;
  bool get isLinkedChildDevice => deviceLinkRole == 2;
  bool get isDeviceLinked =>
      deviceLinkRole != 0 && _linkedDevicePublicKey.isNotEmpty;
  String get linkedDevicePublicKey => _linkedDevicePublicKey;
  String get linkedDeviceNickname => _linkedDeviceNickname;
  List<String> get enabledBotIds => List.unmodifiable(_enabledBotIds);
  bool isBotEnabled(String botId) => _enabledBotIds.contains(botId);
  bool get canEditOwnProfileAndSettings => !isLinkedChildDevice;
  bool get channelsEnabled => connectionMode != 0;

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
    double base;
    switch (_messageDensity) {
      case 0:
        base = 10;
        break;
      case 2:
        base = 4;
        break;
      case 1:
      default:
        base = 7;
        break;
    }
    if (_compactMode) {
      base -= 1.5;
    }
    return base < 2 ? 2 : base;
  }

  /// Нижний отступ между пузырями с учётом плотности.
  double get messageBubbleBottomMargin {
    if (_compactMode) return 2;
    return const [8.0, 4.0, 2.0][_messageDensity];
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
    _prefsReady = true;
    await _migrateAdminPasswordHashV2IfNeeded();
    final modeIdx = _prefs.getInt(_keyThemeMode) ?? 0;
    _themeMode = ThemeMode.values[modeIdx.clamp(0, 2)];
    _accentColorIndex =
        (_prefs.getInt(_keyAccentColor) ?? 0).clamp(0, accentColors.length - 1);
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
    _deviceLinkRole = (_prefs.getInt(_keyDeviceLinkRole) ?? 0).clamp(0, 2);
    _linkedDevicePublicKey = _normalizeLinkedKey(
      _prefs.getString(_keyLinkedDevicePublicKey) ?? '',
    );
    _linkedDeviceNickname =
        (_prefs.getString(_keyLinkedDeviceNickname) ?? '').trim();
    final pre = _prefs.getInt(_keyPreLinkConnectionMode);
    _preLinkConnectionMode = pre?.clamp(0, 2).toInt();
    final hasBotPrefs = _prefs.containsKey(_keyEnabledBotIds);
    final rawBotIds = _prefs.getStringList(_keyEnabledBotIds) ?? const <String>[];
    _enabledBotIds = _sanitizeBotIds(rawBotIds);
    if (!hasBotPrefs) {
      final defaults = kBuiltinAiBots
          .where((b) => b.enabledByDefault)
          .map((b) => b.id)
          .toList();
      _enabledBotIds = _sanitizeBotIds(defaults);
      await _prefs.setStringList(_keyEnabledBotIds, _enabledBotIds);
    }
    if (_deviceLinkRole != 0 && _linkedDevicePublicKey.isEmpty) {
      _deviceLinkRole = 0;
      _linkedDeviceNickname = '';
      await _prefs.remove(_keyDeviceLinkRole);
      await _prefs.remove(_keyLinkedDevicePublicKey);
      await _prefs.remove(_keyLinkedDeviceNickname);
    }
    if (RuntimePlatform.isWeb || isDeviceLinked) {
      // Linked devices work only through relay.
      _relayEnabled = true;
    }
    _mediaPriority = (_prefs.getInt(_keyMediaPriority) ?? 1).clamp(0, 1);
    _bubbleStyle = (_prefs.getInt(_keyBubbleStyle) ?? 0).clamp(0, 2);
    _clockFormat = (_prefs.getInt(_keyClockFormat) ?? 0).clamp(0, 1);
    _messageDensity = (_prefs.getInt(_keyMessageDensity) ?? 1).clamp(0, 2);
    _showReactionsQuickBar = _prefs.getBool(_keyShowReactionsQuickBar) ?? true;
    final rawQuick = _prefs.getString(_keyQuickReactionEmoji) ?? '👍';
    _quickReactionEmoji = canonicalReactionEmojiKey(rawQuick);
    if (_quickReactionEmoji.isEmpty) _quickReactionEmoji = '👍';
    if (_quickReactionEmoji != rawQuick) {
      unawaited(_runPrefsWrite(
          (p) => p.setString(_keyQuickReactionEmoji, _quickReactionEmoji)));
    }
    _notifyPersonal = _prefs.getBool(_keyNotifyPersonal) ?? true;
    _notifyGroups = _prefs.getBool(_keyNotifyGroups) ?? true;
    _notifyChannels = _prefs.getBool(_keyNotifyChannels) ?? true;
    _callRingtone = (_prefs.getInt(_keyCallRingtone) ?? 0).clamp(0, 2);
    var iconV = (_prefs.getInt(_keyAppIconVariant) ?? 0).clamp(0, 3);
    // Раньше: 2=mirror (теперь совпадает с классикой), 3=ai → 2.
    if (iconV == 2) iconV = 0;
    if (iconV == 3) iconV = 2;
    _appIconVariant = iconV.clamp(0, 2);
    if ((_prefs.getInt(_keyAppIconVariant) ?? -1) != _appIconVariant) {
      await _prefs.setInt(_keyAppIconVariant, _appIconVariant);
    }
    _useIosStyleEmoji = RuntimePlatform.isAndroid
        ? (_prefs.getBool(_keyUseIosStyleEmoji) ?? true)
        : false;
    if (RuntimePlatform.isWeb) {
      await _applyWebSettingsBackupIfPresent();
    }
    if (RuntimePlatform.isWeb) {
      unawaited(_persistWebBackupSnapshot());
    }
  }

  List<String> _sanitizeBotIds(List<String> ids) {
    final known = kBuiltinAiBots.map((b) => b.id).toSet();
    final out = <String>[];
    for (final id in ids) {
      if (known.contains(id) && !out.contains(id)) {
        out.add(id);
      }
    }
    return out;
  }

  Future<void> setEnabledBotIds(List<String> botIds) async {
    _enabledBotIds = _sanitizeBotIds(botIds);
    await _runPrefsWrite(
      (p) => p.setStringList(_keyEnabledBotIds, _enabledBotIds),
    );
    _notifySettingsChanged();
  }

  Future<void> _applyWebSettingsBackupIfPresent() async {
    try {
      final raw = await WebAccountBundle.layeredRead(kAppSettingsBackup);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      _themeMode =
          ThemeMode.values[((m['themeMode'] as num?)?.toInt() ?? _themeMode.index).clamp(0, 2)];
      _accentColorIndex = ((m['accentColorIndex'] as num?)?.toInt() ??
              _accentColorIndex)
          .clamp(0, accentColors.length - 1);
      _notificationsEnabled =
          m['notificationsEnabled'] as bool? ?? _notificationsEnabled;
      _notifSound = m['notifSound'] as bool? ?? _notifSound;
      _notifVibration = m['notifVibration'] as bool? ?? _notifVibration;
      _locale = m['locale'] as String? ?? _locale;
      _fontSize = ((m['fontSize'] as num?)?.toInt() ?? _fontSize).clamp(0, 2);
      _sendOnEnter = m['sendOnEnter'] as bool? ?? _sendOnEnter;
      _showReadReceipts = m['showReadReceipts'] as bool? ?? _showReadReceipts;
      _showOnlineStatus = m['showOnlineStatus'] as bool? ?? _showOnlineStatus;
      _autoDownloadMedia =
          m['autoDownloadMedia'] as bool? ?? _autoDownloadMedia;
      _compactMode = m['compactMode'] as bool? ?? _compactMode;
      _onlineStatusMode =
          ((m['onlineStatusMode'] as num?)?.toInt() ?? _onlineStatusMode)
              .clamp(0, 2);
      _relayEnabled = m['relayEnabled'] as bool? ?? _relayEnabled;
      _relayServerUrl = m['relayServerUrl'] as String? ?? _relayServerUrl;
      _connectionMode =
          ((m['connectionMode'] as num?)?.toInt() ?? _connectionMode)
              .clamp(0, 2);
      _mediaPriority =
          ((m['mediaPriority'] as num?)?.toInt() ?? _mediaPriority).clamp(0, 1);
      _bubbleStyle =
          ((m['bubbleStyle'] as num?)?.toInt() ?? _bubbleStyle).clamp(0, 2);
      _clockFormat =
          ((m['clockFormat'] as num?)?.toInt() ?? _clockFormat).clamp(0, 1);
      _messageDensity =
          ((m['messageDensity'] as num?)?.toInt() ?? _messageDensity)
              .clamp(0, 2);
      _showReactionsQuickBar =
          m['showReactionsQuickBar'] as bool? ?? _showReactionsQuickBar;
      _quickReactionEmoji =
          m['quickReactionEmoji'] as String? ?? _quickReactionEmoji;
      _notifyPersonal = m['notifyPersonal'] as bool? ?? _notifyPersonal;
      _notifyGroups = m['notifyGroups'] as bool? ?? _notifyGroups;
      _notifyChannels = m['notifyChannels'] as bool? ?? _notifyChannels;
      _callRingtone =
          ((m['callRingtone'] as num?)?.toInt() ?? _callRingtone).clamp(0, 2);
      _appIconVariant =
          ((m['appIconVariant'] as num?)?.toInt() ?? _appIconVariant)
              .clamp(0, 2);
      _useIosStyleEmoji = m['useIosStyleEmoji'] as bool? ?? _useIosStyleEmoji;
      _deviceLinkRole =
          ((m['deviceLinkRole'] as num?)?.toInt() ?? _deviceLinkRole)
              .clamp(0, 2);
      _linkedDevicePublicKey =
          (m['linkedDevicePublicKey'] as String?) ?? _linkedDevicePublicKey;
      _linkedDeviceNickname =
          (m['linkedDeviceNickname'] as String?) ?? _linkedDeviceNickname;
      final pre = (m['preLinkConnectionMode'] as num?)?.toInt();
      _preLinkConnectionMode = pre?.clamp(0, 2);
      final bots = (m['enabledBotIds'] as List?)?.cast<String>();
      if (bots != null) {
        _enabledBotIds = _sanitizeBotIds(bots);
      }
      final bg = m['chatBgMap'];
      if (bg is Map) {
        for (final e in bg.entries) {
          if (e.key is String && e.value is String) {
            _chatBgMap[e.key as String] = e.value as String;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> setNotifyPersonal(bool v) async {
    _notifyPersonal = v;
    await _runPrefsWrite((p) => p.setBool(_keyNotifyPersonal, v));
    _notifySettingsChanged();
  }

  Future<void> setNotifyGroups(bool v) async {
    _notifyGroups = v;
    await _runPrefsWrite((p) => p.setBool(_keyNotifyGroups, v));
    _notifySettingsChanged();
  }

  Future<void> setNotifyChannels(bool v) async {
    _notifyChannels = v;
    await _runPrefsWrite((p) => p.setBool(_keyNotifyChannels, v));
    _notifySettingsChanged();
  }

  Future<void> setCallRingtone(int v) async {
    _callRingtone = v.clamp(0, 2);
    await _runPrefsWrite((p) => p.setInt(_keyCallRingtone, _callRingtone));
    _notifySettingsChanged();
  }

  Future<void> setAppIconVariant(int v) async {
    _appIconVariant = v.clamp(0, 2);
    await _runPrefsWrite((p) => p.setInt(_keyAppIconVariant, _appIconVariant));
    _notifySettingsChanged();
  }

  Future<void> setUseIosStyleEmoji(bool v) async {
    if (!RuntimePlatform.isAndroid) return;
    _useIosStyleEmoji = v;
    await _runPrefsWrite((p) => p.setBool(_keyUseIosStyleEmoji, v));
    _notifySettingsChanged();
  }

  Future<void> setQuickReactionEmoji(String emoji) async {
    final e = canonicalReactionEmojiKey(emoji);
    if (e.isEmpty) return;
    _quickReactionEmoji = e;
    await _runPrefsWrite(
      (p) => p.setString(_keyQuickReactionEmoji, _quickReactionEmoji),
    );
    _notifySettingsChanged();
  }

  Future<void> setBubbleStyle(int style) async {
    _bubbleStyle = style.clamp(0, 2);
    await _runPrefsWrite((p) => p.setInt(_keyBubbleStyle, _bubbleStyle));
    _notifySettingsChanged();
  }

  Future<void> setClockFormat(int fmt) async {
    _clockFormat = fmt.clamp(0, 1);
    await _runPrefsWrite((p) => p.setInt(_keyClockFormat, _clockFormat));
    _notifySettingsChanged();
  }

  Future<void> setMessageDensity(int d) async {
    _messageDensity = d.clamp(0, 2);
    await _runPrefsWrite((p) => p.setInt(_keyMessageDensity, _messageDensity));
    _notifySettingsChanged();
  }

  Future<void> setShowReactionsQuickBar(bool value) async {
    _showReactionsQuickBar = value;
    await _runPrefsWrite((p) => p.setBool(_keyShowReactionsQuickBar, value));
    _notifySettingsChanged();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _runPrefsWrite((p) => p.setInt(_keyThemeMode, mode.index));
    _notifySettingsChanged();
  }

  Future<void> setAccentColor(int index) async {
    _accentColorIndex = index.clamp(0, accentColors.length - 1);
    await _runPrefsWrite((p) => p.setInt(_keyAccentColor, _accentColorIndex));
    _notifySettingsChanged();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    _notificationsEnabled = value;
    await _runPrefsWrite((p) => p.setBool(_keyNotifications, value));
    _notifySettingsChanged();
  }

  Future<void> setNotifSound(bool value) async {
    _notifSound = value;
    await _runPrefsWrite((p) => p.setBool(_keyNotifSound, value));
    _notifySettingsChanged();
  }

  Future<void> setNotifVibration(bool value) async {
    _notifVibration = value;
    await _runPrefsWrite((p) => p.setBool(_keyNotifVibration, value));
    _notifySettingsChanged();
  }

  Future<void> setChatBgForPeer(String peerId, String? path) async {
    if (path == null) {
      _chatBgMap.remove(peerId);
      await _runPrefsWrite((p) => p.remove('$_keyChatBgPrefix$peerId'));
    } else {
      _chatBgMap[peerId] = path;
      await _runPrefsWrite((p) => p.setString('$_keyChatBgPrefix$peerId', path));
    }
    _notifySettingsChanged();
  }

  Future<void> setLocale(String locale) async {
    _locale = locale;
    await _runPrefsWrite((p) => p.setString(_keyLocale, locale));
    _notifySettingsChanged();
  }

  Future<void> setFontSize(int size) async {
    _fontSize = size.clamp(0, 2);
    await _runPrefsWrite((p) => p.setInt(_keyFontSize, _fontSize));
    _notifySettingsChanged();
  }

  Future<void> setSendOnEnter(bool value) async {
    _sendOnEnter = value;
    await _runPrefsWrite((p) => p.setBool(_keySendOnEnter, value));
    _notifySettingsChanged();
  }

  Future<void> setShowReadReceipts(bool value) async {
    _showReadReceipts = value;
    await _runPrefsWrite((p) => p.setBool(_keyShowReadReceipts, value));
    _notifySettingsChanged();
  }

  Future<void> setShowOnlineStatus(bool value) async {
    _showOnlineStatus = value;
    await _runPrefsWrite((p) => p.setBool(_keyShowOnlineStatus, value));
    _notifySettingsChanged();
  }

  Future<void> setAutoDownloadMedia(bool value) async {
    _autoDownloadMedia = value;
    await _runPrefsWrite((p) => p.setBool(_keyAutoDownloadMedia, value));
    _notifySettingsChanged();
  }

  Future<void> setCompactMode(bool value) async {
    _compactMode = value;
    await _runPrefsWrite((p) => p.setBool(_keyCompactMode, value));
    _notifySettingsChanged();
  }

  Future<void> setEtherRulesAccepted(bool value) async {
    _etherRulesAccepted = value;
    await _runPrefsWrite((p) => p.setBool(_keyEtherRulesAccepted, value));
    _notifySettingsChanged();
  }

  Future<void> setOnlineStatusMode(int mode) async {
    _onlineStatusMode = mode.clamp(0, 2);
    await _runPrefsWrite((p) => p.setInt(_keyOnlineStatusMode, _onlineStatusMode));
    _notifySettingsChanged();
  }

  Future<void> setRelayEnabled(bool value) async {
    _relayEnabled = (RuntimePlatform.isWeb || isDeviceLinked) ? true : value;
    await _runPrefsWrite((p) => p.setBool(_keyRelayEnabled, _relayEnabled));
    _notifySettingsChanged();
  }

  Future<void> setRelayServerUrl(String url) async {
    _relayServerUrl = url;
    await _runPrefsWrite((p) => p.setString(_keyRelayServerUrl, url));
    _notifySettingsChanged();
  }

  Future<void> setConnectionMode(int mode) async {
    _connectionMode =
        (RuntimePlatform.isWeb || isDeviceLinked) ? 1 : mode.clamp(0, 2);
    // Sync relayEnabled based on connection mode
    _relayEnabled = _connectionMode >= 1; // Internet or Both
    await _runPrefsWrite((p) => p.setInt(_keyConnectionMode, _connectionMode));
    await _runPrefsWrite((p) => p.setBool(_keyRelayEnabled, _relayEnabled));
    _notifySettingsChanged();
  }

  Future<void> setMediaPriority(int priority) async {
    _mediaPriority = priority.clamp(0, 1);
    await _runPrefsWrite((p) => p.setInt(_keyMediaPriority, _mediaPriority));
    _notifySettingsChanged();
  }

  Future<void> linkAsPrimaryDevice({
    required String devicePublicKey,
    required String deviceNickname,
  }) {
    return _setDeviceLink(
      role: 1,
      devicePublicKey: devicePublicKey,
      deviceNickname: deviceNickname,
    );
  }

  Future<void> linkAsChildDevice({
    required String devicePublicKey,
    required String deviceNickname,
  }) {
    return _setDeviceLink(
      role: 2,
      devicePublicKey: devicePublicKey,
      deviceNickname: deviceNickname,
    );
  }

  Future<void> unlinkDevice() async {
    _deviceLinkRole = 0;
    _linkedDevicePublicKey = '';
    _linkedDeviceNickname = '';
    if (_preLinkConnectionMode != null) {
      _connectionMode = _preLinkConnectionMode!.clamp(0, 2);
    }
    _preLinkConnectionMode = null;
    _relayEnabled = _connectionMode >= 1;
    await _prefs.remove(_keyDeviceLinkRole);
    await _prefs.remove(_keyLinkedDevicePublicKey);
    await _prefs.remove(_keyLinkedDeviceNickname);
    await _prefs.remove(_keyPreLinkConnectionMode);
    await _prefs.setInt(_keyConnectionMode, _connectionMode);
    await _prefs.setBool(_keyRelayEnabled, _relayEnabled);
    _notifySettingsChanged();
  }

  Future<void> _setDeviceLink({
    required int role,
    required String devicePublicKey,
    required String deviceNickname,
  }) async {
    final normalized = _normalizeLinkedKey(devicePublicKey);
    if (normalized.isEmpty) return;
    final safeRole = role.clamp(1, 2);
    if (_preLinkConnectionMode == null && _connectionMode != 1) {
      _preLinkConnectionMode = _connectionMode;
      await _prefs.setInt(_keyPreLinkConnectionMode, _connectionMode);
    }
    _deviceLinkRole = safeRole;
    _linkedDevicePublicKey = normalized;
    final nick = deviceNickname.trim();
    _linkedDeviceNickname =
        nick.isEmpty ? '${normalized.substring(0, 8)}...' : nick;
    _connectionMode = 1;
    _relayEnabled = true;
    await _prefs.setInt(_keyDeviceLinkRole, _deviceLinkRole);
    await _prefs.setString(_keyLinkedDevicePublicKey, _linkedDevicePublicKey);
    await _prefs.setString(_keyLinkedDeviceNickname, _linkedDeviceNickname);
    await _prefs.setInt(_keyConnectionMode, _connectionMode);
    await _prefs.setBool(_keyRelayEnabled, _relayEnabled);
    _notifySettingsChanged();
  }

  String _normalizeLinkedKey(String value) {
    final key = value.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) return '';
    return key;
  }

  // ── Admin password (SHA-256 hash) ─────────────────────────────
  // Default password: "Misha0000ff2010"
  static const _defaultAdminHash =
      '8676c71fc75fa72489c87aa387b752ad816a4ea4476995da848c76fa06dae4fd';
  static const _keyAdminPwdV2Migrated = 'admin_password_hash_v2_migrated';
  static const _keyAdminCfgRev = 'admin_cfg_rev';
  static const _keyAdminCfgSealed = 'admin_cfg_sealed_box';

  /// Одноразово: новый ключ хэша, сброс sealed и подъём ревизии, чтобы старый
  /// admin_cfg2 с relay не откатил пароль к утерянному значению.
  Future<void> _migrateAdminPasswordHashV2IfNeeded() async {
    if (_prefs.getBool(_keyAdminPwdV2Migrated) == true) return;
    await _prefs.setBool(_keyAdminPwdV2Migrated, true);
    await _prefs.remove('admin_password_hash');
    await _prefs.remove(_keyAdminCfgSealed);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await _prefs.setInt(_keyAdminCfgRev, stamp);
  }

  String get adminPasswordHash {
    final s = _prefs.getString(_keyAdminPasswordHash);
    if (s == null || s.isEmpty) return _defaultAdminHash;
    return s;
  }

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

  /// Обновить ревизию синхронизации и sealed-бокс без смены пароля админки (список каналов).
  Future<void> bumpAccountSyncRevisionOnly(
      int revision, String sealedBoxJson) async {
    final cur = _prefs.getInt(_keyAdminCfgRev) ?? 0;
    if (revision <= cur) return;
    await _prefs.setInt(_keyAdminCfgRev, revision);
    await _prefs.setString(_keyAdminCfgSealed, sealedBoxJson);
    notifyListeners();
  }
}
