# Rlink_help_bot — справка по Rlink в личке

Сторонний бот на **Python** (тот же стек, что `tools/rlink_bot`: relay WebSocket + E2E).  
В приложении для ботов теперь поддерживаются **текстовые action-кнопки** в сообщениях (чипы, как у Lib), если бот отправляет специальный маркер.

---

## Windows (PowerShell)

В PowerShell **не используйте `&&`** (в старых версиях будет ошибка). Пишите так:

```powershell
cd tools\rlink_bot
python -m pip install -e .
```

Команда должна быть **`install -e .`** — с **точкой** в конце. Если **`No module named 'websocket'`**, зависимости не встали в тот же Python:

```powershell
python -m pip install -e .
python -m pip install "websocket-client>=1.7" "cryptography>=42"
```

---

## Чеклист: что сделать по шагам

1. **Установить SDK бота** (один раз на машине):

   bash / macOS / Linux:
   ```bash
   cd tools/rlink_bot
   pip install -e .
   ```

   PowerShell:
   ```powershell
   cd tools\rlink_bot
   python -m pip install -e .
   ```

2. **Сгенерировать ключи** под процесс бота:
   ```bash
   cd tools/rlink_bot
   python -m rlink_bot keys init --file ../rlink_help_bot/rlink_help_bot_keys.json
   python -m rlink_bot keys show-pub --file ../rlink_help_bot/rlink_help_bot_keys.json
   ```
   Скопируйте **64 hex** публичного Ed25519.

3. **Relay** с реестром ботов (локально или прод с новым `server.dart`):

   ```bash
   cd relay_server
   dart run bin/server.dart
   ```

   PowerShell:
   ```powershell
   cd relay_server
   dart run bin/server.dart
   ```
   Для приложения нужен **тот же** relay URL, что и у бота (`RLINK_RELAY_URL`).

4. **В Rlink**: **Боты → Lib** → `/start` →  
   `/newbot rlink_help_bot`  
   затем **отдельным сообщением** вставить публичный ключ (или одной строкой  
   `/newbot rlink_help_bot <64hex>`).

5. **Onboard** — вставьте **claimCode** или **claimId** из ответа Lib (relay по умолчанию как в приложении Rlink):
   ```bash
   cd tools/rlink_help_bot
   python3 -m pip install -e .
   python3 -m rlink_bot onboard КОД_ИЗ_LIB --file rlink_help_bot_keys.json --out rlink_help_bot_config.json
   ```
   Другой relay: `--relay ws://127.0.0.1:8080`. Сохраните **API token** из stdout.

6. **(Опционально) HTTP Bot API** — описание и имя в каталоге:
   ```bash
   BASE=http://127.0.0.1:8080   # ws:// → http://, тот же хост
   curl -sS -X POST "$BASE/bot-api/v1/setMyName" \
     -H "Authorization: Bearer ТОКЕН" -H "Content-Type: application/json" \
     -d '{"displayName":"Rlink Help"}'
   curl -sS -X POST "$BASE/bot-api/v1/setMyDescription" \
     -H "Authorization: Bearer ТОКЕН" -H "Content-Type: application/json" \
     -d '{"description":"Справка по Rlink: меню 1–8, /start, /menu"}'
   ```

7. **Запуск бота**:
   ```bash
   cd tools/rlink_help_bot
   python3 -m rlink_help_bot --config rlink_help_bot_config.json
   ```
   Relay подхватывается из `rlink_help_bot_config.json` (после onboard).

8. **Пользователь** в приложении: поиск **`@rlink_help_bot`** → написать `/start` или `1`.  
   Оба должны быть **онлайн на том же relay**, пока не подтянется **presence** с X25519 (иначе ответ не зашифровать).

---

## Кнопки в сообщениях бота (как у Lib)

Кнопка кодируется прямо в тексте сообщения:

```text
[btn:Текст кнопки|/команда]
```

Можно передать несколько кнопок в одном сообщении:

```text
Выберите действие:
[btn:Меню|/menu] [btn:Сеть BLE/relay|/topic_network] [btn:Боты и Lib|/topic_lib]
```

Что важно:
- `Текст кнопки` — подпись на чипе.
- `/команда` — то, что отправится при нажатии.
- Маркеры можно размещать в конце обычного текста ответа.
- Если команда не поддерживается ботом, обработайте её в `build_reply`.

В `rlink_help_bot` это уже реализовано: `/start` и `/menu` показывают кнопки по темам, а ответы содержат быстрые кнопки «Меню», «Сеть BLE/relay», «Боты и Lib».

---

## Файлы

| Файл | Назначение |
|------|------------|
| `rlink_help_bot_keys.json` | секретные ключи (не в git) |
| `rlink_help_bot_config.json` | после `claim`: relay, handle, bot_id, api_token |
| `rlink_help_bot/app.py` | логика меню и ответов |

Добавьте `rlink_help_bot_keys.json` и `rlink_help_bot_config.json` в `.gitignore` при необходимости.
