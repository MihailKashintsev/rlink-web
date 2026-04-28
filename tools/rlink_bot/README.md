# rlink_bot — Python-бот для Rlink (relay + E2E)

Формат шифрования совместим с клиентом Flutter (`CryptoService` + gossip `msg`).

**Relay по умолчанию** — тот же, что в приложении: `wss://rlink.ru.tuna.am` (константа `rlink_bot/relay_defaults.py`, синхронно с `RelayService.defaultServerUrl` во Flutter). Указывать `--relay` нужно только если вы поднимаете **свой** relay.

---

## Три шага для разработчика

1. **Ключи** (один раз на машине с ботом):
   ```bash
   cd tools/rlink_bot
   python -m pip install -e .
   python -m rlink_bot keys init --file bot_keys.json
   python -m rlink_bot keys show-pub --file bot_keys.json
   ```
   Публичный **64 hex** отправьте боту **Lib** в Rlink: `/newbot ваш_ник` и ключ (или одной строкой).

2. **Код из Lib** — в ответе будет **claimCode** (коротко) и **claimId** (32 hex). Достаточно **одной команды** (relay не указываете — возьмётся как в приложении):
   ```bash
   python -m rlink_bot onboard СЮДА_ВСТАВИТЬ_КОД_ИЗ_LIB --file bot_keys.json
   ```
   В stdout один раз — **API token**; рядом появится `rlink_bot_config.json`.

3. **Онлайн**:
   echo-режим в этом репозитории отключён. Используйте только `tools/rlink_help_bot`:
   ```bash
   cd tools/rlink_help_bot
   python -m rlink_help_bot --config rlink_help_bot_config.json
   ```

Команда **`claim`** — то же, что **`onboard`**, но с явным **`--relay`** по умолчанию из переменной окружения `RLINK_RELAY_URL` (если нужен другой сервер).

Демо-формат claimCode (не из Lib): `python -m rlink_bot code`

## Установка

```bash
cd tools/rlink_bot
pip install -e .
```

### Windows (PowerShell)

- Во многих версиях PowerShell **`&&` не является разделителем команд** (ошибка «Лексема "&&"…»). Используйте **две строки** или **`;`**:
  ```powershell
  cd tools\rlink_bot
  python -m pip install -e .
  ```
- Нужна именно команда **`pip install -e .`** или **`python -m pip install -e .`** — в конце **точка** (каталог пакета). Команда **`pip install -e`** без аргумента завершится ошибкой.
- Ошибка **`No module named 'websocket'`** значит, что зависимости из `pyproject.toml` не установились (другой Python, не тот venv или установка не выполнялась). Повторите:
  ```powershell
  cd C:\путь\к\репо\tools\rlink_bot
  python -m pip install -e .
  python -m pip install "websocket-client>=1.7" "cryptography>=42"
  ```
  И дальше вызывайте **`python -m rlink_bot`** тем же интерпретатором, которым ставили пакеты.

Или без установки:

```bash
cd tools/rlink_bot
PYTHONPATH=. python -m rlink_bot keys init
```

## Локальный relay (опционально)

Если тестируете на своём сервере:

```bash
cd relay_server
dart run bin/server.dart
```

PowerShell: две строки, без `&&`. Тогда в шаге 2 используйте  
`python -m rlink_bot onboard КОД --file bot_keys.json --relay ws://127.0.0.1:8080`.

## Пример: справочный бот `rlink_help_bot`

В репозитории есть отдельный пакет **`tools/rlink_help_bot`** — меню по пунктам 1–8, ответы по ключевым словам и action-кнопки в пузыре (см. его `README.md`).

### Action-кнопки для любого Python-бота

Клиент Rlink понимает «кнопки как в TG» из текста сообщения в формате:

```text
[btn:Текст|/команда]
```

Можно добавить несколько кнопок в один ответ:

```text
Выберите действие:
[btn:Меню|/menu] [btn:Помощь|/help] [btn:Мои боты|/mybots]
```

Минимальный шаблон в Python:

```python
def button_tokens(pairs: list[tuple[str, str]]) -> str:
    return " ".join(f"[btn:{label}|{command}]" for label, command in pairs)

reply = (
    "Готово.\n\n"
    + button_tokens([
        ("Меню", "/menu"),
        ("Помощь", "/help"),
        ("Боты и Lib", "/topic_lib"),
    ])
)
sess.send_dm(user_id, reply)
```

`/команда` — любой текст, который ваш бот умеет обрабатывать в `on_dm`.

### Формат action-кнопок для любого бота

Кнопка кодируется прямо в тексте ответа:

```text
[btn:Текст кнопки|/команда]
```

Несколько кнопок можно отправить в одном сообщении:

```text
Подсказки:
[btn:Меню|/menu] [btn:Помощь|/help]
```

Клиент Rlink покажет чипы-кнопки и отправит `/команда` при нажатии.

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
