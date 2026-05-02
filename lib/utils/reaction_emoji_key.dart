/// Убирает невидимые символы и полуширинное двоеточие перед разбором ключа реакции.
String normalizeReactionKeyString(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  s = s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
  s = s.replaceAll('\uFF1A', ':');
  return s;
}

/// Внутренность `:…:`, если строка похожа на обёртку кастомного эмодзи.
///
/// Не требует `[a-zA-Z0-9_]`, чтобы не ломать shortcode с кириллицей и т.п.
/// (строгая проверка только при *добавлении* эмодзи в пак).
String? looseWrappedShortcodeInner(String raw) {
  final t = normalizeReactionKeyString(raw);
  if (t.length < 3) return null;
  if (t.codeUnitAt(0) != 0x3A || t.codeUnitAt(t.length - 1) != 0x3A) return null;
  final inner = t.substring(1, t.length - 1).trim();
  if (inner.isEmpty || inner.runes.length > 64) return null;
  if (inner.contains('/') ||
      inner.contains('\\') ||
      inner.contains('\n') ||
      inner.contains('\r')) {
    return null;
  }
  return inner;
}

/// Приводит ключ реакции к стабильному виду для хранения и сети.
///
/// Для `:shortcode:` — нормализует регистр внутренней части (в т.ч. Unicode).
/// Остальные строки (Unicode-эмодзи) возвращаются после [normalizeReactionKeyString].
String canonicalReactionEmojiKey(String raw) {
  final s = normalizeReactionKeyString(raw);
  if (s.isEmpty) return s;
  final inner = looseWrappedShortcodeInner(s);
  if (inner != null) {
    return ':${inner.toLowerCase()}:';
  }
  return s;
}
