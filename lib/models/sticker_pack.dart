import 'dart:convert';

/// Локальный набор стикеров (пути относительно каталога документов приложения).
class StickerPack {
  final String id;
  final String title;
  final int createdAtMs;
  final List<String> stickerRelPaths;
  final String? sourcePeerId;
  final String? sourcePeerLabel;

  const StickerPack({
    required this.id,
    required this.title,
    required this.createdAtMs,
    required this.stickerRelPaths,
    this.sourcePeerId,
    this.sourcePeerLabel,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        't': createdAtMs,
        'paths': stickerRelPaths,
        if (sourcePeerId != null) 'srcPeer': sourcePeerId,
        if (sourcePeerLabel != null) 'srcLabel': sourcePeerLabel,
      };

  factory StickerPack.fromJson(Map<String, dynamic> m) {
    final paths = (m['paths'] as List?)?.cast<String>() ?? const <String>[];
    return StickerPack(
      id: m['id'] as String,
      title: (m['title'] as String?)?.trim().isNotEmpty == true
          ? (m['title'] as String).trim()
          : 'Набор',
      createdAtMs: (m['t'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      stickerRelPaths: List<String>.from(paths),
      sourcePeerId: m['srcPeer'] as String?,
      sourcePeerLabel: m['srcLabel'] as String?,
    );
  }

  static List<StickerPack> decodeList(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! List) return [];
      return decoded
          .map((e) => StickerPack.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<StickerPack> packs) =>
      jsonEncode(packs.map((p) => p.toJson()).toList());
}
