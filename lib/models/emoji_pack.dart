import 'dart:convert';

/// Один кастомный эмодзи в наборе ([relPath] относительно каталога документов).
class CustomEmoji {
  final String shortcode;
  final String relPath;

  const CustomEmoji({
    required this.shortcode,
    required this.relPath,
  });

  Map<String, dynamic> toJson() => {
        'sc': shortcode,
        'p': relPath,
      };

  factory CustomEmoji.fromJson(Map<String, dynamic> m) {
    return CustomEmoji(
      shortcode: (m['sc'] as String? ?? m['shortcode'] as String? ?? '').trim(),
      relPath: (m['p'] as String? ?? m['relPath'] as String? ?? '').trim(),
    );
  }
}

/// Локальный набор кастомных эмодзи.
class EmojiPack {
  final String id;
  final String name;
  final List<CustomEmoji> emojis;
  final String? sourcePeerId;

  const EmojiPack({
    required this.id,
    required this.name,
    required this.emojis,
    this.sourcePeerId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emojis': emojis.map((e) => e.toJson()).toList(),
        if (sourcePeerId != null) 'srcPeer': sourcePeerId,
      };

  factory EmojiPack.fromJson(Map<String, dynamic> m) {
    final raw = (m['emojis'] as List?) ?? const [];
    final list = <CustomEmoji>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final ce = CustomEmoji.fromJson(Map<String, dynamic>.from(e));
      if (ce.shortcode.isNotEmpty && ce.relPath.isNotEmpty) {
        list.add(ce);
      }
    }
    return EmojiPack(
      id: m['id'] as String,
      name: (m['name'] as String?)?.trim().isNotEmpty == true
          ? (m['name'] as String).trim()
          : 'Набор',
      emojis: list,
      sourcePeerId: m['srcPeer'] as String? ?? m['sourcePeerId'] as String?,
    );
  }

  static List<EmojiPack> decodeList(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! List) return [];
      return decoded
          .map((e) => EmojiPack.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<EmojiPack> packs) =>
      jsonEncode(packs.map((p) => p.toJson()).toList());
}
