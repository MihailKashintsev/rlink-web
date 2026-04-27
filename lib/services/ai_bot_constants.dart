/// Внутренние идентификаторы ботов (64 hex, формат как у peer-id, но это не Ed25519 ключи).
/// Нужны для единообразного хранения диалогов в той же таблице, что и обычные чаты.
const String kGigachatBotPeerId =
    '726c696e6b6169626f7400000000000000000000000000000000000000000001';

/// Встроенный регистратор сторонних ботов (аналог BotFather).
const String kLibBotPeerId =
    '726c696e6b6169626f7400000000000000000000000000000000000000000002';

class AiBotDefinition {
  final String id;
  final String name;
  final int avatarColor;
  final String avatarEmoji;
  final String description;
  final bool enabledByDefault;

  const AiBotDefinition({
    required this.id,
    required this.name,
    required this.avatarColor,
    required this.avatarEmoji,
    required this.description,
    this.enabledByDefault = false,
  });
}

const AiBotDefinition kGigachatBot = AiBotDefinition(
  id: kGigachatBotPeerId,
  name: 'GigaChat',
  avatarColor: 0xFF21A038,
  avatarEmoji: '🤖',
  description: 'ИИ-ассистент от Сбера. Поддерживает только текст.',
  enabledByDefault: false,
);

const AiBotDefinition kLibBot = AiBotDefinition(
  id: kLibBotPeerId,
  name: 'Lib',
  avatarColor: 0xFF5C6BC0,
  avatarEmoji: '📚',
  description:
      'Регистрация ботов для разработчиков: команды /start, /newbot. '
      'Сообщения с ботами — E2E; relay не читает переписку.',
  enabledByDefault: false,
);

const List<AiBotDefinition> kBuiltinAiBots = <AiBotDefinition>[
  kLibBot,
  kGigachatBot,
];

AiBotDefinition? findAiBotById(String id) {
  for (final bot in kBuiltinAiBots) {
    if (bot.id == id) return bot;
  }
  return null;
}

bool isAiBotPeerId(String id) => findAiBotById(id) != null;
