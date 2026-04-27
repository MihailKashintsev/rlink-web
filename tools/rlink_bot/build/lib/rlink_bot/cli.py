"""CLI: keys init | keys show-pub | claim | run"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
from pathlib import Path

from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession

DEFAULT_RELAY = os.environ.get("RLINK_RELAY_URL", "wss://rlink.ru.tuna.am")

_CLAIM_CODE_ALPHABET_STR = "23456789ABCDEFGHJKMNPRSTWXYZ"
_CLAIM_CODE_ALPHABET = frozenset(_CLAIM_CODE_ALPHABET_STR)


def _normalize_claim_code(raw: str) -> str | None:
    """Канонический AAAA-BBBB-CCCC или None."""
    t = raw.strip().upper().replace(" ", "").replace("-", "").replace("_", "")
    if len(t) != 12:
        return None
    if any(c not in _CLAIM_CODE_ALPHABET for c in t):
        return None
    return f"{t[0:4]}-{t[4:8]}-{t[8:12]}"


def _is_hex_claim_id(s: str) -> bool:
    s = s.strip().lower()
    return len(s) == 32 and all(c in "0123456789abcdef" for c in s)


def _keys_path(args: argparse.Namespace) -> Path:
    return Path(args.file).expanduser().resolve()


def cmd_keys_init(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if p.exists() and not args.force:
        print(f"Refusing to overwrite {p} (use --force)", file=sys.stderr)
        return 1
    keys = BotKeys.generate()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(keys.to_json_dict(), indent=2), encoding="utf-8")
    print(f"Wrote {p}")
    print("Ed25519 public (for Lib /newbot):", keys.ed25519_public_hex)
    return 0


def cmd_keys_show_pub(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing {p}", file=sys.stderr)
        return 1
    d = json.loads(p.read_text(encoding="utf-8"))
    print(d.get("ed25519_public_hex") or BotKeys.from_json_dict(d).ed25519_public_hex)
    return 0


def cmd_claim(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing keys file {p}", file=sys.stderr)
        return 1
    keys = BotKeys.from_json_dict(json.loads(p.read_text(encoding="utf-8")))
    raw = args.claim_id.strip()
    if _is_hex_claim_id(raw):
        claim = raw.strip().lower()
    else:
        canon = _normalize_claim_code(raw)
        if not canon:
            print(
                "claimId must be 32 hex chars, or claimCode like ABCD-EFGH-JKLM "
                "(12 letters/digits without 0/O/1/I/L)",
                file=sys.stderr,
            )
            return 1
        claim = canon
    relay = args.relay.strip()
    sess = RelayBotSession(relay, keys)
    try:
        sess.connect(nick=args.nick)
        ack = sess.claim(claim)
    finally:
        sess.close()
    if not ack.get("ok"):
        print("claim failed:", ack.get("error"), file=sys.stderr)
        return 1
    token = ack.get("apiToken")
    handle = ack.get("handle")
    bot_id = ack.get("botId")
    print("OK handle=@%s botId=%s" % (handle, bot_id))
    if token:
        print("API token (save once):", token)
    cfg = {
        "relay_url": relay,
        "handle": handle,
        "bot_id": bot_id,
        "api_token": token,
        "keys_path": str(p),
    }
    out = Path(args.out).expanduser().resolve()
    out.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    print("Wrote", out)
    return 0


def cmd_code(_args: argparse.Namespace) -> int:
    """Тот же формат, что у relay для claimCode (локально — только для примера)."""
    t = "".join(secrets.choice(_CLAIM_CODE_ALPHABET_STR) for _ in range(12))
    print(f"{t[0:4]}-{t[4:8]}-{t[8:12]}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing keys file {p}", file=sys.stderr)
        return 1
    keys = BotKeys.from_json_dict(json.loads(p.read_text(encoding="utf-8")))
    relay = args.relay.strip()
    nick = args.nick
    sess = RelayBotSession(relay, keys)
    print("Connecting", relay)

    def on_dm(sender: str, text: str) -> None:
        print(f"[DM {sender[:8]}] {text!r}")
        try:
            sess.send_dm(sender, f"echo: {text}")
        except Exception as e:
            print("[reply error]", e, file=sys.stderr)

    try:
        sess.connect(nick=nick)
        print("Registered as bot. Echo mode — Ctrl+C to stop.")
        sess.recv_loop(on_dm, log=lambda m: print(m))
    except KeyboardInterrupt:
        print("bye")
    finally:
        sess.close()
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m rlink_bot")
    sub = ap.add_subparsers(dest="cmd", required=True)

    k = sub.add_parser("keys", help="Manage bot key file")
    ks = k.add_subparsers(dest="keys_cmd", required=True)
    ki = ks.add_parser("init", help="Generate new Ed25519 + X25519 keys")
    ki.add_argument("--file", default="rlink_bot_keys.json")
    ki.add_argument("--force", action="store_true")
    ki.set_defaults(func=cmd_keys_init)

    kp = ks.add_parser("show-pub", help="Print Ed25519 public hex (for Lib)")
    kp.add_argument("--file", default="rlink_bot_keys.json")
    kp.set_defaults(func=cmd_keys_show_pub)

    c = sub.add_parser(
        "claim",
        help="Finish relay registration (claimId 32 hex or claimCode AAAA-BBBB-CCCC from Lib)",
    )
    c.add_argument("claim_id")
    c.add_argument("--file", default="rlink_bot_keys.json")
    c.add_argument("--relay", default=DEFAULT_RELAY)
    c.add_argument("--nick", default=None, help="Short nick on relay (default from pubkey)")
    c.add_argument("--out", default="rlink_bot_config.json")
    c.set_defaults(func=cmd_claim)

    sub.add_parser(
        "code",
        help="Print a random claimCode-style string (relay generates the real code on /newbot)",
    ).set_defaults(func=cmd_code)

    r = sub.add_parser("run", help="Connect and echo DMs (needs peers x25519 via presence)")
    r.add_argument("--file", default="rlink_bot_keys.json")
    r.add_argument("--relay", default=DEFAULT_RELAY)
    r.add_argument("--nick", default=None)
    r.set_defaults(func=cmd_run)

    args = ap.parse_args()
    raise SystemExit(args.func(args))
