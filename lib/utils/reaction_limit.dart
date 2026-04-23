/// Сколько разных эмодзи-реакций один пользователь может оставить на одном сообщении.
const kMaxDistinctReactionsPerUser = 4;

/// Разрешает добавить реакцию [emoji] от [reactorId] (снятие своей реакции всегда ок).
bool reactionAddAllowed(
  Map<String, List<String>> reactions,
  String emoji,
  String reactorId,
) {
  final senders = reactions[emoji];
  if (senders != null && senders.contains(reactorId)) {
    return true;
  }
  var distinct = 0;
  for (final list in reactions.values) {
    if (list.contains(reactorId)) distinct++;
  }
  return distinct < kMaxDistinctReactionsPerUser;
}

/// Обрезает карту реакций: у каждого пользователя остаётся не больше [maxPerUser] эмодзи (лексикографический порядок ключей).
Map<String, List<String>> clampReactionsMapPerUser(
  Map<String, List<String>> m, {
  int maxPerUser = kMaxDistinctReactionsPerUser,
}) {
  if (m.isEmpty) return m;
  final userToEmojis = <String, List<String>>{};
  for (final e in m.entries) {
    for (final uid in e.value) {
      userToEmojis.putIfAbsent(uid, () => []).add(e.key);
    }
  }
  final toRemove = <String, Set<String>>{};
  for (final entry in userToEmojis.entries) {
    final emojis = entry.value.toSet().toList()..sort();
    if (emojis.length <= maxPerUser) continue;
    for (final em in emojis.sublist(maxPerUser)) {
      toRemove.putIfAbsent(em, () => {}).add(entry.key);
    }
  }
  if (toRemove.isEmpty) return m;
  final out = <String, List<String>>{};
  for (final e in m.entries) {
    final rem = toRemove[e.key];
    if (rem == null || rem.isEmpty) {
      out[e.key] = List<String>.from(e.value);
    } else {
      final nl = e.value.where((id) => !rem.contains(id)).toList();
      if (nl.isNotEmpty) out[e.key] = nl;
    }
  }
  return out;
}
