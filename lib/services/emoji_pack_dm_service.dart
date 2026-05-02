import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../services/image_service.dart';
import '../services/relay_service.dart';
import 'emoji_pack_service.dart';

/// Служебный авто-обмен кастомными эмодзи (без карточки в чате).
class EmojiPackDmService {
  EmojiPackDmService._();

  static final _uuid = const Uuid();
  static const _blobFileName = 'rlink_emoji_pack_auto.json';
  static final RegExp _shortcodeRe = RegExp(r':([a-zA-Z0-9_]{1,48}):');

  static Future<Map<String, dynamic>?> _buildPayloadFromShortcodes({
    required Iterable<String> shortcodes,
    required String kind,
  }) async {
    await EmojiPackService.instance.ensureInitialized();
    EmojiPackService.instance.refreshIndexSync();
    final seen = <String>{};
    final emojis = <Map<String, dynamic>>[];
    var totalBytes = 0;
    for (final raw in shortcodes) {
      final sc = raw.trim();
      if (sc.isEmpty) continue;
      final key = sc.toLowerCase();
      if (!seen.add(key)) continue;
      final abs = EmojiPackService.instance.absolutePathForShortcode(sc);
      if (abs == null) continue;
      final rawBytes =
          await EmojiPackService.instance.readEmojiBytesByShortcode(sc);
      if (rawBytes == null || rawBytes.isEmpty) continue;
      final encoded = base64Encode(rawBytes);
      totalBytes += encoded.length;
      if (totalBytes > 300 * 1024) break;
      emojis.add({
        'shortcode': sc,
        'data': encoded,
      });
    }
    if (emojis.isEmpty) return null;
    return {
      'type': 'emoji_auto',
      'kind': kind,
      'emojis': emojis,
    };
  }

  static Future<Map<String, dynamic>?> buildPayloadForText(
    String text, {
    String kind = 'text',
  }) async {
    final codes = <String>[];
    for (final m in _shortcodeRe.allMatches(text)) {
      final sc = m.group(1);
      if (sc != null) codes.add(sc);
    }
    if (codes.isEmpty) return null;
    return _buildPayloadFromShortcodes(shortcodes: codes, kind: kind);
  }

  /// JSON-строка для поля `eap` в gossip (канал / группа и т.д.).
  static Future<String?> buildEmojiAutoPayloadJson(
    String text, {
    String kind = 'text',
  }) async {
    final m = await buildPayloadForText(text, kind: kind);
    if (m == null) return null;
    return jsonEncode(m);
  }

  static Future<Map<String, dynamic>?> buildPayloadForStatus(
      String statusEmoji) async {
    final m = RegExp(r'^:([a-zA-Z0-9_]{1,48}):$').firstMatch(statusEmoji.trim());
    if (m == null) return null;
    final sc = m.group(1);
    if (sc == null || sc.isEmpty) return null;
    return _buildPayloadFromShortcodes(shortcodes: [sc], kind: 'status');
  }

  static Future<void> sendAutoPayloadToPeer({
    required String targetPeerId,
    required String fromId,
    required Map<String, dynamic> payload,
  }) async {
    if (!RelayService.instance.isConnected) return;
    final jsonBytes = utf8.encode(jsonEncode(payload));
    final compressed = ImageService.instance.compress(Uint8List.fromList(jsonBytes));
    final msgId = 'emojiauto_${_uuid.v4()}';
    await RelayService.instance.sendBlob(
      recipientKey: targetPeerId,
      fromId: fromId,
      msgId: msgId,
      compressedData: compressed,
      isFile: true,
      fileName: _blobFileName,
    );
  }

  /// Поле gossip `eap` (JSON) в пакетах `channel_post` / `channel_comment`.
  static Future<int> installFromGossipEapField(
    Map<String, dynamic> payload, {
    required String sourcePeerId,
  }) async {
    final eapRaw = payload['eap'] as String?;
    if (eapRaw == null || eapRaw.trim().isEmpty) return 0;
    try {
      final map = jsonDecode(eapRaw) as Map<String, dynamic>;
      return await EmojiPackService.instance.installFromAutoPayload(
        map,
        sourcePeerId: sourcePeerId,
      );
    } catch (_) {
      return 0;
    }
  }

  static Future<int> receiveFromRelay({
    required String fromId,
    required Uint8List compressedData,
  }) async {
    final decoded = ImageService.instance.decompress(compressedData);
    final m = jsonDecode(utf8.decode(decoded));
    if (m is! Map) return 0;
    final payload = Map<String, dynamic>.from(m);
    if (payload['type'] != 'emoji_auto') return 0;
    return EmojiPackService.instance.installFromAutoPayload(
      payload,
      sourcePeerId: fromId,
    );
  }
}

