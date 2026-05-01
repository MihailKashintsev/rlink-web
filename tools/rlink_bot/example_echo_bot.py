#!/usr/bin/env python3
"""
Минимальный пример бота для Rlink с кнопками (ActionChips).

Запуск после onboard:
    python example_echo_bot.py --config rlink_bot_config.json

Кнопки в Rlink кодируются прямо в тексте ответа:
    [btn:Метка|/команда]

Клиент Rlink парсит их, отображает как кнопки-чипы и при нажатии
автоматически отправляет /команда в чат с ботом.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession


# ── Helpers ──────────────────────────────────────────────────────────────────

def btn(label: str, command: str) -> str:
    """Один токен кнопки. Несколько можно написать через пробел."""
    return f"[btn:{label}|{command}]"


def btns(*pairs: tuple[str, str]) -> str:
    """Строка из нескольких кнопок."""
    return " ".join(btn(label, cmd) for label, cmd in pairs)


# ── Логика ответов ────────────────────────────────────────────────────────────

_MAIN_MENU = btns(
    ("Привет", "/hello"),
    ("Эхо", "/echo"),
    ("Время", "/time"),
    ("Помощь", "/help"),
)

_HELP_TEXT = (
    "**Echo Bot** — пример бота Rlink.\n\n"
    "Команды:\n"
    "• /hello — приветствие\n"
    "• /echo — режим эха (ответит вашим текстом)\n"
    "• /time — текущее UTC-время\n"
    "• /help — эта справка\n"
    "• /menu — главное меню\n\n"
    + _MAIN_MENU
)

_HELLO_TEXT = (
    "Привет! Я Echo Bot, пример бота для Rlink.\n\n"
    "Пишите что угодно — я отвечу эхом.\n"
    "Или выберите действие:\n\n"
    + _MAIN_MENU
)

# Пользователи в «режиме эха»: peer_id → True
_echo_mode: dict[str, bool] = {}


def handle(sender: str, text: str) -> str:
    t = text.strip().lower()

    if t in ("/start", "/menu", "start", "menu", "меню"):
        _echo_mode.pop(sender, None)
        return (
            "📋 **Главное меню**\n\n"
            "Выберите действие:\n\n"
            + _MAIN_MENU
        )

    if t in ("/help", "help", "помощь"):
        _echo_mode.pop(sender, None)
        return _HELP_TEXT

    if t in ("/hello", "hello", "привет"):
        _echo_mode.pop(sender, None)
        return _HELLO_TEXT

    if t == "/time":
        import datetime
        now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
        return (
            f"🕐 Сейчас: **{now}**\n\n"
            + btns(("Обновить", "/time"), ("Меню", "/menu"))
        )

    if t == "/echo":
        _echo_mode[sender] = True
        return (
            "🔁 Режим **эха** включён. Следующее сообщение вернётся обратно.\n\n"
            + btns(("Отмена", "/menu"))
        )

    if _echo_mode.get(sender):
        _echo_mode.pop(sender, None)
        return (
            f"🔁 Эхо: {text}\n\n"
            + btns(("Ещё эхо", "/echo"), ("Меню", "/menu"))
        )

    # Неизвестная команда / свободный текст
    return (
        f"Получил: «{text[:120]}»\n\n"
        "Не знаю такой команды. Попробуйте:\n\n"
        + _MAIN_MENU
    )


# ── Точка входа ───────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="Echo-бот пример для Rlink")
    ap.add_argument(
        "--config",
        default="rlink_bot_config.json",
        help="JSON конфиг после `python -m rlink_bot onboard` (по умолчанию rlink_bot_config.json)",
    )
    ap.add_argument("--relay", default=None, help="Переопределить relay URL из конфига")
    args = ap.parse_args()

    cfg_path = Path(args.config).expanduser().resolve()
    if not cfg_path.exists():
        print(f"Нет файла конфига: {cfg_path}", file=sys.stderr)
        print("Сначала выполните: python -m rlink_bot onboard <claimCode> --file bot_keys.json", file=sys.stderr)
        return 1

    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    relay = (args.relay or cfg.get("relay_url") or "").strip()
    keys_path = Path(cfg.get("keys_path") or "rlink_bot_keys.json").expanduser()
    if not keys_path.is_absolute():
        keys_path = (cfg_path.parent / keys_path).resolve()

    if not relay:
        print("В конфиге нет relay_url", file=sys.stderr)
        return 1
    if not keys_path.exists():
        print(f"Нет ключей: {keys_path}", file=sys.stderr)
        return 1

    keys = BotKeys.from_json_dict(json.loads(keys_path.read_text(encoding="utf-8")))
    handle_name = "@" + (cfg.get("handle") or "echo_bot")[:32]

    def log(msg: str) -> None:
        print(msg, flush=True)

    sess = RelayBotSession(relay, keys)
    log(f"[echo_bot] connecting {relay} nick={handle_name!r}")

    try:
        sess.connect(nick=handle_name)
    except Exception as e:
        log(f"[fatal] {e}")
        return 1

    log("[echo_bot] online. Ctrl+C — стоп.")

    def on_dm(sender: str, text: str) -> None:
        log(f"[dm {sender[:8]}…] {text[:80]!r}")
        try:
            reply = handle(sender, text)
            sess.send_dm(sender, reply)
        except Exception as e:
            log(f"[reply error] {e}")
            try:
                sess.send_dm(sender, "Произошла ошибка. Попробуйте /menu")
            except Exception:
                pass
        time.sleep(0.05)

    try:
        sess.recv_loop(on_dm, log=log)
    except KeyboardInterrupt:
        log("bye")
    finally:
        sess.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
