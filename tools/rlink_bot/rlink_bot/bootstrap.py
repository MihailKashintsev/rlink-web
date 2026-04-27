"""Регистрация бота на relay: claim из Lib + запись конфига (без дублирования логики в CLI)."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession
from rlink_bot.relay_defaults import DEFAULT_RELAY_WS

_CLAIM_CODE_ALPHABET = frozenset("23456789ABCDEFGHJKMNPRSTWXYZ")


def _normalize_claim_code(raw: str) -> str | None:
    t = raw.strip().upper().replace(" ", "").replace("-", "").replace("_", "")
    if len(t) != 12:
        return None
    if any(c not in _CLAIM_CODE_ALPHABET for c in t):
        return None
    return f"{t[0:4]}-{t[4:8]}-{t[8:12]}"


def _is_hex_claim_id(s: str) -> bool:
    s = s.strip().lower()
    return len(s) == 32 and all(c in "0123456789abcdef" for c in s)


def normalize_claim_from_lib(raw: str) -> str:
    """
    Нормализует значение из Lib: 32 hex claimId или claimCode ABCD-EFGH-JKLM.
    Бросает ValueError при неверном формате.
    """
    s = raw.strip()
    if _is_hex_claim_id(s):
        return s.lower()
    canon = _normalize_claim_code(s)
    if canon:
        return canon
    raise ValueError(
        "Нужен claimId (32 hex) или claimCode (12 символов, например ABCD-EFGH-JKLM) из ответа Lib."
    )


def claim_and_save_config(
    keys_path: Path,
    claim_raw: str,
    *,
    relay: str | None = None,
    out_path: Path | None = None,
    nick: str | None = None,
) -> dict[str, Any]:
    """
    Подключается к relay, выполняет bot_claim, пишет JSON конфига.
    relay по умолчанию — как в приложении Rlink.
    """
    keys_path = keys_path.expanduser().resolve()
    if not keys_path.exists():
        raise FileNotFoundError(f"Нет файла ключей: {keys_path}")
    claim = normalize_claim_from_lib(claim_raw)
    relay_url = (relay or DEFAULT_RELAY_WS).strip()
    out = (out_path or keys_path.parent / "rlink_bot_config.json").expanduser().resolve()

    keys = BotKeys.from_json_dict(json.loads(keys_path.read_text(encoding="utf-8")))
    sess = RelayBotSession(relay_url, keys)
    try:
        sess.connect(nick=nick if nick else ("@" + keys.ed25519_public_hex[:10]))
        ack = sess.claim(claim)
    finally:
        sess.close()

    if not ack.get("ok"):
        raise RuntimeError(ack.get("error") or "claim_failed")

    token = ack.get("apiToken")
    handle = ack.get("handle")
    bot_id = ack.get("botId")
    cfg: dict[str, Any] = {
        "relay_url": relay_url,
        "handle": handle,
        "bot_id": bot_id,
        "api_token": token,
        "keys_path": str(keys_path),
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return cfg


def load_config(path: Path) -> dict[str, Any]:
    p = path.expanduser().resolve()
    return json.loads(p.read_text(encoding="utf-8"))


def run_echo_forever(config_path: Path) -> None:
    """Читает конфиг после claim, подключается и шлёт echo на DM."""
    cfg = load_config(config_path)
    keys_path = Path(cfg["keys_path"]).expanduser().resolve()
    relay = str(cfg.get("relay_url") or DEFAULT_RELAY_WS).strip()
    keys = BotKeys.from_json_dict(json.loads(keys_path.read_text(encoding="utf-8")))
    handle = str(cfg.get("handle") or "bot")[:32]
    nick = "@" + handle if not handle.startswith("@") else handle[:64]

    sess = RelayBotSession(relay, keys)
    print("Connecting", relay)

    def on_dm(sender: str, text: str) -> None:
        print(f"[DM {sender[:8]}] {text!r}")
        try:
            sess.send_dm(sender, f"echo: {text}")
        except Exception as e:
            print("[reply error]", e)

    try:
        sess.connect(nick=nick)
        print("Echo mode — Ctrl+C to stop.")
        sess.recv_loop(on_dm, log=lambda m: print(m))
    finally:
        sess.close()
