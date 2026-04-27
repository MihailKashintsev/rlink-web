#!/usr/bin/env python3
"""
Минимальный echo-бот для Rlink.

1) Один раз: в каталоге этого файла выполните
     python -m rlink_bot keys init --file bot_keys.json
2) В приложении Rlink → Lib → /newbot ваш_ник → вставьте публичный ключ.
3) Скопируйте из ответа Lib **claimCode** (или claimId) в переменную RELAY_CLAIM ниже.
4) Запуск:  python example_echo_bot.py

Нужен установленный пакет: из каталога tools/rlink_bot выполните  python -m pip install -e .
Relay по умолчанию совпадает с приложением Rlink (см. rlink_bot.relay_defaults).
"""

from __future__ import annotations

import sys
from pathlib import Path

# ── Вставьте сюда значение из ответа Lib (одна строка, без кавычек) ─────
RELAY_CLAIM = "PASTE_FROM_LIB"
# ───────────────────────────────────────────────────────────────────────

_KEYS = Path(__file__).resolve().parent / "bot_keys.json"
_CONFIG = Path(__file__).resolve().parent / "rlink_bot_config.json"


def main() -> int:
    if not _KEYS.exists():
        print("Нет bot_keys.json — выполните:", file=sys.stderr)
        print("  python -m rlink_bot keys init --file bot_keys.json", file=sys.stderr)
        return 1

    paste = RELAY_CLAIM.strip()
    if paste in ("", "PASTE_FROM_LIB"):
        if not _CONFIG.exists():
            print(
                "В начале example_echo_bot.py задайте RELAY_CLAIM из ответа Lib "
                "(claimCode или 32 hex).",
                file=sys.stderr,
            )
            return 1
    else:
        if not _CONFIG.exists():
            from rlink_bot.bootstrap import claim_and_save_config

            print("Первичный claim на relay…")
            claim_and_save_config(_KEYS, paste, out_path=_CONFIG)

    from rlink_bot.bootstrap import run_echo_forever

    run_echo_forever(_CONFIG)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
