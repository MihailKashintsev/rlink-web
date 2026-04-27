# Rlink_help_bot — справка по Rlink в личке

Сторонний бот на **Python** (тот же стек, что `tools/rlink_bot`: relay WebSocket + E2E).  
В приложении **нет Telegram‑подобных клавиатур** для обычных ботов — только текст. «Кнопки» здесь = **нумерованное меню** и короткие команды (`/start`, `1` …), на которые пользователь отвечает сообщением.

---

## Чеклист: что сделать по шагам

1. **Установить SDK бота** (один раз на машине):
   ```bash
   cd tools/rlink_bot && pip install -e .
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
   cd relay_server && dart run bin/server.dart
   ```
   Для приложения нужен **тот же** relay URL, что и у бота (`RLINK_RELAY_URL`).

4. **В Rlink**: **Боты → Lib** → `/start` →  
   `/newbot rlink_help_bot`  
   затем **отдельным сообщением** вставить публичный ключ (или одной строкой  
   `/newbot rlink_help_bot <64hex>`).

5. **Завершить claim** (именно **ключ бота**, не ваш личный):
   ```bash
   cd tools/rlink_help_bot
   export RLINK_RELAY_URL=ws://127.0.0.1:8080   # ваш relay
   pip install -e .
   python -m rlink_bot claim <claimId_или_claimCode> \
     --file rlink_help_bot_keys.json --relay "$RLINK_RELAY_URL" \
     --out rlink_help_bot_config.json
   ```
   Сохраните **API token** из stdout.

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
   export RLINK_RELAY_URL=ws://127.0.0.1:8080
   python -m rlink_help_bot --config rlink_help_bot_config.json
   ```

8. **Пользователь** в приложении: поиск **`@rlink_help_bot`** → написать `/start` или `1`.  
   Оба должны быть **онлайн на том же relay**, пока не подтянется **presence** с X25519 (иначе ответ не зашифровать).

---

## Файлы

| Файл | Назначение |
|------|------------|
| `rlink_help_bot_keys.json` | секретные ключи (не в git) |
| `rlink_help_bot_config.json` | после `claim`: relay, handle, bot_id, api_token |
| `rlink_help_bot/app.py` | логика меню и ответов |

Добавьте `rlink_help_bot_keys.json` и `rlink_help_bot_config.json` в `.gitignore` при необходимости.
