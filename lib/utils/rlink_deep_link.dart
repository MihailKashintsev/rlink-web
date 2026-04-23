import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Ссылки вида [rlink://channel/<id>] — открытие канала в приложении.
///
/// Публичные приглашения: [channelInviteWebUri] — страница Tilda с `?channel=<id>` (см. [channelWebInvitePage]).
class RlinkDeepLink {
  RlinkDeepLink._();

  /// База веб-страницы Rlink (установка, лендинг, APK).
  static const String installWebBase = 'https://rendergames.online/rlink';

  /// Лендинг «открыть канал» (Tilda). ID передаётся в query: `?channel=` — так проще одна страница без вложенных URL.
  static const String channelWebInvitePage =
      'https://rendergames.online/rlinkchanales';

  static Uri channelUri(String channelId) =>
      Uri(scheme: 'rlink', host: 'channel', pathSegments: [channelId]);

  /// Ссылка для шаринга и браузера: откроется сайт; при настроенных App Links — приложение.
  static Uri channelInviteWebUri(String channelId) => Uri.parse(
        '$channelWebInvitePage?channel=${Uri.encodeQueryComponent(channelId)}',
      );

  static String channelInviteShareText({
    required String channelTitle,
    required String channelId,
  }) {
    final url = channelInviteWebUri(channelId).toString();
    return 'Канал «$channelTitle» в Rlink\n$url';
  }

  /// [context] — виджет, от которого якорится системный лист (обязательно для iPad / macOS).
  static Rect sharePositionOriginFromContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    final center = Offset(size.width / 2, size.height / 2);
    return Rect.fromCenter(center: center, width: 48, height: 48);
  }

  static Future<void> shareChannelInvite({
    required BuildContext context,
    required String channelTitle,
    required String channelId,
  }) async {
    final text = channelInviteShareText(
      channelTitle: channelTitle,
      channelId: channelId,
    );
    try {
      await Share.share(
        text,
        subject: 'Rlink: $channelTitle',
        sharePositionOrigin: sharePositionOriginFromContext(context),
      );
    } catch (e, st) {
      debugPrint('[RlinkDeepLink] Share failed: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть «Поделиться». '
              'Нажмите «Копировать ссылку» и вставьте в нужное приложение.',
            ),
          ),
        );
      }
    }
  }

  /// Разбор `rlink://channel/<id>`, `https://…/channel/<id>`,
  /// `https://…/rlink/channel/<id>`, `https://…/rlinkchanales?channel=<id>` и `?c=`.
  static String? parseChannelId(Uri uri) {
    if (uri.scheme == 'rlink' && uri.host == 'channel') {
      if (uri.pathSegments.isNotEmpty) return uri.pathSegments.first;
      final p = uri.path;
      if (p.length > 1 && p.startsWith('/')) {
        final seg = p.substring(1).split('/').firstWhere((s) => s.isNotEmpty,
            orElse: () => '');
        if (seg.isNotEmpty) return seg;
      }
    }
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      final q = uri.queryParameters;
      final fromQuery = q['channel'] ?? q['c'];
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;

      final segs = uri.pathSegments;
      final i = segs.indexOf('channel');
      if (i >= 0 && i + 1 < segs.length) return segs[i + 1];
    }
    return null;
  }
}
