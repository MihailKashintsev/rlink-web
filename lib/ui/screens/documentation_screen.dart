import 'package:flutter/material.dart';

import '../../app_version.dart';
import '../rlink_nav_routes.dart';

/// Встроенная справка Rlink и ботов (RU / EN).
class DocumentationScreen extends StatelessWidget {
  const DocumentationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          title: const Text('Документация'),
          elevation: 0,
          scrolledUnderElevation: 0.5,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Русский'),
              Tab(text: 'English'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _DocBody(text: _docRu, version: AppVersion.label),
            _DocBody(text: _docEn, version: AppVersion.label),
          ],
        ),
      ),
    );
  }

  /// Открыть из настроек с единым переходом.
  static void open(BuildContext context) {
    Navigator.push(context, rlinkPushRoute(const DocumentationScreen()));
  }
}

class _DocBody extends StatelessWidget {
  final String text;
  final String version;

  const _DocBody({required this.text, required this.version});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF121212) : const Color(0xFFF7F7F7);
    final blocks = _parseDocBlocks(text.replaceAll('{VERSION}', version), cs);

    return ColoredBox(
      color: surface,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 40),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: blocks,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Парсер: ## / ###, таблицы |…|, списки • / 1., **жирный**, `код` ─────

List<String> _splitTableRow(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return t.split('|').map((c) => c.trim()).toList();
}

bool _isTableRow(String line) {
  final t = line.trim();
  return t.startsWith('|') && t.endsWith('|') && t.contains('|', 1);
}

bool _isTableSeparatorRow(List<String> cells) {
  if (cells.isEmpty) return false;
  return cells.every((c) => RegExp(r'^[\s\-:]+$').hasMatch(c));
}

bool _isBulletLine(String line) {
  final t = line.trimLeft();
  return t.startsWith('• ') ||
      t.startsWith('- ') ||
      RegExp(r'^\d+\.\s').hasMatch(t);
}

String _stripListPrefix(String line) {
  var t = line.trimLeft();
  if (t.startsWith('• ')) return t.substring(2).trimLeft();
  if (t.startsWith('- ')) return t.substring(2).trimLeft();
  final m = RegExp(r'^\d+\.\s').firstMatch(t);
  if (m != null) return t.substring(m.end).trimLeft();
  return t;
}

/// `**bold**` и `` `mono` `` внутри одной строки/абзаца.
List<InlineSpan> _inlineSpans(String line, TextStyle base, TextStyle bold, TextStyle mono) {
  final out = <InlineSpan>[];
  var rest = line;
  while (rest.isNotEmpty) {
    final codeIdx = rest.indexOf('`');
    final boldIdx = rest.indexOf('**');
    int? nextKind; // 0=code, 1=bold
    int nextPos = rest.length;
    if (codeIdx >= 0 && codeIdx < nextPos) {
      nextPos = codeIdx;
      nextKind = 0;
    }
    if (boldIdx >= 0 && boldIdx < nextPos) {
      nextPos = boldIdx;
      nextKind = 1;
    }
    if (nextPos == rest.length) {
      out.add(TextSpan(text: rest, style: base));
      break;
    }
    if (nextPos > 0) {
      out.add(TextSpan(text: rest.substring(0, nextPos), style: base));
    }
    rest = rest.substring(nextPos);
    if (nextKind == 0) {
      rest = rest.substring(1);
      final end = rest.indexOf('`');
      if (end < 0) {
        out.add(TextSpan(text: '`$rest', style: base));
        break;
      }
      out.add(TextSpan(text: rest.substring(0, end), style: mono));
      rest = rest.substring(end + 1);
    } else {
      rest = rest.substring(2);
      final end = rest.indexOf('**');
      if (end < 0) {
        out.add(TextSpan(text: '**$rest', style: base));
        break;
      }
      out.add(TextSpan(text: rest.substring(0, end), style: bold));
      rest = rest.substring(end + 2);
    }
  }
  return out;
}

List<Widget> _parseDocBlocks(String raw, ColorScheme cs) {
  final lines = raw.split('\n');
  final widgets = <Widget>[];
  var i = 0;
  var firstHeading = true;

  while (i < lines.length) {
    final line = lines[i];

    if (line.startsWith('## ')) {
      widgets.add(_headingH2(line.substring(3), cs, first: firstHeading));
      firstHeading = false;
      i++;
      continue;
    }
    if (line.startsWith('### ')) {
      widgets.add(_headingH3(line.substring(4), cs));
      i++;
      continue;
    }

    if (_isTableRow(line)) {
      final tableRows = <List<String>>[];
      while (i < lines.length && _isTableRow(lines[i])) {
        final cells = _splitTableRow(lines[i]);
        if (_isTableSeparatorRow(cells)) {
          i++;
          continue;
        }
        tableRows.add(cells);
        i++;
      }
      if (tableRows.isNotEmpty) {
        widgets.add(_DocTable(rows: tableRows, colorScheme: cs));
        widgets.add(const SizedBox(height: 16));
      }
      continue;
    }

    if (line.trim().isEmpty) {
      widgets.add(const SizedBox(height: 10));
      i++;
      continue;
    }

    if (_isBulletLine(line)) {
      final items = <String>[];
      while (i < lines.length && _isBulletLine(lines[i])) {
        items.add(_stripListPrefix(lines[i]));
        i++;
      }
      widgets.add(_DocBulletList(items: items, colorScheme: cs));
      widgets.add(const SizedBox(height: 14));
      continue;
    }

    final para = StringBuffer();
    while (i < lines.length) {
      final l = lines[i];
      if (l.trim().isEmpty ||
          l.startsWith('## ') ||
          l.startsWith('### ') ||
          _isTableRow(l) ||
          _isBulletLine(l)) {
        break;
      }
      if (para.isNotEmpty) para.writeln();
      para.write(l);
      i++;
    }
    if (para.isNotEmpty) {
      widgets.add(_DocParagraph(text: para.toString(), colorScheme: cs));
      widgets.add(const SizedBox(height: 14));
    }
  }

  return widgets;
}

Widget _headingH2(String text, ColorScheme cs, {required bool first}) {
  return Padding(
    padding: EdgeInsets.only(top: first ? 0 : 28, bottom: 12),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 24,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: cs.primary,
      ),
    ),
  );
}

Widget _headingH3(String text, ColorScheme cs) {
  return Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 18,
        height: 1.25,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
    ),
  );
}

class _DocParagraph extends StatelessWidget {
  final String text;
  final ColorScheme colorScheme;

  const _DocParagraph({required this.text, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: 15,
      height: 1.55,
      color: colorScheme.onSurface,
    );
    final bold = base.copyWith(fontWeight: FontWeight.w700);
    final mono = base.copyWith(
      fontFamily: 'monospace',
      fontSize: 14,
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
    );
    final spans = <InlineSpan>[];
    final split = text.split('\n');
    for (var i = 0; i < split.length; i++) {
      spans.add(TextSpan(children: _inlineSpans(split[i], base, bold, mono)));
      if (i < split.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return Text.rich(TextSpan(children: spans));
  }
}

class _DocBulletList extends StatelessWidget {
  final List<String> items;
  final ColorScheme colorScheme;

  const _DocBulletList({required this.items, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: 15,
      height: 1.5,
      color: colorScheme.onSurface,
    );
    final bold = base.copyWith(fontWeight: FontWeight.w700);
    final mono = base.copyWith(
      fontFamily: 'monospace',
      fontSize: 14,
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Icon(
                    Icons.circle,
                    size: 6,
                    color: colorScheme.primary.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: _inlineSpans(item, base, bold, mono)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DocTable extends StatelessWidget {
  final List<List<String>> rows;
  final ColorScheme colorScheme;

  const _DocTable({required this.rows, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final header = rows.first;
    final body = rows.length > 1 ? rows.sublist(1) : <List<String>>[];
    final colCount = header.length;
    if (colCount == 0) return const SizedBox.shrink();

    TextStyle cellStyle({required bool headerRow}) => TextStyle(
          fontSize: headerRow ? 14 : 14,
          height: 1.4,
          fontWeight: headerRow ? FontWeight.w700 : FontWeight.w500,
          color: headerRow
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurface,
        );

    TableRow buildRow(List<String> cells, bool isHeader) {
      final padded = List<String>.from(cells);
      while (padded.length < colCount) {
        padded.add('');
      }
      if (padded.length > colCount) padded.removeRange(colCount, padded.length);
      return TableRow(
        decoration: isHeader
            ? BoxDecoration(color: colorScheme.primaryContainer)
            : null,
        children: [
          for (var c = 0; c < colCount; c++)
            _TableCell(
              text: padded[c],
              style: cellStyle(headerRow: isHeader),
              colorScheme: colorScheme,
            ),
        ],
      );
    }

    final borderColor = colorScheme.outlineVariant.withValues(alpha: 0.9);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: w > 0 ? w : 320),
              child: Table(
                border: TableBorder(
                  horizontalInside: BorderSide(color: borderColor.withValues(alpha: 0.6)),
                  verticalInside: BorderSide(color: borderColor.withValues(alpha: 0.4)),
                  bottom: BorderSide(color: borderColor),
                ),
                columnWidths: {
                  for (var k = 0; k < colCount; k++) k: const FlexColumnWidth(1),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  buildRow(header, true),
                  for (final row in body) buildRow(row, false),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TableCell extends StatelessWidget {
  final String text;
  final TextStyle style;
  final ColorScheme colorScheme;

  const _TableCell({
    required this.text,
    required this.style,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final base = style;
    final bold = base.copyWith(fontWeight: FontWeight.w700);
    final mono = base.copyWith(
      fontFamily: 'monospace',
      fontSize: (style.fontSize ?? 14) - 0.5,
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text.rich(
        TextSpan(children: _inlineSpans(text, base, bold, mono)),
      ),
    );
  }
}

const String _docRu = '''
## Rlink — что это

**Rlink** — децентрализованный мессенджер: личные чаты и группы с **сквозным шифрованием (E2E)**. Сообщения между устройствами ходят по **BLE (рядом)** и/или через **интернет‑ретранслятор (relay)**. Ретранслятор видит только зашифрованные пакеты и публичные ключи — **не читает** текст переписок.

| Поле | Значение |
| :--- | :--- |
| Версия приложения | **{VERSION}** |


## Учётная запись и профиль

При первом запуске создаётся пара ключей. Профиль (ник, аватар, опционально username) виден контактам.

| Ключ | Назначение |
| :--- | :--- |
| **Ed25519** | Идентификатор в сети, подписи |
| **X25519** | Установление секрета для шифрования DM |

Публичный ключ можно передать вручную или найти пользователя через **поиск** на relay (ник, короткий id).


## Связь: рядом и интернет

| Режим | Описание |
| :--- | :--- |
| **BLE** | Обмен с устройствами в радиусе Bluetooth |
| **Relay** | Сообщения к удалённым собеседникам через ретранслятор |
| **Связка устройств** | Синхронизация части личных чатов между двумя устройствами (см. настройки сети) |


## Чаты и контент

Обычные **личные чаты**, **группы**, **каналы**, голос/видео/файлы (где поддерживается платформой), стикеры, ответы и реакции. История хранится **локально** на устройстве.


## Боты в Rlink

| Бот | Роль |
| :--- | :--- |
| **GigaChat** | Встроенный ИИ (ключ API в профиле); ответы на стороне Сбера |
| **Lib** | Регистратор сторонних ботов (`/newbot`, claim, токен API) |
| **Сторонние боты** | Своя пара ключей, свой процесс на relay; поиск по **@нику** |

### Команды Lib

| Команда | Назначение |
| :--- | :--- |
| `/start`, `/help` | Справка по регистрации |
| `/newbot` | Новый бот (ник + ключ Ed25519 64 hex) |
| `/commands` | Список команд |
| `/cancel` | Сброс ожидания ключа |
| `/guide` | Короткий чеклист |

Регистрация создаёт заявку на **relay**; приватные ключи бота остаются только у разработчика (например в **Python SDK**).


## Как создать своего бота (кратко)

1. Установите пакет из репозитория: каталог **tools/rlink_bot** (`pip install -e .`).  
2. `python -m rlink_bot keys init` — сгенерировать ключи; `keys show-pub` — публичный Ed25519 (64 hex).  
3. В приложении: **Боты → Lib** — `/newbot ваш_ник` и ключ (или одной строкой `/newbot ник <hex>`).  
4. На сервере с ключами: `python -m rlink_bot claim <claimId или claimCode> --relay <wss://…>` — **claimCode** (короткий код вида `ABCD-EFGH-JKLM`) дублирует claimId в ответе Lib; один раз получите **API token** для HTTP Bot API.  
5. `python -m rlink_bot run` — процесс в сети; для ответа пользователю нужен его **X25519** из presence (оба должны быть онлайн на relay).

Подробности — в **README** в `tools/rlink_bot/README.md` в исходниках проекта.


## Приватность

Содержимое личных сообщений в сети **E2E**; relay и третьи стороны без ваших ключей его не прочитают. Каталог публичных каналов и реестр ботов на relay содержит только **публичные метаданные** (имена, ключи для установления шифрования).

''';

const String _docEn = '''
## What is Rlink

**Rlink** is a decentralized messenger with **end‑to‑end encrypted (E2E)** chats and groups. Traffic uses **Bluetooth LE (nearby)** and/or an **internet relay**. The relay forwards **opaque encrypted blobs** and public keys — it **does not** read message plaintext.

| Field | Value |
| :--- | :--- |
| App version | **{VERSION}** |


## Account and profile

On first launch the app creates a keypair. Your profile (nickname, avatar, optional username) is visible to contacts.

| Key | Role |
| :--- | :--- |
| **Ed25519** | Network identity and signatures |
| **X25519** | Establishing secrets for DM encryption |

You can share your public key or **search** the relay by nickname or short id.


## Connectivity

| Mode | Description |
| :--- | :--- |
| **BLE** | Talk to devices in Bluetooth range |
| **Relay** | Reach remote peers through the relay server |
| **Linked devices** | Sync some DMs between two devices (see Network settings) |


## Chats

**Direct messages**, **groups**, **channels**, voice/video/files (where the OS allows), stickers, replies, and reactions. History is stored **locally** on the device.


## Bots

| Bot | Role |
| :--- | :--- |
| **GigaChat** | Built‑in AI (API key in profile); replies from Sber’s service |
| **Lib** | Third‑party bot registrar (`/newbot`, claim, API token) |
| **Custom bots** | Own keypair and process on relay; discovery by **@handle** |

### Lib commands

| Command | Purpose |
| :--- | :--- |
| `/start`, `/help` | Registration help |
| `/newbot` | New bot (handle + Ed25519 public key, 64 hex) |
| `/commands` | Command list |
| `/cancel` | Cancel waiting for the key |
| `/guide` | Short checklist |

Registration creates a claim on the **relay**; the bot’s **private keys** stay on the developer’s machine (e.g. **Python SDK**).


## Creating a bot (short)

1. From the repo: **tools/rlink_bot** (`pip install -e .`).  
2. `python -m rlink_bot keys init` then `keys show-pub` for the Ed25519 public key (64 hex).  
3. In the app: **Bots → Lib** — `/newbot your_handle` and send the key (or `/newbot handle <hex>` in one line).  
4. On the bot host: `python -m rlink_bot claim <claimId or claimCode> --relay <wss://…>` — **claimCode** (short `ABCD-EFGH-JKLM` style) is shown alongside claimId in Lib; save the one‑time **API token** for HTTP Bot API.  
5. `python -m rlink_bot run` — stay online; replying needs the user’s **X25519** from **presence** (both sides online on the same relay).

More detail: **tools/rlink_bot/README.md** in the project tree.


## Privacy

DM content is **E2E**; without your keys, the relay cannot read it. The public channel directory and bot registry only store **public metadata** (names, keys needed to set up encryption).

''';
