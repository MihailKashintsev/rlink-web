import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../ui/screens/channels_screen.dart';
import '../utils/rlink_deep_link.dart';
import 'channel_service.dart';

/// Вход по ссылке `rlink://channel/...` (macOS / iOS / Android).
class RlinkDeepLinkService {
  RlinkDeepLinkService._();
  static final instance = RlinkDeepLinkService._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _initialLinkConsumed = false;

  /// Вызывать после инициализации сервисов; [key] — [MaterialApp.navigatorKey].
  Future<void> start(GlobalKey<NavigatorState> key) async {
    _navigatorKey = key;
    if (_sub == null) {
      _sub = _appLinks.uriLinkStream.listen(_handle, onError: (e) {
        debugPrint('[DeepLink] stream: $e');
      });
    }
    if (!_initialLinkConsumed) {
      _initialLinkConsumed = true;
      try {
        final initial = await _appLinks.getInitialLink();
        if (initial != null) {
          _handle(initial);
        }
      } catch (e) {
        debugPrint('[DeepLink] getInitialLink: $e');
      }
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _initialLinkConsumed = false;
  }

  void _handle(Uri uri) {
    final channelId = RlinkDeepLink.parseChannelId(uri);
    if (channelId != null && channelId.isNotEmpty) {
      unawaited(openChannelInApp(channelId));
    }
  }

  /// Открыть ленту канала, если он уже есть в локальной базе.
  Future<void> openChannelInApp(String channelId) async {
    final nav = _navigatorKey?.currentState;
    final ctx = _navigatorKey?.currentContext;
    if (nav == null || ctx == null) return;

    final row = await ChannelService.instance.getChannel(channelId);
    if (row == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text(
              'Канал не найден на устройстве. Нужно приглашение или синхронизация с подписчиками.',
            ),
          ),
        );
      }
      return;
    }

    if (!ctx.mounted) return;
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelViewScreen(channel: row),
      ),
    );
  }
}
