# rlink_bot — Python SDK для ботов Rlink

Формат шифрования совместим с Flutter-клиентом (`CryptoService` + gossip `msg`).

**Relay по умолчанию** — тот же, что в приложении: `wss://rlink.ru.tuna.am`.
Указывайте `--relay` только если поднимаете свой relay.

---

## Быстрый старт — три шага

### 1. Ключи (один раз на машине с ботом)

```bash
cd tools/rlink_bot
pip install -e .
python -m rlink_bot keys init --file bot_keys.json
python -m rlink_bot keys show-pub --file bot_keys.json
```

Скопируйте **64 hex** из последней команды.

### 2. Регистрация через Lib

В приложении Rlink → чат с ботом **Lib**:

```
/newbot ваш_ник <вставьте 64 hex сюда>
```

В ответе придёт **claimCode** (короткий, удобный) и claimId (32 hex).

```bash
python -m rlink_bot onboard ABCD-EFGH-JKLM --file bot_keys.json
```

В stdout один раз — **API token**. Рядом создастся `rlink_bot_config.json`.

### 3. Запуск

```bash
# Пример-эхо из этого репозитория:
python tools/rlink_bot/example_echo_bot.py --config rlink_bot_config.json

# Справочный бот с меню:
cd tools/rlink_help_bot
python -m rlink_help_bot --config rlink_help_bot_config.json
```

---

## Кнопки (InlineKeyboard)

Клиент Rlink показывает **кнопки-чипы** прямо в пузыре сообщения.
Формат — токен в тексте ответа:

```
[btn:Метка|/команда]
```

Несколько кнопок в одном сообщении:

```
Что хотите сделать?
[btn:Меню|/menu] [btn:Помощь|/help] [btn:Время|/time]
```

При нажатии клиент автоматически отправляет `/команда` в чат с ботом.

### Вспомогательная функция (Python)

```python
def btns(*pairs: tuple[str, str]) -> str:
    """Строка из нескольких кнопок."""
    return " ".join(f"[btn:{label}|{cmd}]" for label, cmd in pairs)

reply = (
    "Привет! Выберите действие:\n\n"
    + btns(
        ("Меню", "/menu"),
        ("Помощь", "/help"),
        ("Эхо", "/echo"),
    )
)
sess.send_dm(user_id, reply)
```

### Минимальный бот с кнопками

```python
from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession
import json
from pathlib import Path

cfg = json.loads(Path("rlink_bot_config.json").read_text())
keys = BotKeys.from_json_dict(json.loads(Path(cfg["keys_path"]).read_text()))
sess = RelayBotSession(cfg["relay_url"], keys)
sess.connect(nick="@mybot")

def on_dm(sender: str, text: str) -> None:
    if text.strip().lower() in ("/start", "/menu"):
        sess.send_dm(sender,
            "Привет!\n\n[btn:Помощь|/help] [btn:Эхо|/echo]"
        )
    elif text.strip().lower() == "/help":
        sess.send_dm(sender, "Это пример бота. [btn:Назад|/menu]")
    else:
        sess.send_dm(sender, f"Эхо: {text}\n\n[btn:Меню|/menu]")

sess.recv_loop(on_dm)
```

Полный рабочий пример с меню, командами и режимом эха: `example_echo_bot.py`.

---

## Форматирование текста

Поддерживается Markdown-подобный синтаксис (как в Telegram):

| Синтаксис | Результат |
|-----------|-----------|
| `**текст**` | **жирный** |
| `_текст_` | *курсив* |
| `__текст__` | подчёркнутый |
| `~~текст~~` | зачёркнутый |
| `\`код\`` | моноширинный |
| `\`\`\`python\nкод\n\`\`\`` | блок кода с подсветкой |
| `\|\|текст\|\|` | спойлер |

Пример:

```python
sess.send_dm(user_id,
    "**Результат поиска:**\n\n"
    "```python\nprint('Hello, Rlink!')\n```\n\n"
    "[btn:Новый поиск|/search] [btn:Меню|/menu]"
)
```

---

## API бота (HTTP)

После `onboard` есть API-токен для управления метаданными бота через HTTP:

```bash
# Установить описание
curl -X POST "http://relay:8080/bot-api/v1/setMyDescription" \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  -H "Content-Type: application/json" \
  -d '{"description":"Мой бот"}'

# Аватар (публичный URL)
curl -X POST "http://relay:8080/bot-api/v1/setMyAvatarUrl" \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/avatar.png"}'
```

Другие методы: `setMyName`, `setMyBannerUrl`, `setWebhook`, `revokeToken`.

---

## Установка

```bash
cd tools/rlink_bot
pip install -e .
```

### Windows (PowerShell)

```powershell
cd tools\rlink_bot
python -m pip install -e .
```

Если `&&` не работает — используйте две строки или `;`.

При ошибке `No module named 'websocket'`:
```powershell
python -m pip install "websocket-client>=1.7" "cryptography>=42"
```

---

## Структура пакета

| Файл | Что делает |
|------|-----------|
| `rlink_bot/relay_client.py` | WebSocket-сессия: connect, send_dm, recv_loop |
| `rlink_bot/crypto_rlink.py` | Ключи Ed25519/X25519, шифрование DM |
| `rlink_bot/bootstrap.py` | Онбординг (claim) + запись конфига |
| `rlink_bot/cli.py` | CLI: `keys init`, `keys show-pub`, `onboard`, `run` |
| `example_echo_bot.py` | Пример бота с кнопками, командами и эхо |

---

## Переменные окружения

| Переменная | Назначение |
|------------|-----------|
| `RLINK_RELAY_URL` | URL WebSocket relay по умолчанию |
