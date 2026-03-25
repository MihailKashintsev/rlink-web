/// Lightweight localization without code generation.
/// Usage: AppL10n.t('key')  or  AppL10n.s.settingsTitle
///
/// To add a new string:
///   1. Add the key to _ru map (Russian is the master)
///   2. Add translations to _en, _es, _de, _fr, _zh, _uk maps
library;

import 'dart:ui' as ui;

import '../services/app_settings.dart';

class AppL10n {
  AppL10n._();

  // Returns current language based on AppSettings.
  // When 'system', detect platform locale and fall back to 'ru'.
  static String get _lang {
    final chosen = AppSettings.instance.locale;
    if (chosen != 'system') return chosen;
    final systemLang = ui.PlatformDispatcher.instance.locale.languageCode;
    return _data.containsKey(systemLang) ? systemLang : 'ru';
  }

  static String t(String key) =>
      _data[_lang]?[key] ?? _data['ru']![key] ?? key;

  // Convenience singleton that rebuilds on language change
  static AppL10n get s => AppL10n._();

  // ────────────────────────────────────────────────────────────────
  // All strings
  // ────────────────────────────────────────────────────────────────

  static const _ru = <String, String>{
    // Nav
    'nav_chats': 'Чаты',
    'nav_contacts': 'Контакты',
    'nav_nearby': 'Рядом',
    'nav_ether': 'Эфир',

    // Settings
    'settings': 'Настройки',
    'settings_appearance': 'Внешний вид',
    'settings_theme': 'Тема',
    'settings_theme_system': 'Системная',
    'settings_theme_light': 'Светлая',
    'settings_theme_dark': 'Тёмная',
    'settings_accent_color': 'Акцентный цвет',
    'settings_chat_bg': 'Фон чатов',
    'settings_chat_bg_custom': 'Пользовательский фон',
    'settings_chat_bg_none': 'Без фона',
    'settings_font_size': 'Размер шрифта',
    'settings_font_small': 'Мелкий',
    'settings_font_medium': 'Средний',
    'settings_font_large': 'Крупный',
    'settings_compact_mode': 'Компактный режим',
    'settings_compact_mode_sub': 'Уменьшает отступы для большей плотности',
    'settings_language': 'Язык',
    'settings_language_system': 'Системный',

    // Notifications
    'settings_notifications': 'Уведомления',
    'settings_notif_messages': 'Уведомления о сообщениях',
    'settings_notif_messages_sub': 'Показывать уведомление при новом сообщении',
    'settings_notif_sound': 'Звук',
    'settings_notif_vibration': 'Вибрация',
    'settings_notif_previews': 'Показывать текст в уведомлении',
    'settings_notif_previews_sub': 'Отображать первые слова сообщения',

    // Privacy
    'settings_privacy': 'Конфиденциальность',
    'settings_read_receipts': 'Статус прочтения',
    'settings_read_receipts_sub': 'Показывать галочки прочтения',
    'settings_online_status': 'Онлайн-статус',
    'settings_online_status_sub': 'Показывать зелёную точку у онлайн-контактов',

    // Messaging
    'settings_messaging': 'Сообщения',
    'settings_send_on_enter': 'Enter для отправки',
    'settings_send_on_enter_sub': 'Отправлять сообщение клавишей Enter (ПК)',
    'settings_auto_download': 'Авто-загрузка медиа',
    'settings_auto_download_sub': 'Автоматически получать фото, видео и файлы',

    // Profile
    'settings_profile': 'Профиль',
    'settings_public_key': 'Мой публичный ключ',
    'settings_key_copied': 'Ключ скопирован',

    // Search
    'settings_find_user': 'Найти пользователя',
    'settings_search_by_id': 'Поиск по уникальному ID',
    'settings_search_by_id_sub': 'Открыть чат зная публичный ключ собеседника',

    // Data
    'settings_data': 'Данные',
    'settings_clear_history': 'Очистить историю чатов',
    'settings_clear_history_sub': 'Удалит все сообщения, контакты останутся',
    'settings_delete_contacts': 'Удалить все контакты',
    'settings_delete_contacts_sub': 'Контакты будут удалены, сообщения останутся',

    // Danger zone
    'settings_danger': 'Опасная зона',
    'settings_reset': 'Сбросить приложение',
    'settings_reset_sub': 'Удалит профиль, все чаты и контакты. Необратимо.',

    // About
    'settings_about': 'О проекте',
    'about_title': 'О проекте Rlink',
    'about_version': 'Версия',
    'about_description': 'Rlink — децентрализованный мессенджер на Bluetooth LE. Общайся без интернета и серверов, напрямую между устройствами.',
    'about_developer': 'Разработчик',
    'about_website': 'Сайт',
    'about_telegram': 'Telegram-канал',
    'about_support': 'Поддержать проект',
    'about_github': 'GitHub разработчика',
    'about_links': 'Ссылки',
    'about_open_source': 'Открытый исходный код',
    'about_open_source_sub': 'Смотреть на GitHub',

    // Common
    'cancel': 'Отмена',
    'confirm': 'Подтвердить',
    'reset': 'Сбросить',
    'open': 'Открыть',
    'copy': 'Копировать',
    'delete': 'Удалить',
    'ok': 'OK',
    'error': 'Ошибка',
    'loading': 'Загрузка...',
    'no_chats': 'Нет чатов',
    'no_messages': 'Нет сообщений',
  };

  static const _en = <String, String>{
    // Nav
    'nav_chats': 'Chats',
    'nav_contacts': 'Contacts',
    'nav_nearby': 'Nearby',
    'nav_ether': 'Ether',

    // Settings
    'settings': 'Settings',
    'settings_appearance': 'Appearance',
    'settings_theme': 'Theme',
    'settings_theme_system': 'System',
    'settings_theme_light': 'Light',
    'settings_theme_dark': 'Dark',
    'settings_accent_color': 'Accent Color',
    'settings_chat_bg': 'Chat Background',
    'settings_chat_bg_custom': 'Custom background',
    'settings_chat_bg_none': 'No background',
    'settings_font_size': 'Font Size',
    'settings_font_small': 'Small',
    'settings_font_medium': 'Medium',
    'settings_font_large': 'Large',
    'settings_compact_mode': 'Compact Mode',
    'settings_compact_mode_sub': 'Reduce padding for higher density',
    'settings_language': 'Language',
    'settings_language_system': 'System',

    // Notifications
    'settings_notifications': 'Notifications',
    'settings_notif_messages': 'Message Notifications',
    'settings_notif_messages_sub': 'Show notification on new message',
    'settings_notif_sound': 'Sound',
    'settings_notif_vibration': 'Vibration',
    'settings_notif_previews': 'Show message preview',
    'settings_notif_previews_sub': 'Display first words of message',

    // Privacy
    'settings_privacy': 'Privacy',
    'settings_read_receipts': 'Read Receipts',
    'settings_read_receipts_sub': 'Show read checkmarks',
    'settings_online_status': 'Online Status',
    'settings_online_status_sub': 'Show green dot for online contacts',

    // Messaging
    'settings_messaging': 'Messaging',
    'settings_send_on_enter': 'Enter to Send',
    'settings_send_on_enter_sub': 'Send message with Enter key (desktop)',
    'settings_auto_download': 'Auto-download Media',
    'settings_auto_download_sub': 'Automatically receive photos, videos and files',

    // Profile
    'settings_profile': 'Profile',
    'settings_public_key': 'My Public Key',
    'settings_key_copied': 'Key copied',

    // Search
    'settings_find_user': 'Find User',
    'settings_search_by_id': 'Search by unique ID',
    'settings_search_by_id_sub': 'Open chat if you know the public key',

    // Data
    'settings_data': 'Data',
    'settings_clear_history': 'Clear chat history',
    'settings_clear_history_sub': 'Deletes all messages, contacts remain',
    'settings_delete_contacts': 'Delete all contacts',
    'settings_delete_contacts_sub': 'Contacts deleted, messages remain',

    // Danger zone
    'settings_danger': 'Danger Zone',
    'settings_reset': 'Reset App',
    'settings_reset_sub': 'Deletes profile, all chats and contacts. Irreversible.',

    // About
    'settings_about': 'About',
    'about_title': 'About Rlink',
    'about_version': 'Version',
    'about_description': 'Rlink is a decentralized Bluetooth LE messenger. Chat without internet or servers, device-to-device.',
    'about_developer': 'Developer',
    'about_website': 'Website',
    'about_telegram': 'Telegram Channel',
    'about_support': 'Support the project',
    'about_github': 'Developer GitHub',
    'about_links': 'Links',
    'about_open_source': 'Open Source',
    'about_open_source_sub': 'View on GitHub',

    // Common
    'cancel': 'Cancel',
    'confirm': 'Confirm',
    'reset': 'Reset',
    'open': 'Open',
    'copy': 'Copy',
    'delete': 'Delete',
    'ok': 'OK',
    'error': 'Error',
    'loading': 'Loading...',
    'no_chats': 'No chats',
    'no_messages': 'No messages',
  };

  static const _es = <String, String>{
    'nav_chats': 'Chats',
    'nav_contacts': 'Contactos',
    'nav_nearby': 'Cerca',
    'nav_ether': 'Éter',
    'settings': 'Ajustes',
    'settings_appearance': 'Apariencia',
    'settings_theme': 'Tema',
    'settings_theme_system': 'Sistema',
    'settings_theme_light': 'Claro',
    'settings_theme_dark': 'Oscuro',
    'settings_accent_color': 'Color de acento',
    'settings_language': 'Idioma',
    'settings_language_system': 'Sistema',
    'settings_notifications': 'Notificaciones',
    'settings_privacy': 'Privacidad',
    'settings_messaging': 'Mensajería',
    'settings_data': 'Datos',
    'settings_danger': 'Zona de peligro',
    'settings_about': 'Acerca de',
    'about_title': 'Acerca de Rlink',
    'about_version': 'Versión',
    'about_description': 'Rlink es un mensajero Bluetooth LE descentralizado.',
    'cancel': 'Cancelar',
    'confirm': 'Confirmar',
    'ok': 'OK',
  };

  static const _de = <String, String>{
    'nav_chats': 'Chats',
    'nav_contacts': 'Kontakte',
    'nav_nearby': 'In der Nähe',
    'nav_ether': 'Äther',
    'settings': 'Einstellungen',
    'settings_appearance': 'Aussehen',
    'settings_theme': 'Thema',
    'settings_theme_system': 'System',
    'settings_theme_light': 'Hell',
    'settings_theme_dark': 'Dunkel',
    'settings_accent_color': 'Akzentfarbe',
    'settings_language': 'Sprache',
    'settings_language_system': 'System',
    'settings_notifications': 'Benachrichtigungen',
    'settings_privacy': 'Datenschutz',
    'settings_messaging': 'Nachrichten',
    'settings_data': 'Daten',
    'settings_danger': 'Gefahrenzone',
    'settings_about': 'Über',
    'about_title': 'Über Rlink',
    'about_version': 'Version',
    'about_description': 'Rlink ist ein dezentraler Bluetooth-LE-Messenger.',
    'cancel': 'Abbrechen',
    'confirm': 'Bestätigen',
    'ok': 'OK',
  };

  static const _fr = <String, String>{
    'nav_chats': 'Chats',
    'nav_contacts': 'Contacts',
    'nav_nearby': 'À proximité',
    'nav_ether': 'Éther',
    'settings': 'Paramètres',
    'settings_appearance': 'Apparence',
    'settings_theme': 'Thème',
    'settings_theme_system': 'Système',
    'settings_theme_light': 'Clair',
    'settings_theme_dark': 'Sombre',
    'settings_accent_color': 'Couleur d\'accent',
    'settings_language': 'Langue',
    'settings_language_system': 'Système',
    'settings_notifications': 'Notifications',
    'settings_privacy': 'Confidentialité',
    'settings_messaging': 'Messagerie',
    'settings_data': 'Données',
    'settings_danger': 'Zone de danger',
    'settings_about': 'À propos',
    'about_title': 'À propos de Rlink',
    'about_version': 'Version',
    'about_description': 'Rlink est une messagerie Bluetooth LE décentralisée.',
    'cancel': 'Annuler',
    'confirm': 'Confirmer',
    'ok': 'OK',
  };

  static const _uk = <String, String>{
    'nav_chats': 'Чати',
    'nav_contacts': 'Контакти',
    'nav_nearby': 'Поруч',
    'nav_ether': 'Ефір',
    'settings': 'Налаштування',
    'settings_appearance': 'Зовнішній вигляд',
    'settings_theme': 'Тема',
    'settings_theme_system': 'Системна',
    'settings_theme_light': 'Світла',
    'settings_theme_dark': 'Темна',
    'settings_accent_color': 'Акцентний колір',
    'settings_language': 'Мова',
    'settings_language_system': 'Системна',
    'settings_notifications': 'Сповіщення',
    'settings_privacy': 'Конфіденційність',
    'settings_messaging': 'Повідомлення',
    'settings_data': 'Дані',
    'settings_danger': 'Небезпечна зона',
    'settings_about': 'Про проєкт',
    'about_title': 'Про Rlink',
    'about_version': 'Версія',
    'about_description': 'Rlink — децентралізований мессенджер на Bluetooth LE.',
    'cancel': 'Скасувати',
    'confirm': 'Підтвердити',
    'ok': 'OK',
  };

  static const _zh = <String, String>{
    'nav_chats': '聊天',
    'nav_contacts': '联系人',
    'nav_nearby': '附近',
    'nav_ether': '广播',
    'settings': '设置',
    'settings_appearance': '外观',
    'settings_theme': '主题',
    'settings_theme_system': '跟随系统',
    'settings_theme_light': '浅色',
    'settings_theme_dark': '深色',
    'settings_accent_color': '强调色',
    'settings_language': '语言',
    'settings_language_system': '系统',
    'settings_notifications': '通知',
    'settings_privacy': '隐私',
    'settings_messaging': '消息',
    'settings_data': '数据',
    'settings_danger': '危险区域',
    'settings_about': '关于',
    'about_title': '关于 Rlink',
    'about_version': '版本',
    'about_description': 'Rlink 是基于蓝牙LE的去中心化通讯工具。',
    'cancel': '取消',
    'confirm': '确认',
    'ok': '好',
  };

  static const Map<String, Map<String, String>> _data = {
    'ru': _ru,
    'en': _en,
    'es': _es,
    'de': _de,
    'fr': _fr,
    'uk': _uk,
    'zh': _zh,
  };

  // Supported locales for the language picker
  static const List<({String code, String name, String nativeName})> supportedLocales = [
    (code: 'system', name: 'System',    nativeName: 'Системный'),
    (code: 'ru',     name: 'Russian',   nativeName: 'Русский'),
    (code: 'en',     name: 'English',   nativeName: 'English'),
    (code: 'uk',     name: 'Ukrainian', nativeName: 'Українська'),
    (code: 'de',     name: 'German',    nativeName: 'Deutsch'),
    (code: 'fr',     name: 'French',    nativeName: 'Français'),
    (code: 'es',     name: 'Spanish',   nativeName: 'Español'),
    (code: 'zh',     name: 'Chinese',   nativeName: '中文'),
  ];
}
