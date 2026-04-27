# rlink_bot — Python-бот для Rlink (relay + E2E)

Формат шифрования совместим с клиентом Flutter (`CryptoService` + gossip `msg`).

Пример формата короткого кода (только демо; рабочий код выдаёт Lib после `/newbot`):

```bash
python -m rlink_bot code
```

## Установка

```bash
cd tools/rlink_bot
pip install -e .
```

Или без установки:

```bash
cd tools/rlink_bot
PYTHONPATH=. python -m rlink_bot keys init
```

## Как завести бота (коротко)

1. **Relay** с поддержкой реестра ботов (ветка с `bot_register_start` / `bot_claim`). Для локального теста:
   ```bash
   cd relay_server && dart run bin/server.dart
   ```
   По умолчанию `ws://127.0.0.1:8080`. В приложении Rlink для теста нужен relay с этим адресом (если у вас только прод `wss://rlink.ru.tuna.am`, там должен быть задеплоен новый server).

2. **Ключи бота** на машине, где будет крутиться процесс:
   ```bash
   python -m rlink_bot keys init --file bot_keys.json
   python -m rlink_bot keys show-pub --file bot_keys.json
   ```
   Скопируйте **64 hex** публичного Ed25519.

3. **В приложении Rlink**: каталог ботов → **Lib** → `/start` → `/newbot myhandle` → вставить **публичный ключ** отдельным сообщением (или `/newbot myhandle <64hex>` одной строкой). В ответ придёт **claimId** (32 hex).

4. **Завершить регистрацию на relay** (тот же ключ, что в Lib):
   ```bash
   export RLINK_RELAY_URL=ws://127.0.0.1:8080   # или ваш wss://
   python -m rlink_bot claim <claimId> --file bot_keys.json --relay "$RLINK_RELAY_URL"
   ```
   В ответе Lib также есть короткий **claimCode** (формат `ABCD-EFGH-JKLM`, без 0/O/1/I/L) — его можно передать в `claim` вместо 32 hex **claimId**.
   В stdout один раз покажется **API token**; конфиг пишется в `rlink_bot_config.json`.

5. **Запуск echo-бота** (пользователь должен быть **онлайн**, чтобы пришёл `presence` с X25519 — иначе ответ зашифровать некуда):
   ```bash
   python -m rlink_bot run --file bot_keys.json --relay "$RLINK_RELAY_URL"
   ```

6. **Пользователь** в Rlink: поиск `@myhandle` → написать боту. Первое сообщение может прийти, когда у бота уже есть ваш `x25519` из presence (оба онлайн на одном relay).

## Пример: справочный бот `rlink_help_bot`

В репозитории есть отдельный пакет **`tools/rlink_help_bot`** — меню по пунктам 1–8 и ответы по ключевым словам (см. его `README.md`).

## HTTP Bot API (метаданные)

После `claim` у вас есть токен. Пример (локально порт 8080):

```bash
curl -sS -X POST "http://127.0.0.1:8080/bot-api/v1/setMyDescription" \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  -H "Content-Type: application/json" \
  -d '{"description":"Мой echo-бот"}'
```

Другие пути: `setWebhook`, `deleteWebhook`, `setMyName`, `revokeToken`.

Аватар и баннер в каталоге (публичные URL, `https` или `http`, до 2048 символов; пустая строка сбрасывает):

```bash
curl -sS -X POST "http://127.0.0.1:8080/bot-api/v1/setMyAvatarUrl" \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/bot-avatar.png"}'

curl -sS -X POST "http://127.0.0.1:8080/bot-api/v1/setMyBannerUrl" \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/bot-banner.jpg"}'
```

После сохранения relay рассылает обновлённый `bot_dir_snapshot` всем подключённым клиентам.

## Переменные окружения

| Переменная        | Назначение                          |
|-------------------|-------------------------------------|
| `RLINK_RELAY_URL` | URL WebSocket relay по умолчанию   |
