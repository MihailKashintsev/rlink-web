import '../models/contact.dart';
import '../models/user_profile.dart';

/// Упоминание в тексте канала: `&` + полный Ed25519 public key (64 hex).
/// В UI показывается как @ник/юзернейм; в сыром тексте и при пересылке остаётся `&hex`.
final RegExp kChannelMentionToken =
    RegExp(r'&([0-9a-fA-F]{64})', caseSensitive: false);

/// Подпись для @-отображения: приоритет уникального юзернейма, иначе ник.
String resolveChannelMentionDisplay(
  String publicKeyHex,
  List<Contact> contacts,
  UserProfile? self,
) {
  final n = publicKeyHex.toLowerCase();
  for (final c in contacts) {
    if (c.publicKeyHex.toLowerCase() == n) {
      final u = c.username.trim();
      if (u.isNotEmpty) return u;
      final nick = c.nickname.trim();
      if (nick.isNotEmpty) return nick;
      break;
    }
  }
  if (self != null && self.publicKeyHex.toLowerCase() == n) {
    final u = self.username.trim();
    if (u.isNotEmpty) return u;
    final nick = self.nickname.trim();
    if (nick.isNotEmpty) return nick;
  }
  return publicKeyHex.length >= 8 ? '${publicKeyHex.substring(0, 8)}…' : publicKeyHex;
}
