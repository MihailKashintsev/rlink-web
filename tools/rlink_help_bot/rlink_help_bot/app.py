"""
Rlink_help_bot — справка по Rlink в личке.

Кнопки кодируются токенами [btn:Метка|/команда] прямо в тексте ответа.
Клиент Rlink парсит и показывает их как чипы-кнопки (ActionChip).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Callable

from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession

# Совместимо с клиентом Rlink: OutboundDmText._chunkLen = 600
_MAX_DM_CHARS = 580


def _chunk_text(text: str, size: int = _MAX_DM_CHARS) -> list[str]:
    t = text.strip()
    if not t:
        return []
    return [t[i : i + size] for i in range(0, len(t), size)]


def _send_chunks(
    sess: RelayBotSession,
    to_hex: str,
    text: str,
    log: Callable[[str], None],
) -> None:
    for part in _chunk_text(text):
        try:
            sess.send_dm(to_hex, part)
            time.sleep(0.12)
        except Exception as e:
            log(f"[send] {e}")
            raise


# ── База ответов (индекс = «кнопка» в меню) ─────────────────────────

_TOPIC_DEFS: list[tuple[str, str, tuple[str, ...], str]] = [
    (
        "1",
        "Что такое Rlink",
        ("rlink", "мессенджер", "e2e", "шифрование", "что это", "what"),
        """**Rlink** — децентрализованный мессенджер с **сквозным шифрованием (E2E)**.

Сообщения идут по **Bluetooth (рядом)** и/или через **relay** в интернете. Relay видит только **зашифрованные пакеты** и публичные ключи — не читает текст переписок.

История чатов хранится **локально** на устройстве.""",
    ),
    (
        "2",
        "Ключи и профиль",
        ("ключ", "ed25519", "x25519", "профиль", "аккаунт", "keys"),
        """При первом запуске приложение создаёт пару ключей:

• **Ed25519** — ваш идентификатор в сети и подписи.
• **X25519** — для установления секрета и **шифрования** личных сообщений.

Профиль (ник, аватар, username) виден контактам. Публичный ключ можно передать вручную или найти человека **поиском на relay**.""",
    ),
    (
        "3",
        "BLE и relay",
        ("ble", "bluetooth", "relay", "интернет", "сеть", "mesh"),
        """**BLE** — общение с устройствами в радиусе Bluetooth.

**Relay** — когда включён интернет‑режим, сообщения могут дойти до удалённого собеседника через сервер‑ретранслятор.

**Связка устройств** — два ваших устройства могут синхронизировать часть личных чатов через relay (см. настройки сети в приложении).""",
    ),
    (
        "4",
        "Боты: Lib и свои боты",
        ("lib", "newbot", "бот", "bot", "claim", "регистрация"),
        """**Lib** — встроенный регистратор сторонних ботов (аналог BotFather): `/start`, `/newbot`, `/cancel`, `/guide`.

Вы создаёте **отдельную пару ключей** для бота, регистрируете `@ник` на relay, затем процесс бота подключается к relay как обычный клиент.

Переписка с ботом — **то же E2E**, что с людьми. Пользователи находят бота по **@нику** в поиске.""",
    ),
    (
        "5",
        "Python SDK (rlink_bot)",
        ("python", "pip", "rlink_bot", "sdk", "echo"),
        """Пример стека в репозитории: каталог **tools/rlink_bot**.

Типичный цикл:
1. `python -m rlink_bot keys init`
2. В приложении: Lib → `/newbot ваш_ник` + публичный ключ.
3. `python -m rlink_bot claim <claimId или claimCode> --relay …`
4. `python -m rlink_bot run` — процесс онлайн, расшифровка DM.

Нужен **X25519** собеседника из **presence** на том же relay — пока пользователь не онлайн, ответ может быть не зашифрован.""",
    ),
    (
        "6",
        "Сообщения и вложения",
        ("файл", "фото", "голос", "стикер", "вложение", "media"),
        """В личных чатах и группах поддерживаются текст, файлы, медиа (в рамках платформы), стикеры, ответы и реакции.

Ограничения зависят от **OS** (микрофон, камера, фоновая работа). Очень большие файлы могут нарезаться на части при отправке через relay.""",
    ),
    (
        "7",
        "Документация в приложении",
        ("документация", "справка", "настройки", "docs", "help app"),
        """В приложении: **Настройки → Документация** — вкладки **Русский** / **English**: обзор Rlink, связь, боты, приватность.

Там же таблицы по командам **Lib** и краткий чеклист создания бота.""",
    ),
    (
        "8",
        "Подсказка по этому чату",
        ("меню", "кнопк", "start", "снова", "menu"),
        """Напишите **цифру 1–8** или команду **`/menu`**, **`/start`**.

Под каждым ответом — кнопки-чипы: нажмите или напишите команду текстом.""",
    ),
]


def _button_tokens(pairs: list[tuple[str, str]]) -> str:
    # Спец-формат для клиента Rlink: ActionChip-кнопки в пузыре.
    # Пример токена: [btn:Меню|/menu]
    return " ".join(f"[btn:{label}|{command}]" for label, command in pairs)


def _menu_text() -> str:
    lines = [
        "📚 **Rlink Help** — выберите тему (ответьте **цифрой** или командой `/menu`):",
        "",
    ]
    for num, title, _, _ in _TOPIC_DEFS:
        lines.append(f"  **{num}** · {title}")
    lines.extend(
        [
            "",
            "Команды: `/start` `/help` `/menu`",
            "",
            "_Подсказка: можно написать ключевое слово (например «relay» или «Lib»)._",
        ]
    )
    return "\n".join(lines)


def _normalize(s: str) -> str:
    return s.strip().lower()


def _resolve_topic(user_text: str) -> str | None:
    t = _normalize(user_text)
    if not t:
        return None
    if t in ("/start", "/help", "/menu", "menu", "меню", "привет", "hello", "hi"):
        return "__menu__"
    if t in ("/topic_intro", "/topic_keys", "/topic_network", "/topic_lib"):
        return {
            "/topic_intro": "1",
            "/topic_keys": "2",
            "/topic_network": "3",
            "/topic_lib": "4",
        }[t]
    if re.fullmatch(r"\d+", t):
        for num, _, _, _ in _TOPIC_DEFS:
            if t == num:
                return num
        return None
    for num, _, kws, _ in _TOPIC_DEFS:
        for kw in kws:
            if kw in t:
                return num
    return None


def _body_for(num: str) -> str | None:
    for n, _, _, body in _TOPIC_DEFS:
        if n == num:
            return body
    return None


def build_reply(user_text: str) -> str:
    key = _resolve_topic(user_text)
    if key == "__menu__" or key is None:
        if key is None and _normalize(user_text):
            hint = (
                "Не распознал запрос. Кратко опишите проблему или откройте меню цифрой **1–8**.\n\n"
            )
        else:
            hint = ""
        return (
            hint
            + _menu_text()
            + "\n\n"
            + _button_tokens(
                [
                    ("О приложении", "/topic_intro"),
                    ("Ключи", "/topic_keys"),
                    ("Сеть BLE/relay", "/topic_network"),
                    ("Боты и Lib", "/topic_lib"),
                    ("Меню", "/menu"),
                ]
            )
        )
    body = _body_for(key)
    assert body
    footer = (
        "\n\n—\n**Ещё вопрос?** Напишите `/menu` или другую цифру.\n\n"
        + _button_tokens(
            [
                ("Меню", "/menu"),
                ("Сеть BLE/relay", "/topic_network"),
                ("Боты и Lib", "/topic_lib"),
            ]
        )
    )
    return body + footer


def main() -> int:
    ap = argparse.ArgumentParser(description="Rlink_help_bot — справка в DM")
    ap.add_argument(
        "--config",
        default="rlink_help_bot_config.json",
        help="JSON после rlink_bot claim (relay_url, keys_path, …)",
    )
    ap.add_argument(
        "--relay",
        default=None,
        help="Переопределить relay URL из конфига",
    )
    args = ap.parse_args()

    cfg_path = Path(args.config).expanduser().resolve()
    if not cfg_path.exists():
        print(f"Нет файла конфига: {cfg_path}", file=sys.stderr)
        print("Сначала выполните claim (см. README).", file=sys.stderr)
        return 1

    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    relay = (args.relay or cfg.get("relay_url") or "").strip()
    keys_path = Path(cfg.get("keys_path") or "rlink_help_bot_keys.json").expanduser()
    if not keys_path.is_absolute():
        keys_path = (cfg_path.parent / keys_path).resolve()
    if not relay:
        print("В конфиге нет relay_url", file=sys.stderr)
        return 1
    if not keys_path.exists():
        print(f"Нет ключей: {keys_path}", file=sys.stderr)
        return 1

    keys = BotKeys.from_json_dict(json.loads(keys_path.read_text(encoding="utf-8")))
    nick = "@" + (cfg.get("handle") or "rlink_help_bot")[:32]

    def log(msg: str) -> None:
        print(msg, flush=True)

    sess = RelayBotSession(relay, keys)
    log(f"[rlink_help_bot] connecting {relay} nick={nick!r}")

    try:
        sess.connect(nick=nick)
    except Exception as e:
        log(f"[fatal] connect/register: {e}")
        return 1

    log("[rlink_help_bot] online. Ctrl+C — стоп.")

    def on_dm(sender: str, text: str) -> None:
        sid = sender.lower()
        log(f"[dm {sid[:8]}…] {text[:120]!r}")
        try:
            reply = build_reply(text)
            _send_chunks(sess, sid, reply, log)
        except Exception as e:
            log(f"[dm] reply error: {e}")
            try:
                _send_chunks(
                    sess,
                    sid,
                    "Сейчас не могу ответить (нет ключа X25519 собеседника в presence?). "
                    "Оставьте приложение открытым на том же relay и напишите снова.",
                    log,
                )
            except Exception:
                pass

    try:
        sess.recv_loop(on_dm, log=log)
    except KeyboardInterrupt:
        log("bye")
    finally:
        sess.close()
    return 0
