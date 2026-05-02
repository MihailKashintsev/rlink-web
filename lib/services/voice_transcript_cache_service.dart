import 'package:shared_preferences/shared_preferences.dart';

/// Локальное хранение текста расшифровки голосовых по id сообщения.
class VoiceTranscriptCacheService {
  VoiceTranscriptCacheService._();
  static final VoiceTranscriptCacheService instance =
      VoiceTranscriptCacheService._();

  static const _prefix = 'rlink_voice_transcript_v1_';

  String _key(String messageId) => '$_prefix$messageId';

  Future<String?> get(String messageId) async {
    if (messageId.isEmpty) return null;
    final p = await SharedPreferences.getInstance();
    return p.getString(_key(messageId));
  }

  Future<void> set(String messageId, String text) async {
    if (messageId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final t = text.trim();
    if (t.isEmpty) {
      await p.remove(_key(messageId));
      return;
    }
    await p.setString(_key(messageId), t);
  }
}
