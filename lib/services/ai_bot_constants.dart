/// Внутренние идентификаторы ботов (64 hex, формат как у peer-id, но это не Ed25519 ключи).
/// Нужны для единообразного хранения диалогов в той же таблице, что и обычные чаты.
const String kGigachatBotPeerId =
    '726c696e6b6169626f7400000000000000000000000000000000000000000001';

/// Встроенный регистратор сторонних ботов (аналог BotFather).
const String kLibBotPeerId =
    '726c696e6b6169626f7400000000000000000000000000000000000000000002';

/// Встроенный бот наборов кастомных эмодзи (:shortcode:).
const String kEmojiBotPeerId =
    '726c696e6b6169626f7400000000000000000000000000000000000000000003';

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
  description:
      'ИИ-ассистент от Сбера. В Rlink — только текст (без файлов, голоса и звонков). '
      'Ответы приходят с серверов Сбера; нужен интернет и настроенный GigaChat.',
  enabledByDefault: true,
);

const AiBotDefinition kLibBot = AiBotDefinition(
  id: kLibBotPeerId,
  name: 'Lib',
  avatarColor: 0xFF5C6BC0,
  avatarEmoji: '📚',
  description:
      'Регистратор сторонних ботов для разработчиков: команды /start, /newbot и др. '
      'Диалоги с Lib и с ботами из каталога — только текст. '
      'Переписка с пользователями и ботами шифруется end-to-end; relay не читает содержимое.',
  enabledByDefault: true,
);

const AiBotDefinition kEmojiBot = AiBotDefinition(
  id: kEmojiBotPeerId,
  name: 'Emoji',
  avatarColor: 0xFFFFB300,
  avatarEmoji: '😀',
  description:
      'Свои картинки-эмодзи как :shortcode: в сообщениях. Команды /start, /newpack, /add, /share. '
      'Данные только на устройстве; карточка набора передаётся вместе с сообщением в чате.',
  enabledByDefault: true,
);

const List<AiBotDefinition> kBuiltinAiBots = <AiBotDefinition>[
  kLibBot,
  kEmojiBot,
  kGigachatBot,
];

AiBotDefinition? findAiBotById(String id) {
  for (final bot in kBuiltinAiBots) {
    if (bot.id == id) return bot;
  }
  return null;
}

bool isAiBotPeerId(String id) => findAiBotById(id) != null;
