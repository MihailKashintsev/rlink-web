import 'ai_bot_constants.dart';
import 'relay_service.dart';

/// Lib / GigaChat или сторонний бот из каталога relay (по bot_dir_snapshot).
bool isDmBotPeerId(String peerId) {
  if (isAiBotPeerId(peerId)) return true;
  return RelayService.instance.isRelayCatalogBot(peerId);
}
