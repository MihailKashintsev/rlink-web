import 'dart:convert';
import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../models/emoji_pack.dart';
import 'ai_bot_constants.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'emoji_pack_service.dart';

class EmojiBotShare {
  final String previewText;
  final String invitePayloadJson;

  const EmojiBotShare({
    required this.previewText,
    required this.invitePayloadJson,
  });
}

class EmojiBotTurnResult {
  final List<String> lines;
  final EmojiBotShare? share;

  const EmojiBotTurnResult({required this.lines, this.share});
}

class _EmojiSession {
  String? activePackId;
  String? pendingShortcode;
}

/// Встроенный бот для наборов кастомных эмодзи (локально, без relay).
class EmojiBotService {
  EmojiBotService._();
  static final EmojiBotService instance = EmojiBotService._();

  final Map<String, _EmojiSession> _sessions = {};

  _EmojiSession _sessionForMe() {
    final k = CryptoService.instance.publicKeyHex;
    final key = k.isEmpty ? '_local' : k;
    return _sessions.putIfAbsent(key, () => _EmojiSession());
  }

  void resetState() {
    _sessionForMe()
      ..activePackId = null
      ..pendingShortcode = null;
  }

  static const _help = 'Emoji — свои эмодзи в виде :shortcode: в сообщениях.\n\n'
      'Команды:\n'
      '• /newpack Название — новый набор (станет текущим)\n'
      '• /add :shortcode: — затем отправьте **картинку** одним сообщением\n'
      '• /list — ваши наборы\n'
      '• /delete :shortcode: — удалить из **текущего** набора\n'
      '• /preview — перечислить эмодзи текущего набора\n'
      '• /share — карточка набора для чата (Установить у получателя)\n'
      '• /install (uuid из карточки) — установить набор из этого чата\n'
      '• /pack (uuid) — сделать набор текущим\n\n'
      'Управление: Настройки → Эмодзи.';

  static final List<(String, String)> _menuButtons = [
    ('Справка', '/help'),
    ('Новый набор', '/newpack '),
    ('Мои наборы', '/list'),
    ('Поделиться', '/share'),
  ];

  String _buttonTokens(List<(String, String)> buttons) {
    return buttons.map((b) => '[btn:${b.$1}|${b.$2}]').join(' ');
  }

  List<String> _withMenu(List<String> lines) {
    return [...lines, '', _buttonTokens(_menuButtons)];
  }

  String? _parseShortcodeArg(String line) {
    final t = line.trim();
    final m = RegExp(r':([a-zA-Z0-9_]{1,48}):').firstMatch(t);
    if (m != null) return m.group(1);
    final m2 = RegExp(r'^/add\s+(:[a-zA-Z0-9_]{1,48}:)\s*$').firstMatch(t);
    if (m2 != null) {
      final inner = RegExp(r':([a-zA-Z0-9_]{1,48}):').firstMatch(m2.group(1)!);
      return inner?.group(1);
    }
    final m3 = RegExp(r'^/(?:add|delete)\s+([a-zA-Z0-9_]{1,48})\s*$').firstMatch(t);
    return m3?.group(1);
  }

  Future<EmojiBotTurnResult> handleUserTurn(String text) async {
    final s = _sessionForMe();
    final t = text.trim();
    final lower = t.toLowerCase();

    if (lower == '/start' || lower == '/help') {
      return EmojiBotTurnResult(lines: _withMenu([_help]));
    }

    if (lower.startsWith('/newpack')) {
      final rest = t.substring('/newpack'.length).trim();
      if (rest.isEmpty) {
        return EmojiBotTurnResult(
          lines: _withMenu([
            'Укажите название: /newpack Мои смайлы',
          ]),
        );
      }
      final id = await EmojiPackService.instance.createPack(name: rest);
      s.activePackId = id;
      return EmojiBotTurnResult(
        lines: _withMenu([
          'Создан набор **$rest**.',
          'id: `$id`',
          'Он выбран как текущий. Добавьте эмодзи: /add :код:',
        ]),
      );
    }

    if (lower.startsWith('/pack ')) {
      final id = t.substring('/pack '.length).trim();
      final p = await EmojiPackService.instance.packById(id);
      if (p == null) {
        return EmojiBotTurnResult(lines: ['Набор с таким id не найден.']);
      }
      s.activePackId = id;
      return EmojiBotTurnResult(
        lines: ['Текущий набор: **${p.name}** (`$id`).'],
      );
    }

    if (lower == '/list' || lower.startsWith('/list ')) {
      final packs = await EmojiPackService.instance.loadPacks();
      if (packs.isEmpty) {
        return EmojiBotTurnResult(lines: ['Пока нет наборов. Создайте: /newpack Имя']);
      }
      final lines = <String>['Ваши наборы:'];
      for (final p in packs) {
        final cur = s.activePackId == p.id ? ' ← текущий' : '';
        lines.add('• **${p.name}** — `${p.id}` (${p.emojis.length}) $cur');
      }
      return EmojiBotTurnResult(lines: _withMenu(lines));
    }

    if (lower.startsWith('/add')) {
      final sc = _parseShortcodeArg(t);
      if (sc == null) {
        return EmojiBotTurnResult(
          lines: ['Укажите шорткод: /add :smile:'],
        );
      }
      if (s.activePackId == null) {
        return EmojiBotTurnResult(
          lines: [
            'Сначала выберите или создайте набор: /newpack Имя или /pack (uuid)',
          ],
        );
      }
      s.pendingShortcode = sc;
      return EmojiBotTurnResult(
        lines: [
          'Жду **картинку** для :$sc: (следующее сообщение с фото/стикером/GIF).',
          'Отмена: отправьте /cancel',
        ],
      );
    }

    if (lower == '/cancel' || lower.startsWith('/cancel ')) {
      s.pendingShortcode = null;
      return EmojiBotTurnResult(lines: ['Ожидание картинки сброшено.']);
    }

    if (lower.startsWith('/delete')) {
      final sc = _parseShortcodeArg(t);
      if (sc == null) {
        return EmojiBotTurnResult(lines: ['Пример: /delete :smile:']);
      }
      if (s.activePackId == null) {
        return EmojiBotTurnResult(lines: ['Нет текущего набора. Укажите /pack id']);
      }
      await EmojiPackService.instance.deleteEmoji(s.activePackId!, sc);
      return EmojiBotTurnResult(lines: ['Удалено :$sc: из текущего набора.']);
    }

    if (lower == '/preview' || lower.startsWith('/preview ')) {
      if (s.activePackId == null) {
        return EmojiBotTurnResult(lines: ['Нет текущего набора.']);
      }
      final p = await EmojiPackService.instance.packById(s.activePackId!);
      if (p == null || p.emojis.isEmpty) {
        return EmojiBotTurnResult(lines: ['В текущем наборе пока нет эмодзи.']);
      }
      final lines = <String>['**${p.name}** (${p.emojis.length}):'];
      for (final e in p.emojis) {
        lines.add(':${e.shortcode}:');
      }
      return EmojiBotTurnResult(lines: lines);
    }

    if (lower == '/share' || lower.startsWith('/share ')) {
      if (s.activePackId == null) {
        return EmojiBotTurnResult(lines: ['Нет текущего набора для шаринга.']);
      }
      final pack = await EmojiPackService.instance.packById(s.activePackId!);
      if (pack == null || pack.emojis.isEmpty) {
        return EmojiBotTurnResult(lines: ['В наборе нет эмодзи для карточки.']);
      }
      final share = await _buildShare(pack);
      return EmojiBotTurnResult(
        lines: const [],
        share: share,
      );
    }

    if (lower.startsWith('/install')) {
      final arg = t.contains(' ')
          ? t.substring(t.indexOf(' ')).trim()
          : '';
      if (arg.isEmpty) {
        return EmojiBotTurnResult(
          lines: ['Укажите id набора с карточки: /install `<uuid>`'],
        );
      }
      final payload = await _findSharePayloadByPackId(arg);
      if (payload == null) {
        return EmojiBotTurnResult(
          lines: [
            'Карточка с id `$arg` не найдена в этом чате.',
            'Откройте сообщение с карточкой выше или попросите отправить /share снова.',
          ],
        );
      }
      final newId = await EmojiPackService.instance.installFromSharePayload(payload);
      if (newId == null) {
        return EmojiBotTurnResult(
          lines: ['Не удалось установить набор (нет данных в карточке).'],
        );
      }
      s.activePackId = newId;
      return EmojiBotTurnResult(
        lines: [
          'Набор установлен.',
          'Новый id: `$newId` (копия на устройстве).',
        ],
      );
    }

    return EmojiBotTurnResult(
      lines: ['Неизвестная команда. /help'],
    );
  }

  Future<Map<String, dynamic>?> _findSharePayloadByPackId(String packId) async {
    final msgs =
        await ChatStorageService.instance.getMessages(kEmojiBotPeerId);
    for (var i = msgs.length - 1; i >= 0; i--) {
      final raw = msgs[i].invitePayloadJson;
      if (raw == null || raw.isEmpty) continue;
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final ty = m['type'] as String? ?? m['kind'] as String?;
        if (ty != 'emoji_pack') continue;
        if ((m['id'] as String?) == packId) {
          return m;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<EmojiBotShare> _buildShare(EmojiPack pack) async {
    await EmojiPackService.instance.ensureInitialized();
    await EmojiPackService.instance.warmIndex();
    final outEmojis = <Map<String, dynamic>>[];
    const maxItems = 24;
    var n = 0;
    for (final e in pack.emojis) {
      if (n >= maxItems) break;
      final abs = await EmojiPackService.instance.absolutePathForEmoji(e);
      if (abs == null) continue;
      final bytes = await File(abs).readAsBytes();
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 128,
        minHeight: 128,
        quality: 82,
        format: CompressFormat.png,
      );
      if (compressed.isEmpty) continue;
      outEmojis.add({
        'shortcode': e.shortcode,
        'data': base64Encode(compressed),
      });
      n++;
    }
    final payload = <String, dynamic>{
      'type': 'emoji_pack',
      'kind': 'emoji_pack',
      'id': pack.id,
      'name': pack.name,
      'emojis': outEmojis,
    };
    final jsonStr = jsonEncode(payload);
    return EmojiBotShare(
      previewText: 'Набор эмодзи: ${pack.name}',
      invitePayloadJson: jsonStr,
    );
  }

  /// После сохранения исходящего сообщения с картинкой в чат с Emoji-ботом.
  Future<List<String>> handleOutgoingImage({
    required String resolvedImagePath,
  }) async {
    final s = _sessionForMe();
    final sc = s.pendingShortcode;
    final packId = s.activePackId;
    if (sc == null || packId == null) {
      return const [
        'Картинка получена. Если хотите добавить эмодзи в набор — сначала /add :код:',
      ];
    }
    try {
      await EmojiPackService.instance.addEmoji(
        packId: packId,
        shortcode: sc,
        absoluteImagePath: resolvedImagePath,
      );
      s.pendingShortcode = null;
      return [
        'Добавлено :$sc: в текущий набор.',
      ];
    } catch (e) {
      return ['Ошибка: $e'];
    }
  }
}
