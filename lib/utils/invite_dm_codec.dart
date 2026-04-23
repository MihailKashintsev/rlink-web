import 'dart:convert';

/// Машиночитаемые приглашения в ЛС (шифруются как обычный текст).
const _kCh = 'RLINK:CH:v1:';
const _kGr = 'RLINK:GR:v1:';

String _b64Enc(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _b64Dec(String s) {
  var t = s;
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64Url.decode(t);
}

class InviteDmCodec {
  InviteDmCodec._();

  static String encodeChannelInvite(Map<String, dynamic> data) =>
      _kCh + _b64Enc(utf8.encode(jsonEncode(data)));

  static Map<String, dynamic>? tryDecodeChannelInvite(String text) {
    if (!text.startsWith(_kCh)) return null;
    try {
      final m = jsonDecode(utf8.decode(_b64Dec(text.substring(_kCh.length))))
          as Map<String, dynamic>;
      if (m['channelId'] is! String || m['channelName'] is! String) {
        return null;
      }
      return m;
    } catch (_) {
      return null;
    }
  }

  static String channelInvitePreview(Map<String, dynamic> m) {
    final name = m['channelName'] as String? ?? 'канал';
    return '📢 Приглашение в канал «$name»';
  }

  static String encodeGroupInvite(Map<String, dynamic> data) =>
      _kGr + _b64Enc(utf8.encode(jsonEncode(data)));

  static Map<String, dynamic>? tryDecodeGroupInvite(String text) {
    if (!text.startsWith(_kGr)) return null;
    try {
      final m = jsonDecode(utf8.decode(_b64Dec(text.substring(_kGr.length))))
          as Map<String, dynamic>;
      if (m['groupId'] is! String || m['groupName'] is! String) {
        return null;
      }
      return m;
    } catch (_) {
      return null;
    }
  }

  static String groupInvitePreview(Map<String, dynamic> m) {
    final name = m['groupName'] as String? ?? 'группу';
    return '👥 Приглашение в группу «$name»';
  }

  static final _channelPreviewName =
      RegExp(r'^📢 Приглашение в канал «([^»]+)»');
  static final _groupPreviewName =
      RegExp(r'^👥 Приглашение в группу «([^»]+)»');

  /// Имя из превью-текста приглашения (для старых сообщений без [invite_payload]).
  static String? channelNameFromInvitePreview(String text) {
    final m = _channelPreviewName.firstMatch(text.trim());
    return m?.group(1);
  }

  static String? groupNameFromInvitePreview(String text) {
    final m = _groupPreviewName.firstMatch(text.trim());
    return m?.group(1);
  }
}
