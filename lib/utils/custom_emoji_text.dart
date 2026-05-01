import '../services/emoji_pack_service.dart';

final RegExp _kCustomEmojiShortcode = RegExp(r':([a-zA-Z0-9_]{1,48}):');

/// В plain-text местах (уведомления, буфер, превью) прячет `:shortcode:`
/// и заменяет на обычный emoji-глиф.
String humanizeCustomEmojiCodes(
  String input, {
  String fallbackEmoji = '😀',
}) {
  if (input.isEmpty || !input.contains(':')) return input;
  return input.replaceAllMapped(_kCustomEmojiShortcode, (m) {
    final sc = m.group(1)!;
    final exists = EmojiPackService.instance.lookupByShortcode(sc) != null;
    return exists ? fallbackEmoji : m.group(0)!;
  });
}

