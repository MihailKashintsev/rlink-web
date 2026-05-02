import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:flutter_highlight/themes/atom-one-dark.dart' as hl_atom_dark;
import 'package:flutter_highlight/themes/github.dart' as hl_github;
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_l10n.dart';
import '../../services/app_settings.dart';
import '../../services/emoji_pack_service.dart';
import '../../services/runtime_platform.dart';
import '../../utils/card_luhn.dart';
import '../../utils/channel_mentions.dart';
import '../../utils/code_language_guess.dart';

/// Телефон E.164-подобный: + и 10–15 цифр.
bool _phoneDigitOk(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  return d.length >= 10 && d.length <= 15;
}

String _telUriString(String raw) {
  final b = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '+') {
      if (b.isEmpty) b.write('+');
    } else if (ch.compareTo('0') >= 0 && ch.compareTo('9') <= 0) {
      b.write(ch);
    }
  }
  var s = b.toString();
  if (!s.startsWith('+')) s = '+$s';
  return s;
}

class _Hit {
  final int start;
  final int end;
  final String kind;
  final String raw;
  const _Hit(this.start, this.end, this.kind, this.raw);
}

class _TextSegment {
  final String text;
  const _TextSegment(this.text);
}

class _CodeFenceSegment {
  final String code;
  final String? languageHint;
  const _CodeFenceSegment({
    required this.code,
    this.languageHint,
  });
}

sealed class _RichSegment {
  const _RichSegment();
}

class _RichTextSegment extends _RichSegment {
  final _TextSegment value;
  const _RichTextSegment(this.value);
}

class _RichCodeSegment extends _RichSegment {
  final _CodeFenceSegment value;
  const _RichCodeSegment(this.value);
}

List<_RichSegment> _splitCodeFenceSegments(String source) {
  final segments = <_RichSegment>[];
  final fenceRegex = RegExp(r'```([^\n`]*)\r?\n?([\s\S]*?)```');
  var pos = 0;
  for (final m in fenceRegex.allMatches(source)) {
    if (m.start > pos) {
      segments
          .add(_RichTextSegment(_TextSegment(source.substring(pos, m.start))));
    }
    final rawLang = (m.group(1) ?? '').trim();
    var code = m.group(2) ?? '';
    if (code.endsWith('\r\n')) {
      code = code.substring(0, code.length - 2);
    } else if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    segments.add(
      _RichCodeSegment(
        _CodeFenceSegment(
          code: code,
          languageHint: rawLang.isEmpty ? null : rawLang,
        ),
      ),
    );
    pos = m.end;
  }
  if (pos < source.length) {
    segments.add(_RichTextSegment(_TextSegment(source.substring(pos))));
  }
  return segments;
}

String? _normalizeHighlightLanguage(String? raw) {
  final l = raw?.trim().toLowerCase();
  if (l == null || l.isEmpty) return null;
  switch (l) {
    case 'код':
    case 'code':
      return null;
    case 'dart/flutter':
      return 'dart';
    case 'c/c++':
    case 'c++':
    case 'cpp':
      return 'cpp';
    case 'c#':
    case 'cs':
      return 'cs';
    case 'js':
    case 'javascript':
      return 'javascript';
    case 'ts':
    case 'typescript':
      return 'typescript';
    case 'py':
    case 'python':
      return 'python';
    case 'kt':
    case 'kotlin':
      return 'kotlin';
    case 'golang':
    case 'go':
      return 'go';
    case 'rs':
    case 'rust':
      return 'rust';
    case 'html':
    case 'xml':
      return 'xml';
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'shell':
      return 'bash';
    case 'ps1':
    case 'psm1':
    case 'pwsh':
    case 'posh':
    case 'powershell':
    case 'microsoft.powershell':
      return 'powershell';
    case 'cmd':
    case 'bat':
    case 'batch':
      return 'dos';
    case 'yml':
    case 'yaml':
      return 'yaml';
    case 'md':
    case 'markdown':
      return 'markdown';
    default:
      return l;
  }
}

String _displayLanguageLabel(String? fenceLanguage, String code) {
  final hinted = fenceLanguage?.trim();
  if (hinted != null && hinted.isNotEmpty) return hinted;
  return guessProgrammingLanguage(code);
}

String? _highlightLanguageForCode(String? fenceLanguage, String code) {
  final fromFence = _normalizeHighlightLanguage(fenceLanguage);
  if (fromFence != null) return fromFence;
  return _normalizeHighlightLanguage(guessProgrammingLanguage(code));
}

/// Команды вида `/start`, `/newbot` — только если не пересекаются с email/телефоном/картой
/// и не сразу после `://` (часть URL).
List<_Hit> _collectSlashCommandHits(String s, List<_Hit> blocked) {
  final out = <_Hit>[];
  for (final m in RegExp(r'(^|[^\w/])(/[a-zA-Z][a-zA-Z0-9_-]*)').allMatches(s)) {
    final cmd = m.group(2)!;
    final st = m.start + (m.group(1)?.length ?? 0);
    final en = st + cmd.length;
    if (st >= 2 && s[st - 1] == '/' && s[st - 2] == ':') {
      continue;
    }
    if (blocked.any((h) => !(en <= h.start || st >= h.end))) {
      continue;
    }
    out.add(_Hit(st, en, 'slash', cmd));
  }
  return out;
}

List<_Hit> _collectInteractiveHits(String s) {
  final cands = <_Hit>[];
  for (final m in RegExp(
          r'\b[a-zA-Z0-9][a-zA-Z0-9._%+-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}\b')
      .allMatches(s)) {
    cands.add(_Hit(m.start, m.end, 'email', m.group(0)!));
  }
  for (final m in RegExp(r'(?<!\S)\+[\d\s\-\(\).]+').allMatches(s)) {
    final raw = m.group(0)!;
    if (_phoneDigitOk(raw)) {
      cands.add(_Hit(m.start, m.end, 'phone', raw));
    }
  }
  for (final m in RegExp(r'\b(?:\d[ \-\.]?){12,18}\d\b').allMatches(s)) {
    final raw = m.group(0)!;
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length >= 13 && d.length <= 19 && passesLuhn(d)) {
      cands.add(_Hit(m.start, m.end, 'card', raw));
    }
  }
  cands.sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));
  final picked = <_Hit>[];
  for (final h in cands) {
    if (picked.any((p) => !(h.end <= p.start || h.start >= p.end))) continue;
    picked.add(h);
  }
  picked.sort((a, b) => a.start.compareTo(b.start));
  return picked;
}

List<_Hit> _collectCustomEmojiHits(String s, List<_Hit> blocked) {
  final out = <_Hit>[];
  for (final m in RegExp(r':([a-zA-Z0-9_]{1,48}):').allMatches(s)) {
    final st = m.start;
    final en = m.end;
    if (blocked.any((h) => !(en <= h.start || st >= h.end))) continue;
    final sc = m.group(1)!;
    if (EmojiPackService.instance.lookupByShortcode(sc) == null) continue;
    out.add(_Hit(st, en, 'cemoji', sc));
  }
  return out;
}

List<InlineSpan> _spansForPlain(
  String s,
  TextStyle baseStyle,
  ColorScheme cs,
  bool isOut,
  BuildContext context, {
  void Function(String command)? onSlashCommandTap,
  void Function(String shortcode)? onCustomEmojiTap,
  bool parseCustomEmoji = true,
}) {
  if (s.isEmpty) return [];
  final hits = _collectInteractiveHits(s);
  if (onSlashCommandTap != null) {
    for (final sh in _collectSlashCommandHits(s, hits)) {
      hits.add(sh);
    }
    hits.sort((a, b) => a.start.compareTo(b.start));
  }
  if (parseCustomEmoji) {
    for (final eh in _collectCustomEmojiHits(s, hits)) {
      if (hits.any((x) => !(eh.end <= x.start || eh.start >= x.end))) continue;
      hits.add(eh);
    }
    hits.sort((a, b) => a.start.compareTo(b.start));
  }
  if (hits.isEmpty) {
    return [TextSpan(text: s, style: baseStyle)];
  }
  final spans = <InlineSpan>[];
  var pos = 0;
  for (final h in hits) {
    if (h.start > pos) {
      spans.add(TextSpan(text: s.substring(pos, h.start), style: baseStyle));
    }
    if (h.kind == 'phone') {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => _showPhoneSheet(context, h.raw, isOut, cs),
          child: Text(
            h.raw,
            style: baseStyle.copyWith(
              color: isOut ? Colors.white.withValues(alpha: 0.95) : cs.primary,
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ));
    } else if (h.kind == 'email') {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => _showEmailSheet(context, h.raw, isOut, cs),
          child: Text(
            h.raw,
            style: baseStyle.copyWith(
              color: isOut ? Colors.white.withValues(alpha: 0.95) : cs.primary,
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ));
    } else if (h.kind == 'card') {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => _showCardSheet(context, h.raw),
          child: Text(
            h.raw,
            style: baseStyle.copyWith(
              color:
                  isOut ? Colors.white.withValues(alpha: 0.95) : cs.secondary,
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ));
    } else if (h.kind == 'slash' && onSlashCommandTap != null) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => onSlashCommandTap(h.raw),
          child: Text(
            h.raw,
            style: baseStyle.copyWith(
              color: isOut ? Colors.white.withValues(alpha: 0.95) : cs.primary,
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ));
    } else if (h.kind == 'cemoji') {
      final path = EmojiPackService.instance.absolutePathForShortcode(h.raw);
      if (path == null || !File(path).existsSync()) {
        spans.add(
            TextSpan(text: s.substring(h.start, h.end), style: baseStyle));
      } else {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: onCustomEmojiTap == null ? null : () => onCustomEmojiTap(h.raw),
            child: Image.file(
              File(path),
              width: 18,
              height: 18,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Text(':${h.raw}:', style: baseStyle),
            ),
          ),
        ));
      }
    }
    pos = h.end;
  }
  if (pos < s.length) {
    spans.add(TextSpan(text: s.substring(pos), style: baseStyle));
  }
  return spans;
}

void _showPhoneSheet(
    BuildContext context, String raw, bool isOut, ColorScheme cs) {
  final tel = _telUriString(raw);
  final uri = Uri(scheme: 'tel', path: tel);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.phone, color: cs.primary),
            title: Text(AppL10n.t('link_phone_call')),
            onTap: () async {
              Navigator.pop(ctx);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(AppL10n.t('link_phone_copy')),
            onTap: () {
              Clipboard.setData(ClipboardData(text: raw.trim()));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppL10n.t('link_phone_copied'))),
              );
            },
          ),
        ],
      ),
    ),
  );
}

void _showEmailSheet(
    BuildContext context, String raw, bool isOut, ColorScheme cs) {
  final addr = raw.trim();
  final uri = Uri(scheme: 'mailto', path: addr);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.mail_outline, color: cs.primary),
            title: Text(AppL10n.t('link_email_compose')),
            onTap: () async {
              Navigator.pop(ctx);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(AppL10n.t('copy')),
            onTap: () {
              Clipboard.setData(ClipboardData(text: addr));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppL10n.t('link_email_copied'))),
              );
            },
          ),
        ],
      ),
    ),
  );
}

void _showCardSheet(BuildContext context, String raw) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(AppL10n.t('link_card_copy_title')),
            subtitle: Text(AppL10n.t('link_card_copy_hint')),
            onTap: () {
              final digits = raw.replaceAll(RegExp(r'\D'), '');
              Clipboard.setData(ClipboardData(text: digits));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppL10n.t('link_card_snackbar_copied'))),
              );
            },
          ),
        ],
      ),
    ),
  );
}

void _showCodeSheet(BuildContext context, String code, bool isOut) {
  final lang = guessProgrammingLanguage(code);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              lang,
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(AppL10n.t('link_code_copy_title')),
            onTap: () {
              Clipboard.setData(ClipboardData(text: code));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppL10n.t('link_code_snackbar_copied'))),
              );
            },
          ),
        ],
      ),
    ),
  );
}

/// Renders message text with simple inline formatting and link previews.
///
/// Supported markers (Telegram-like):
/// - **bold**
/// - _italic_
/// - __underline__
/// - ~~strikethrough~~
/// - ||spoiler||
/// - `code` — тап: язык + копирование
///
/// Номер `+…` — позвонить / скопировать. Email — письмо / скопировать.
/// Номер карты (Лун) — скопировать цифры.
///
/// URLs (`http(s)://...`) are clickable and also shown as small preview cards
/// below the message.
class RichMessageText extends StatelessWidget {
  final String text;
  final Color textColor;
  final bool isOut;

  /// Упоминания `&` + 64 hex ключа: показ как @лейбл, в [text] остаётся сырое значение.
  final String Function(String publicKeyHex)? mentionLabelFor;

  /// Тап по @упоминанию (например переход в личный чат).
  final void Function(String publicKeyHex)? onMentionTap;

  /// Тап по `/команде` в чате с ботом — отправить команду в поле ввода (обработчик снаружи).
  final void Function(String command)? onSlashCommandTap;

  /// Тап по кастомному эмодзи в тексте.
  final void Function(String shortcode)? onCustomEmojiTap;

  /// Парсинг `:shortcode:` через [EmojiPackService].
  final bool parseCustomEmoji;

  const RichMessageText({
    super.key,
    required this.text,
    required this.textColor,
    required this.isOut,
    this.mentionLabelFor,
    this.onMentionTap,
    this.onSlashCommandTap,
    this.onCustomEmojiTap,
    this.parseCustomEmoji = true,
  });

  static final _urlRegex = RegExp(r'https?://\S+');
  static final _mdLinkRegex = RegExp(r'\[([^\]]+)\]\((https?://[^\s)]+)\)');

  // Combined regex — order matters: longer/more specific markers first.
  // group 1: **bold**, group 2: __underline__, group 3: ~~strike~~,
  // group 4: `mono`, group 5: _italic_, group 6: ||spoiler||,
  // group 7-8: [text](url), otherwise URL.
  static final _fmtRegex = RegExp(
    r'\*\*([\s\S]*?)\*\*|__([\s\S]*?)__|~~([\s\S]*?)~~|`([\s\S]*?)`|_([\s\S]*?)_|\|\|([\s\S]*?)\|\||\[([^\]]+)\]\((https?://[^\s)]+)\)|https?://\S+',
  );

  @override
  Widget build(BuildContext context) {
    if (!parseCustomEmoji) return _buildInner(context);
    return ValueListenableBuilder<int>(
      valueListenable: EmojiPackService.instance.version,
      builder: (_, __, ___) => _buildInner(context),
    );
  }

  Widget _buildInner(BuildContext context) {
    final segments = _splitCodeFenceSegments(text);
    final urls = <String>{};
    for (final seg in segments) {
      if (seg is! _RichTextSegment) continue;
      final raw = seg.value.text;
      for (final m in _urlRegex.allMatches(raw)) {
        urls.add(m.group(0)!);
      }
      for (final m in _mdLinkRegex.allMatches(raw)) {
        urls.add(m.group(2)!);
      }
    }
    return Column(
      crossAxisAlignment:
          isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        ..._buildSegments(context, segments),
        ...urls.map((u) => LinkPreviewCard(url: u, isOut: isOut)),
      ],
    );
  }

  List<Widget> _buildSegments(
    BuildContext context,
    List<_RichSegment> segments,
  ) {
    final widgets = <Widget>[];
    for (final seg in segments) {
      switch (seg) {
        case _RichTextSegment():
          if (seg.value.text.isEmpty) continue;
          widgets.add(_buildInlineRichText(context, seg.value.text));
        case _RichCodeSegment():
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _CodeBlockView(
                code: seg.value.code,
                languageLabel: _displayLanguageLabel(
                  seg.value.languageHint,
                  seg.value.code,
                ),
                highlightLanguage: _highlightLanguageForCode(
                  seg.value.languageHint,
                  seg.value.code,
                ),
                isOut: isOut,
              ),
            ),
          );
      }
    }
    if (widgets.isEmpty) {
      widgets.add(_buildInlineRichText(context, text));
    }
    return widgets;
  }

  Widget _buildInlineRichText(BuildContext context, String sourceText) {
    final cs = Theme.of(context).colorScheme;
    final matches = _fmtRegex.allMatches(sourceText).toList();

    TextStyle baseEmojiStyle() {
      var st = TextStyle(color: textColor, fontSize: 15);
      if (RuntimePlatform.isAndroid && AppSettings.instance.useIosStyleEmoji) {
        final fam = GoogleFonts.notoColorEmoji().fontFamily;
        if (fam != null) {
          st = st.copyWith(
            fontFamilyFallback: [...(st.fontFamilyFallback ?? []), fam],
          );
        }
      }
      return st;
    }

    final baseStyle = baseEmojiStyle();

    void addPlain(List<InlineSpan> spans, String s) {
      if (s.isEmpty) return;
      spans.addAll(_spansForPlain(
        s,
        baseStyle,
        cs,
        isOut,
        context,
        onSlashCommandTap: onSlashCommandTap,
        onCustomEmojiTap: onCustomEmojiTap,
        parseCustomEmoji: parseCustomEmoji,
      ));
    }

    void addPlainWithMentions(List<InlineSpan> spans, String s) {
      if (s.isEmpty) return;
      final resolver = mentionLabelFor;
      if (resolver == null) {
        addPlain(spans, s);
        return;
      }
      var pos = 0;
      for (final m in kChannelMentionToken.allMatches(s)) {
        if (m.start > pos) {
          spans.addAll(_spansForPlain(
            s.substring(pos, m.start),
            baseStyle,
            cs,
            isOut,
            context,
            onSlashCommandTap: onSlashCommandTap,
            onCustomEmojiTap: onCustomEmojiTap,
            parseCustomEmoji: parseCustomEmoji,
          ));
        }
        final hex = m.group(1)!;
        final label = resolver(hex);
        final mentionStyle = baseStyle.copyWith(
          color: isOut ? Colors.white.withValues(alpha: 0.95) : cs.primary,
          fontWeight: FontWeight.w600,
          decoration: onMentionTap != null ? TextDecoration.underline : null,
        );
        if (onMentionTap != null) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () => onMentionTap!(hex),
              child: Text('@$label', style: mentionStyle),
            ),
          ));
        } else {
          spans.add(TextSpan(text: '@$label', style: mentionStyle));
        }
        pos = m.end;
      }
      if (pos < s.length) {
        spans.addAll(_spansForPlain(
          s.substring(pos),
          baseStyle,
          cs,
          isOut,
          context,
          onSlashCommandTap: onSlashCommandTap,
          onCustomEmojiTap: onCustomEmojiTap,
          parseCustomEmoji: parseCustomEmoji,
        ));
      }
    }

    if (matches.isEmpty) {
      final spans = <InlineSpan>[];
      addPlainWithMentions(spans, sourceText);
      return RichText(text: TextSpan(children: spans));
    }

    final spans = <InlineSpan>[];
    var lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        addPlainWithMentions(spans, sourceText.substring(lastEnd, match.start));
      }

      final full = match.group(0)!;

      if (match.group(1) != null) {
        spans.add(TextSpan(
          text: match.group(1)!,
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(2) != null) {
        spans.add(TextSpan(
          text: match.group(2)!,
          style: baseStyle.copyWith(decoration: TextDecoration.underline),
        ));
      } else if (match.group(3) != null) {
        spans.add(TextSpan(
          text: match.group(3)!,
          style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
        ));
      } else if (match.group(4) != null) {
        final t = match.group(4)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onLongPress: () => _showCodeSheet(context, t, isOut),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: isOut
                    ? Colors.black.withValues(alpha: 0.18)
                    : cs.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                t,
                style: baseStyle.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: textColor,
                ),
              ),
            ),
          ),
        ));
      } else if (match.group(5) != null) {
        spans.add(TextSpan(
          text: match.group(5)!,
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(6) != null) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _SpoilerText(text: match.group(6)!, style: baseStyle),
        ));
      } else if (match.group(7) != null && match.group(8) != null) {
        final label = match.group(7)!;
        final url = match.group(8)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            child: Text(
              label,
              style: baseStyle.copyWith(
                color: isOut ? Colors.white.withValues(alpha: 0.9) : cs.primary,
                decoration: TextDecoration.underline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ));
      } else {
        final url = full;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            child: Text(
              url,
              style: baseStyle.copyWith(
                color: isOut ? Colors.white.withValues(alpha: 0.9) : cs.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ));
      }

      lastEnd = match.end;
    }

    if (lastEnd < sourceText.length) {
      addPlainWithMentions(spans, sourceText.substring(lastEnd));
    }

    return RichText(text: TextSpan(children: spans));
  }
}

class LinkPreviewCard extends StatelessWidget {
  final String url;
  final bool isOut;

  const LinkPreviewCard({super.key, required this.url, required this.isOut});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uri = Uri.tryParse(url);
    final domain = uri?.host ?? url;

    return GestureDetector(
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isOut
              ? Colors.black.withValues(alpha: 0.15)
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              color: isOut ? Colors.white.withValues(alpha: 0.4) : cs.primary,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.language,
                  size: 14, color: isOut ? Colors.white70 : cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  domain,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isOut ? Colors.white : cs.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              url,
              style: TextStyle(
                fontSize: 11,
                color: isOut
                    ? Colors.white60
                    : cs.onSurface.withValues(alpha: 0.5),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Подсветка как [HighlightView], но с выделением текста (копирование фрагмента).
class _SelectableHighlightView extends StatelessWidget {
  final String source;
  final String? language;
  final Map<String, TextStyle> theme;
  final TextStyle? textStyle;

  _SelectableHighlightView(
    String input, {
    this.language,
    required this.theme,
    this.textStyle,
    int tabSize = 8,
  }) : source = input.replaceAll('\t', ' ' * tabSize);

  static const _rootKey = 'root';

  static List<TextSpan> _spansForNodes(
    List<Node> nodes,
    Map<String, TextStyle> themeMap,
  ) {
    final spans = <TextSpan>[];
    var currentSpans = spans;
    final stack = <List<TextSpan>>[];

    void traverse(Node node) {
      if (node.value != null) {
        currentSpans.add(node.className == null
            ? TextSpan(text: node.value)
            : TextSpan(
                text: node.value,
                style: themeMap[node.className!],
              ));
      } else if (node.children != null) {
        final tmp = <TextSpan>[];
        currentSpans
            .add(TextSpan(children: tmp, style: themeMap[node.className!]));
        stack.add(currentSpans);
        currentSpans = tmp;

        for (final n in node.children!) {
          traverse(n);
          if (n == node.children!.last) {
            currentSpans = stack.isEmpty ? spans : stack.removeLast();
          }
        }
      }
    }

    for (final node in nodes) {
      traverse(node);
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    const defaultFontColor = Color(0xff000000);
    const defaultFontFamily = 'monospace';

    var merged = TextStyle(
      fontFamily: defaultFontFamily,
      color: theme[_rootKey]?.color ?? defaultFontColor,
    );
    if (textStyle != null) {
      merged = merged.merge(textStyle!);
    }

    List<TextSpan> children;
    try {
      final parsed = highlight.parse(source, language: language);
      final nodes = parsed.nodes;
      children = nodes != null && nodes.isNotEmpty
          ? _spansForNodes(nodes, theme)
          : [TextSpan(text: source)];
    } catch (_) {
      children = [TextSpan(text: source)];
    }

    return SelectableText.rich(
      TextSpan(style: merged, children: children),
    );
  }
}

class _CodeBlockView extends StatelessWidget {
  final String code;
  final String languageLabel;
  final String? highlightLanguage;
  final bool isOut;

  const _CodeBlockView({
    required this.code,
    required this.languageLabel,
    required this.highlightLanguage,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final baseTheme =
        isDarkTheme ? hl_atom_dark.atomOneDarkTheme : hl_github.githubTheme;
    final theme = _stripHighlightBackgrounds(baseTheme);
    final shellBg = isOut
        ? Colors.black.withValues(alpha: 0.24)
        : cs.surfaceContainerHighest.withValues(alpha: 0.85);
    final lineColor = isOut
        ? Colors.white.withValues(alpha: 0.2)
        : cs.outline.withValues(alpha: 0.3);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: shellBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: lineColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: lineColor),
              ),
            ),
            child: Row(
              children: [
                Text(
                  languageLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isOut ? Colors.white70 : cs.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: AppL10n.t('link_code_copy_title'),
                  icon: Icon(
                    Icons.copy_rounded,
                    color: isOut ? Colors.white70 : cs.onSurfaceVariant,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(AppL10n.t('link_code_snackbar_copied')),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: _SelectableHighlightView(
              code.isEmpty ? ' ' : code,
              language: highlightLanguage,
              theme: theme,
              textStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13.5,
                height: 1.35,
                color: isOut ? Colors.white : cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, TextStyle> _stripHighlightBackgrounds(
  Map<String, TextStyle> source,
) {
  final out = <String, TextStyle>{};
  source.forEach((key, style) {
    out[key] = style.copyWith(backgroundColor: Colors.transparent);
  });
  return out;
}

class _SpoilerText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _SpoilerText({required this.text, required this.style});

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: _revealed
          ? Text(widget.text, style: widget.style)
          : Text(
              '▓' * widget.text.length.clamp(1, 20),
              style: widget.style.copyWith(
                color: widget.style.color?.withValues(alpha: 0.5),
                letterSpacing: 1,
              ),
            ),
    );
  }
}
