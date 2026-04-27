import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'crypto_service.dart';
import 'relay_service.dart';

/// Диалог с ботом Lib: команды для регистрации сторонних ботов на relay.
class LibBotService {
  LibBotService._();
  static final LibBotService instance = LibBotService._();

  String? _awaitingBotPubForHandle;
  String _awaitingDisplayName = '';

  static const _help =
      'Lib — регистратор ботов (аналог BotFather; переписки с ботами — E2E).\n\n'
      'Полная инструкция по приложению и ботам: Настройки → Документация (RU / EN).\n\n'
      'Команды (см. также /commands):\n'
      '• /newbot <ник> — затем одним сообщением публичный ключ бота Ed25519 (64 hex). '
      'Ключ: на машине бота `python -m rlink_bot keys init` и `keys show-pub`.\n'
      '• Или одной строкой: /newbot <ник> <64hex>\n'
      '• /cancel — отменить ожидание ключа\n'
      '• /guide — краткая памятка\n\n'
      'После успеха придут claimId (32 hex) и короткий код claimCode (например ABCD-EFGH-JKLM). '
      'В claim подойдёт любой из них:\n'
      '  python -m rlink_bot claim <claimId или claimCode>\n\n'
      'Токен API — один раз в ответ claim, сохраните.\n'
      'Пользователи ищут бота по @нику на relay.';

  static const _commandsList =
      'Список команд Lib:\n\n'
      '/start, /help — справка по регистрации ботов\n'
      '/newbot <ник> — новый бот (см. кнопки под полем ввода)\n'
      '/cancel — отменить ожидание публичного ключа\n'
      '/guide — короткий чеклист создания бота\n'
      '/commands — это сообщение\n\n'
      'Документация по всему Rlink: Настройки → Документация.';

  static const _guideLines = <String>[
    'Чеклист: создать бота',
    '',
    '1) На ПК: python -m rlink_bot keys init → keys show-pub',
    '2) Здесь: /newbot ваш_ник, затем вставить 64 hex ключа',
    '3) На ПК: python -m rlink_bot claim <claimId или claimCode> --relay <wss://…>',
    '4) python -m rlink_bot run — держать процесс онлайн',
    '',
    'Подробно: Настройки → «Документация» (вкладки Русский / English).',
  ];

  /// Сброс сценария «ждём ключ» (например при выходе из чата).
  void resetAwaitingState() {
    _awaitingBotPubForHandle = null;
    _awaitingDisplayName = '';
  }

  Future<List<String>> handleUserTurn(String text) async {
    final t = text.trim();
    final lower = t.toLowerCase();

    if (_awaitingBotPubForHandle != null) {
      if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t)) {
        final handle = _awaitingBotPubForHandle!;
        final disp = _awaitingDisplayName;
        _awaitingBotPubForHandle = null;
        _awaitingDisplayName = '';
        return _registerOnRelay(
          handle: handle,
          displayName: disp,
          botPubHex: t.toLowerCase(),
        );
      }
      _awaitingBotPubForHandle = null;
      _awaitingDisplayName = '';
      return const [
        'Ожидался публичный ключ бота — ровно 64 шестнадцатеричных символа.',
        'Начните снова: /newbot ваш_ник',
      ];
    }

    if (lower == '/start' || lower == '/help') {
      return const [_help];
    }

    if (lower == '/commands' ||
        lower == '/cmd' ||
        lower.startsWith('/commands ') ||
        lower.startsWith('/cmd ')) {
      return const [_commandsList];
    }

    if (lower == '/cancel' || lower.startsWith('/cancel ')) {
      resetAwaitingState();
      return const [
        'Ожидание публичного ключа сброшено. Можно снова вызвать /newbot.',
      ];
    }

    if (lower == '/guide' || lower.startsWith('/guide ')) {
      return List<String>.from(_guideLines);
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
      if (parts.length >= 3) {
        final last = parts.last;
        if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(last)) {
          final dispParts = parts.sublist(2, parts.length - 1).join(' ').trim();
          final displayName =
              dispParts.isNotEmpty ? dispParts : handle;
          return _registerOnRelay(
            handle: handle,
            displayName: displayName,
            botPubHex: last.toLowerCase(),
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
        'На ПК с ботом: `python -m rlink_bot keys init` → `python -m rlink_bot keys show-pub`',
      ];
    }

    return const [
      'Неизвестная команда. Введите /help',
    ];
  }

  Future<List<String>> _registerOnRelay({
    required String handle,
    required String displayName,
    required String botPubHex,
  }) async {
    if (!RelayService.instance.isConnected) {
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
      if (!completer.isCompleted) completer.complete(Map<String, dynamic>.from(m));
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
      await RelayService.instance.sendBotRegisterStart(
        payloadJson: payloadJson,
        signatureHex: sig,
      );
      final ack = await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => <String, dynamic>{
          'ok': false,
          'error': 'timeout',
        },
      );
      if (ack['ok'] != true) {
        final err = ack['error']?.toString() ?? 'unknown';
        return [
          'Relay отклонил регистрацию: $err',
          if (err == 'handle_taken') 'Выберите другой @ник.',
          if (err == 'bad_signature') 'Внутренняя ошибка подписи — попробуйте ещё раз.',
          if (err == 'claim_code_alloc')
            'Не удалось выделить код заявки — попробуйте /newbot ещё раз.',
        ];
      }
      final claimId = ack['claimId'] as String? ?? '';
      final claimCode = (ack['claimCode'] as String?)?.trim() ?? '';
      if (claimId.length != 32) {
        return const ['Некорректный ответ relay (claimId).'];
      }
      final lines = <String>[
        'Заявка создана.',
        '',
        'claimId (32 hex, скопируйте):',
        claimId,
      ];
      if (claimCode.isNotEmpty) {
        lines.add('');
        lines.add('Короткий код claimCode (можно вместо claimId в команде claim):');
        lines.add(claimCode);
      }
      lines.addAll([
        '',
        'На машине с ключами бота выполните:',
        '  python -m rlink_bot claim $claimId',
      ]);
      if (claimCode.isNotEmpty) {
        lines.add('  или: python -m rlink_bot claim $claimCode');
      }
      lines.addAll([
        '',
        'Токен API придёт один раз в stdout — сохраните в секретах.',
        'Затем запуск: python -m rlink_bot run',
      ]);
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
