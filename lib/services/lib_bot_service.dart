import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'crypto_service.dart';
import 'relay_service.dart';

/// Диалог с ботом Lib: команды для регистрации сторонних ботов на relay.
class LibBotService {
  LibBotService._();
  static final LibBotService instance = LibBotService._();

  /// Совпадает с `_reservedBotHandles` на relay (`server.dart`).
  static const Set<String> _reservedRelayBotHandles = {
    'lib',
    'gigachat',
    'admin',
    'support',
    'rlink',
    'system',
    'botfather',
    'rendergames',
  };

  String? _awaitingBotPubForHandle;
  String _awaitingDisplayName = '';

  Future<bool> _ensureRelayConnected() async {
    if (RelayService.instance.isConnected) return true;
    await RelayService.instance.connect();
    if (RelayService.instance.isConnected) return true;
    if (RelayService.instance.state.value == RelayState.connecting) {
      // На мобильной сети/после wake-up websocket иногда поднимается не за 2-3 сек.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (RelayService.instance.isConnected) return true;
        if (RelayService.instance.state.value == RelayState.disconnected) break;
      }
    }
    return RelayService.instance.isConnected;
  }

  String _normalizeMediaUrl(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return t;
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    if (t.startsWith('www.')) return 'https://$t';
    return t;
  }

  static const _help =
      'Lib — регистратор ботов (аналог BotFather; переписки с ботами — E2E).\n\n'
      'Полная инструкция по приложению и ботам: Настройки → Документация (RU / EN).\n\n'
      'Команды (см. также /commands):\n'
      '• /mybots — ваши боты на relay (ник, имя, описание)\n'
      '• /setname @ник новое_имя — отображаемое имя (1–64 символа)\n'
      '• /setdesc @ник текст — описание (до 512; пустой текст — очистить)\n'
      '• /setavatar @ник <url> — URL аватара (http/https); без URL — сбросить\n'
      '• /setbanner @ник <url> — баннер; без URL — сбросить\n'
      '• /setcommands @ник /cmd1 Описание, /cmd2 Описание — команды в профиле и автодополнение\n'
      '• /delbot @ник — удалить (отозвать) бота из каталога relay\n'
      '• /newbot <ник> — затем **в чат Lib** одним сообщением публичный ключ бота Ed25519 (64 hex). '
      'Ключ копируют с ПК: `python -m rlink_bot keys show-pub` (в терминал ключ вводить не нужно).\n'
      '• Или одной строкой: /newbot <ник> <64hex>\n'
      '• /cancel — отменить ожидание ключа\n'
      '• /guide — краткая памятка\n\n'
      'После успеха придут claimId (32 hex) и короткий код claimCode. '
      'На ПК достаточно одной команды (relay по умолчанию как в приложении):\n'
      '  python -m rlink_bot onboard <claimCode или claimId> --file bot_keys.json\n\n'
      'Токен API — один раз в ответ claim, сохраните.\n'
      'Пользователи ищут бота по @нику на relay.';

  static const _commandsList = 'Список команд Lib:\n\n'
      '/start, /help — справка\n'
      '/mybots — список ваших ботов на relay\n'
      '/setname @ник имя — имя в каталоге\n'
      '/setdesc @ник текст — описание (пусто = очистить)\n'
      '/setavatar @ник [url] — аватар по URL или сброс без url\n'
      '/setbanner @ник [url] — баннер или сброс\n'
      '/setcommands @ник /cmd1 Описание, /cmd2 … — список slash-команд бота\n'
      '/delbot @ник — удалить бота из каталога relay\n'
      '/newbot <ник> — новый бот (см. кнопки под полем ввода)\n'
      '/cancel — отменить ожидание публичного ключа\n'
      '/guide — короткий чеклист создания бота\n'
      '/commands — это сообщение\n\n'
      'После /newbot на ПК: python -m rlink_bot onboard <код из Lib> --file bot_keys.json\n\n'
      'Документация по всему Rlink: Настройки → Документация.';

  static const List<(String, String)> _menuButtons = [
    ('Справка', '/help'),
    ('Команды', '/commands'),
    ('Мои боты', '/mybots'),
    ('Новый бот', '/newbot my_bot'),
    ('Удалить бота', '/delbot @'),
    ('Памятка', '/guide'),
  ];

  String _buttonTokens(List<(String, String)> buttons) {
    return buttons.map((b) => '[btn:${b.$1}|${b.$2}]').join(' ');
  }

  List<String> _withMenuButtons(List<String> lines) {
    return <String>[
      ...lines,
      '',
      _buttonTokens(_menuButtons),
    ];
  }

  static const _guideLines = <String>[
    'Чеклист: создать бота',
    '',
    '1) На ПК: python -m rlink_bot keys init → keys show-pub',
    '2) Здесь: /newbot ваш_ник, затем вставить 64 hex ключа',
    '3) На ПК: python -m rlink_bot onboard <код из Lib> --file bot_keys.json',
    '4) python -m rlink_bot run — держать процесс онлайн',
    '',
    'Подробно: Настройки → «Документация» (вкладки Русский / English).',
  ];

  /// Сброс сценария «ждём ключ» (например при выходе из чата).
  void resetAwaitingState() {
    _awaitingBotPubForHandle = null;
    _awaitingDisplayName = '';
  }

  /// 64 hex подряд из вставки (игнорирует префиксы вроде «Ed25519…», пробелы, переводы строк).
  String? _extract64HexBotPub(String raw) {
    final hexRun = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hexRun.length != 64) return null;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexRun)) return null;
    return hexRun.toLowerCase();
  }

  Future<List<String>> handleUserTurn(String text) async {
    final t = text.trim();
    final lower = t.toLowerCase();

    if (_awaitingBotPubForHandle != null) {
      final extracted = _extract64HexBotPub(t);
      if (extracted != null) {
        final handle = _awaitingBotPubForHandle!;
        final disp = _awaitingDisplayName;
        _awaitingBotPubForHandle = null;
        _awaitingDisplayName = '';
        return _registerOnRelay(
          handle: handle,
          displayName: disp,
          botPubHex: extracted,
        );
      }
      final oneLine = t.trim().replaceAll(RegExp(r'\s'), '');
      if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(oneLine)) {
        _awaitingBotPubForHandle = null;
        _awaitingDisplayName = '';
        return const [
          'Похоже на **claimId** (32 hex) из ответа Lib, а не на публичный ключ бота.',
          'claimId и claimCode используются **только на ПК**: `python -m rlink_bot onboard …`',
          'В чат Lib нужно отправить **64 hex** публичного ключа (`keys show-pub`).',
          'Начните снова: /newbot ваш_ник',
        ];
      }
      final claimFlat = oneLine.toUpperCase().replaceAll(RegExp(r'[-_]'), '');
      if (claimFlat.length == 12 &&
          RegExp(r'^[23456789ABCDEFGHJKMNPRSTWXYZ]{12}$').hasMatch(claimFlat)) {
        _awaitingBotPubForHandle = null;
        _awaitingDisplayName = '';
        return const [
          'Похоже на **claimCode** из ответа Lib, а не на публичный ключ бота.',
          'Короткий код нужен **на ПК** в `onboard`, в чат Lib его вставлять не нужно.',
          'Сюда — **64 hex** публичного ключа бота. Снова: /newbot ваш_ник',
        ];
      }
      _awaitingBotPubForHandle = null;
      _awaitingDisplayName = '';
      return const [
        'Ожидался публичный ключ бота — ровно 64 шестнадцатеричных символа.',
        'Начните снова: /newbot ваш_ник',
      ];
    }

    if (lower == '/start' || lower == '/help') {
      return _withMenuButtons([_help]);
    }

    if (lower == '/commands' ||
        lower == '/cmd' ||
        lower.startsWith('/commands ') ||
        lower.startsWith('/cmd ')) {
      return _withMenuButtons([_commandsList]);
    }

    if (lower == '/cancel' || lower.startsWith('/cancel ')) {
      resetAwaitingState();
      return const [
        'Ожидание публичного ключа сброшено. Можно снова вызвать /newbot.',
      ];
    }

    if (lower == '/guide' || lower.startsWith('/guide ')) {
      return _withMenuButtons(List<String>.from(_guideLines));
    }

    if (lower == '/mybots' || lower.startsWith('/mybots ')) {
      return _myBotsLines();
    }

    if (lower.startsWith('/setname')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 3) {
        return const [
          'Использование: /setname @ник новое_имя',
          'Пример: /setname @mybot Книжный маг',
        ];
      }
      final h = _parseHandleArg(parts[1]);
      if (h == null) {
        return const ['Некорректный ник. Допустимы a–z, 0–9, _, длина от 2.'];
      }
      final name = parts.sublist(2).join(' ').trim();
      if (name.isEmpty || name.length > 64) {
        return const ['Имя: от 1 до 64 символов.'];
      }
      return _patchOwnedBot(handleNorm: h, changes: {'displayName': name});
    }

    if (lower.startsWith('/setdesc')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return const [
          'Использование: /setdesc @ник [текст описания]',
          'Без текста после ника — очистить описание.',
        ];
      }
      final h = _parseHandleArg(parts[1]);
      if (h == null) {
        return const ['Некорректный ник. Допустимы a–z, 0–9, _, длина от 2.'];
      }
      final desc = parts.length > 2 ? parts.sublist(2).join(' ').trim() : '';
      if (desc.length > 512) {
        return const ['Описание не длиннее 512 символов.'];
      }
      return _patchOwnedBot(handleNorm: h, changes: {'description': desc});
    }

    if (lower.startsWith('/setavatar')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return const [
          'Использование: /setavatar @ник <url>',
          'Только @ник — сбросить аватар.',
        ];
      }
      final h = _parseHandleArg(parts[1]);
      if (h == null) {
        return const ['Некорректный ник. Допустимы a–z, 0–9, _, длина от 2.'];
      }
      if (parts.length == 2) {
        return _patchOwnedBot(handleNorm: h, changes: {'clearAvatar': true});
      }
      final url = _normalizeMediaUrl(parts.sublist(2).join(' ').trim());
      return _patchOwnedBot(handleNorm: h, changes: {'avatarUrl': url});
    }

    if (lower.startsWith('/setbanner')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return const [
          'Использование: /setbanner @ник <url>',
          'Только @ник — сбросить баннер.',
        ];
      }
      final h = _parseHandleArg(parts[1]);
      if (h == null) {
        return const ['Некорректный ник. Допустимы a–z, 0–9, _, длина от 2.'];
      }
      if (parts.length == 2) {
        return _patchOwnedBot(handleNorm: h, changes: {'clearBanner': true});
      }
      final url = _normalizeMediaUrl(parts.sublist(2).join(' ').trim());
      return _patchOwnedBot(handleNorm: h, changes: {'bannerUrl': url});
    }

    if (lower.startsWith('/setcommands')) {
      final m = RegExp(
        r'^/setcommands\s+@([a-z0-9_]{2,32})\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(t.trim());
      if (m == null) {
        return const [
          'Использование: /setcommands @ник /команда1 Описание, /команда2 Описание',
          'Пары разделяются запятой перед следующей «/» (запятые внутри описания допустимы).',
          'Пример: /setcommands @mybot /start Начало работы, /help Справка',
        ];
      }
      final h = m.group(1)!.toLowerCase();
      final rest = m.group(2)!;
      final segments = rest.split(RegExp(r',\s*(?=\/)'));
      final out = <Map<String, String>>[];
      for (final seg in segments) {
        final s = seg.trim();
        if (s.isEmpty) continue;
        final space = s.indexOf(' ');
        if (space <= 0) {
          return [
            'После команды нужен пробел и описание: `$s`',
          ];
        }
        final cmd = s.substring(0, space).trim();
        final desc = s.substring(space + 1).trim();
        if (!RegExp(r'^/[a-z0-9_]{1,63}$', caseSensitive: false)
            .hasMatch(cmd)) {
          return [
            'Некорректная команда: `$cmd` (формат: /имя, латиница, цифры, _).',
          ];
        }
        if (desc.length > 256) {
          return ['Описание для `$cmd` не длиннее 256 символов.'];
        }
        out.add({'cmd': cmd.toLowerCase(), 'desc': desc});
      }
      if (out.isEmpty) {
        return const ['Укажите хотя бы одну команду после ника.'];
      }
      if (out.length > 32) {
        return const ['Не больше 32 команд за раз.'];
      }
      return _setCommandsForOwnedBot(handleNorm: h, commands: out);
    }

    if (lower.startsWith('/newbot')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return const [
          'Использование: /newbot <ник>',
          'Затем отдельным сообщением — публичный Ed25519 ключ бота (64 hex), '
              'или одной строкой: /newbot <ник> <64hex>',
        ];
      }
      var handle = parts[1].toLowerCase().replaceAll('@', '');
      handle = handle.replaceAll(RegExp(r'[^a-z0-9_]'), '');
      if (handle.length < 2) {
        return const ['Ник слишком короткий. Допустимы a-z, 0-9, _.'];
      }
      if (handle.length > 32) {
        return const ['Ник не длиннее 32 символов.'];
      }
      if (_reservedRelayBotHandles.contains(handle)) {
        return [
          'Ник @$handle зарезервирован на relay (служебные имена, как у бренда и системных ботов).',
          'Выберите другой, например: rlink_help, my_shop_bot.',
          'Список зарезервированных: ${_reservedRelayBotHandles.join(", ")}.',
        ];
      }
      if (parts.length >= 3) {
        final pub = _extract64HexBotPub(parts.last);
        if (pub != null) {
          final dispParts = parts.sublist(2, parts.length - 1).join(' ').trim();
          final displayName = dispParts.isNotEmpty ? dispParts : handle;
          return _registerOnRelay(
            handle: handle,
            displayName: displayName,
            botPubHex: pub,
          );
        }
      }
      final displayName =
          parts.length > 2 ? parts.sublist(2).join(' ').trim() : handle;
      _awaitingBotPubForHandle = handle;
      _awaitingDisplayName = displayName.isEmpty ? handle : displayName;
      return [
        'Ник бота: @$handle',
        'Отображаемое имя: $displayName',
        '',
        'Следующим сообщением пришлите **публичный** ключ Ed25519 бота (64 hex).',
        'Вставьте ключ **сюда, в этот чат с Lib** (не только в терминал).',
        'На ПК: `python -m rlink_bot keys show-pub` — скопируйте одну строку из вывода.',
      ];
    }

    if (lower.startsWith('/delbot')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return const [
          'Использование: /delbot @ник',
          'Пример: /delbot @mybot',
        ];
      }
      final h = _parseHandleArg(parts[1]);
      if (h == null) {
        return const ['Некорректный ник. Допустимы a–z, 0–9, _, длина от 2.'];
      }
      return _revokeOwnedBot(handleNorm: h);
    }

    return _withMenuButtons(const [
      'Неизвестная команда. Введите /help',
    ]);
  }

  /// Ник после @ или без; только a-z, 0-9, _; длина 2–32.
  String? _parseHandleArg(String raw) {
    var h = raw.trim().toLowerCase();
    if (h.startsWith('@')) h = h.substring(1);
    h = h.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (h.length < 2 || h.length > 32) return null;
    return h;
  }

  String _ownerListErr(Map<String, dynamic> ack) {
    final e = ack['error']?.toString() ?? 'unknown';
    switch (e) {
      case 'offline':
        return 'Relay не подключён.';
      case 'timeout':
        return 'Таймаут ответа relay. Проверьте соединение и попробуйте снова.';
      case 'rate_limited':
        return 'Слишком частые запросы к relay. Подождите немного.';
      case 'bad_signature':
      case 'stale_ts':
        return 'Запрос отклонён relay ($e). Попробуйте ещё раз.';
      default:
        return 'Ошибка relay: $e';
    }
  }

  String _botCommandsSetErr(Map<String, dynamic> ack) {
    final e = ack['error']?.toString() ?? 'unknown';
    switch (e) {
      case 'offline':
        return 'Relay не подключён.';
      case 'timeout':
        return 'Таймаут ответа relay.';
      case 'not_found':
        return 'Бот не найден в каталоге relay.';
      case 'not_owner':
        return 'Этот бот привязан к другому владельцу.';
      case 'bad_commands':
      case 'bad_command_entry':
        return 'Некорректный формат команд для relay.';
      case 'too_many_commands':
        return 'Не больше 32 команд.';
      case 'rate_limited':
        return 'Слишком частые запросы к relay. Подождите немного.';
      case 'bad_signature':
      case 'stale_ts':
        return 'Запрос отклонён relay ($e). Попробуйте ещё раз.';
      default:
        return 'Ошибка relay: $e';
    }
  }

  String _ownerPatchErr(Map<String, dynamic> ack) {
    final e = ack['error']?.toString() ?? 'unknown';
    switch (e) {
      case 'offline':
        return 'Relay не подключён.';
      case 'timeout':
        return 'Таймаут ответа relay. Возможно на сервере ещё нет поддержки bot_owner_patch '
            '(обновите relay до актуального server.dart) или нестабильное соединение.';
      case 'not_found':
        return 'Бот не найден в каталоге relay.';
      case 'not_owner':
        return 'Этот бот привязан к другому владельцу.';
      case 'bad_display_name':
        return 'Некорректное имя (1–64 символа, не пустое).';
      case 'description_too_long':
        return 'Описание не длиннее 512 символов.';
      case 'bad_url':
        return 'Некорректный URL (нужны http или https, длина до 2048).';
      case 'rate_limited':
        return 'Слишком частые запросы к relay. Подождите немного.';
      case 'empty_patch':
        return 'Пустое изменение.';
      case 'already_revoked':
        return 'Бот уже удалён (revoked).';
      default:
        return 'Ошибка relay: $e';
    }
  }

  Future<(List<Map<String, dynamic>>, String?)> _loadMyBots() async {
    final ack = await RelayService.instance.sendBotOwnerList();
    if (ack['ok'] != true) {
      return (<Map<String, dynamic>>[], _ownerListErr(ack));
    }
    final raw = ack['bots'];
    if (raw is! List) {
      return (<Map<String, dynamic>>[], 'Некорректный ответ relay (bots).');
    }
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      out.add(Map<String, dynamic>.from(item));
    }
    return (out, null);
  }

  Map<String, dynamic>? _findOwnedBotByHandle(
    List<Map<String, dynamic>> bots,
    String handleNorm,
  ) {
    for (final b in bots) {
      if ((b['handle'] as String?)?.toLowerCase() == handleNorm) return b;
    }
    return null;
  }

  Future<List<String>> _myBotsLines() async {
    if (!await _ensureRelayConnected()) {
      return const [
        'Relay не подключён.',
        'Проверьте интернет и URL relay в настройках сети, затем повторите команду.',
      ];
    }
    final (bots, err) = await _loadMyBots();
    if (err != null) return [err];
    if (bots.isEmpty) {
      return const [
        'У вас пока нет ботов на этом relay.',
        'Создать: /newbot ваш_ник',
      ];
    }
    final lines = <String>['Ваши боты на relay (${bots.length}):', ''];
    for (final b in bots) {
      final h = b['handle'] as String? ?? '';
      final dn = b['displayName'] as String? ?? h;
      final d = (b['description'] as String?)?.trim() ?? '';
      lines.add('@$h — $dn');
      if (d.isNotEmpty) {
        final short = d.length > 120 ? '${d.substring(0, 117)}…' : d;
        lines.add('  $short');
      }
      lines.add('');
    }
    lines.add(
        'Правки: /setname, /setdesc, /setavatar, /setbanner, /setcommands (см. /help).');
    lines.add('Удалить бота: /delbot @ник');
    return lines;
  }

  Future<List<String>> _revokeOwnedBot({
    required String handleNorm,
  }) async {
    final res = await _patchOwnedBot(
      handleNorm: handleNorm,
      changes: const {'revoke': true},
    );
    if (res.length == 1 && res.first.startsWith('Готово:')) {
      return [
        'Готово: @$handleNorm удалён из каталога relay.',
        'Повторно заново добавить можно через /newbot @$handleNorm <64hex>.',
      ];
    }
    return res;
  }

  Future<List<String>> _setCommandsForOwnedBot({
    required String handleNorm,
    required List<Map<String, String>> commands,
  }) async {
    if (!await _ensureRelayConnected()) {
      return const [
        'Relay не подключён.',
        'Проверьте интернет и URL relay в настройках сети, затем повторите команду.',
      ];
    }
    final (bots, err) = await _loadMyBots();
    if (err != null) return [err];
    final row = _findOwnedBotByHandle(bots, handleNorm);
    if (row == null) {
      return [
        'Бот @$handleNorm не найден среди ваших на relay.',
        'Список: /mybots',
      ];
    }
    final botId = (row['botId'] as String?) ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(botId)) {
      return const ['Внутренняя ошибка: некорректный botId.'];
    }
    final ack =
        await RelayService.instance.sendBotCommandsSetOwner(
      botId: botId,
      commands: commands,
    );
    if (ack['ok'] == true) {
      return [
        'Готово: команды для @$handleNorm обновлены на relay (${commands.length}).',
      ];
    }
    return [_botCommandsSetErr(ack)];
  }

  Future<List<String>> _patchOwnedBot({
    required String handleNorm,
    required Map<String, dynamic> changes,
  }) async {
    if (!await _ensureRelayConnected()) {
      return const [
        'Relay не подключён.',
        'Проверьте интернет и URL relay в настройках сети, затем повторите команду.',
      ];
    }
    final (bots, err) = await _loadMyBots();
    if (err != null) return [err];
    final row = _findOwnedBotByHandle(bots, handleNorm);
    if (row == null) {
      return [
        'Бот @$handleNorm не найден среди ваших на relay.',
        'Список: /mybots',
      ];
    }
    final botId = (row['botId'] as String?) ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(botId)) {
      return const ['Внутренняя ошибка: некорректный botId.'];
    }
    final ack = await RelayService.instance
        .sendBotOwnerPatch(botId: botId, changes: changes);
    if (ack['ok'] == true) {
      return ['Готово: @$handleNorm обновлён на relay.'];
    }
    return [_ownerPatchErr(ack)];
  }

  Future<List<String>> _registerOnRelay({
    required String handle,
    required String displayName,
    required String botPubHex,
  }) async {
    if (!await _ensureRelayConnected()) {
      return const [
        'Relay не подключён. Включите интернет-соединение в настройках и попробуйте снова.',
      ];
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(botPubHex)) {
      return const ['Некорректный публичный ключ (нужны 64 hex-символа).'];
    }

    final owner = CryptoService.instance.publicKeyHex.toLowerCase();
    if (owner.isEmpty) {
      return const ['Ключи аккаунта не готовы.'];
    }
    if (botPubHex == owner) {
      return const ['Ключ бота должен отличаться от вашего личного ключа.'];
    }

    final completer = Completer<Map<String, dynamic>>();
    void listener(Map<String, dynamic> m) {
      if (!completer.isCompleted) {
        completer.complete(Map<String, dynamic>.from(m));
      }
    }

    RelayService.instance.onBotRegisterAck = listener;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final payloadObj = <String, dynamic>{
        'v': 1,
        'owner': owner,
        'handle': handle,
        'displayName': displayName,
        'botPublicKey': botPubHex,
        'description': '',
        'ts': ts,
      };
      final payloadJson = jsonEncode(payloadObj);
      final sig = await CryptoService.instance.signUtf8Message(payloadJson);
      final sent = await RelayService.instance.sendBotRegisterStart(
        payloadJson: payloadJson,
        signatureHex: sig,
      );
      if (!sent) {
        return const [
          'Запрос на relay не отправлен (нет WebSocket или ошибка сети).',
          'Проверьте, что relay подключён (интернет / настройки), и повторите /newbot.',
        ];
      }
      final ack = await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => <String, dynamic>{
          'ok': false,
          'error': 'timeout',
        },
      );
      if (ack['ok'] != true) {
        final err = ack['error']?.toString() ?? 'unknown';
        if (err == 'timeout') {
          // Защита от ложного timeout: сервер мог применить заявку, но ack потерялся.
          final (bots, listErr) = await _loadMyBots();
          if (listErr == null) {
            final row = _findOwnedBotByHandle(bots, handle);
            final rowBotId = (row?['botId'] as String?)?.toLowerCase() ?? '';
            if (rowBotId == botPubHex) {
              return [
                'Похоже, relay зарегистрировал бота, но подтверждение пришло с задержкой.',
                '@$handle уже есть в вашем списке (/mybots).',
                'Продолжайте шаг onboarding на ПК как обычно.',
              ];
            }
          }
        }
        return [
          'Relay отклонил регистрацию: $err',
          if (err == 'timeout') ...[
            '',
            'Relay: ${RelayService.instance.serverUrl ?? RelayService.defaultServerUrl}',
            '',
            'За 45 с не пришёл ответ (bot_register_ack). Чаще всего на этом URL **ещё не задеплоена** текущая версия relay из репозитория (ветка с `bot_register_start` в server.dart) — сервер тогда **молча игнорирует** запрос.',
            'Что сделать: обновить/задеплоить `relay_server` на хост, который обслуживает этот WebSocket, либо временно поднять свой relay для теста.',
            '',
            'У вас в скриншоте шаги верные: ключ в чат Lib после /newbot — так и должно быть.',
          ],
          if (err == 'handle_taken') 'Выберите другой @ник.',
          if (err == 'bad_handle')
            'Ник не принят: зарезервированное слово, недопустимые символы или длина не 2–32 (см. подсказку Lib при /newbot).',
          if (err == 'bad_signature')
            'Внутренняя ошибка подписи — попробуйте ещё раз.',
          if (err == 'claim_code_alloc')
            'Не удалось выделить код заявки — попробуйте /newbot ещё раз.',
        ];
      }
      final claimId = ack['claimId'] as String? ?? '';
      final claimCode = (ack['claimCode'] as String?)?.trim() ?? '';
      if (claimId.length != 32) {
        return const ['Некорректный ответ relay (claimId).'];
      }
      final claimOne = claimCode.isNotEmpty ? claimCode : claimId;
      final lines = <String>[
        'Заявка создана.',
        '',
        'Скопируйте одно значение (удобнее короткий claimCode):',
        if (claimCode.isNotEmpty) 'claimCode: $claimCode',
        'claimId: $claimId',
        '',
        'На машине с файлом ключей бота (см. keys init):',
        '  python -m rlink_bot onboard $claimOne --file bot_keys.json',
        '',
        'Relay по умолчанию как в приложении Rlink; другой сервер: добавьте --relay wss://…',
        '',
        'Токен API — один раз в stdout; затем держите бота онлайн:',
        '  python -m rlink_bot run --file bot_keys.json',
        '',
        'Пример «вставил код в файл»: tools/rlink_bot/example_echo_bot.py',
      ];
      return lines;
    } catch (e, st) {
      debugPrint('[LibBot] register: $e\n$st');
      return ['Ошибка: $e'];
    } finally {
      if (RelayService.instance.onBotRegisterAck == listener) {
        RelayService.instance.onBotRegisterAck = null;
      }
    }
  }
}
