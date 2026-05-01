import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/emoji_pack_service.dart';

class StatusEmojiView extends StatelessWidget {
  final String statusEmoji;
  final double fontSize;
  final Color? color;
  final String emptyPlaceholder;
  final TextStyle? style;

  const StatusEmojiView({
    super.key,
    required this.statusEmoji,
    this.fontSize = 20,
    this.color,
    this.emptyPlaceholder = '—',
    this.style,
  });

  static final RegExp _shortcodeRe = RegExp(r'^:([a-zA-Z0-9_]{1,48}):$');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: EmojiPackService.instance.version,
      builder: (_, __, ___) {
        final v = statusEmoji.trim();
        final base = style ?? TextStyle(fontSize: fontSize, color: color);
        if (v.isEmpty) {
          return Text(emptyPlaceholder, style: base);
        }
        final m = _shortcodeRe.firstMatch(v);
        if (m == null) {
          return Text(v, style: base);
        }
        final sc = m.group(1)!;
        final abs = EmojiPackService.instance.absolutePathForShortcode(sc);
        if (abs == null || !File(abs).existsSync()) {
          return Text(v, style: base);
        }
        return Image.file(
          File(abs),
          width: fontSize + 2,
          height: fontSize + 2,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Text(v, style: base),
        );
      },
    );
  }
}

class CustomEmojiInlineText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow overflow;

  const CustomEmojiInlineText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  static final RegExp _shortcodeRe = RegExp(r':([a-zA-Z0-9_]{1,48}):');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: EmojiPackService.instance.version,
      builder: (_, __, ___) {
        final spans = <InlineSpan>[];
        var pos = 0;
        for (final m in _shortcodeRe.allMatches(text)) {
          if (m.start > pos) {
            spans.add(TextSpan(text: text.substring(pos, m.start), style: style));
          }
          final sc = m.group(1)!;
          final abs = EmojiPackService.instance.absolutePathForShortcode(sc);
          if (abs != null && File(abs).existsSync()) {
            spans.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Image.file(
                File(abs),
                width: (style.fontSize ?? 15) + 2,
                height: (style.fontSize ?? 15) + 2,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Text(':$sc:', style: style),
              ),
            ));
          } else {
            spans.add(TextSpan(text: m.group(0), style: style));
          }
          pos = m.end;
        }
        if (pos < text.length) {
          spans.add(TextSpan(text: text.substring(pos), style: style));
        }
        return RichText(
          maxLines: maxLines,
          overflow: overflow,
          text: TextSpan(style: style, children: spans),
        );
      },
    );
  }
}
