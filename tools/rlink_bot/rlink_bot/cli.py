"""CLI: keys init | keys show-pub | onboard | claim | run | code"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
from pathlib import Path

from rlink_bot.bootstrap import claim_and_save_config, normalize_claim_from_lib
from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession
from rlink_bot.relay_defaults import DEFAULT_RELAY_WS

DEFAULT_RELAY = os.environ.get("RLINK_RELAY_URL", DEFAULT_RELAY_WS)

_CLAIM_CODE_ALPHABET_STR = "23456789ABCDEFGHJKMNPRSTWXYZ"


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


def _do_claim_save(args: argparse.Namespace, *, label: str) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing keys file {p}", file=sys.stderr)
        return 1
    relay = args.relay.strip()
    out = Path(args.out).expanduser().resolve()
    try:
        raw = args.claim_id.strip()
        normalize_claim_from_lib(raw)  # validate early
        cfg = claim_and_save_config(
            p,
            raw,
            relay=relay or None,
            out_path=out,
            nick=args.nick,
        )
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    except RuntimeError as e:
        print("claim failed:", e, file=sys.stderr)
        return 1
    except Exception as e:
        print(label, e, file=sys.stderr)
        return 1

    token = cfg.get("api_token")
    handle = cfg.get("handle")
    bot_id = cfg.get("bot_id")
    print("OK handle=@%s botId=%s" % (handle, bot_id))
    if token:
        print("API token (save once):", token)
    print("Wrote", out)
    print("Relay:", cfg.get("relay_url"))
    return 0


def cmd_onboard(args: argparse.Namespace) -> int:
    """Claim с relay по умолчанию (как в приложении Rlink)."""
    print("Using relay:", args.relay.strip() or DEFAULT_RELAY_WS)
    return _do_claim_save(args, label="onboard:")


def cmd_claim(args: argparse.Namespace) -> int:
    return _do_claim_save(args, label="claim:")


def cmd_code(_args: argparse.Namespace) -> int:
    t = "".join(secrets.choice(_CLAIM_CODE_ALPHABET_STR) for _ in range(12))
    print(f"{t[0:4]}-{t[4:8]}-{t[8:12]}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing file {p}", file=sys.stderr)
        return 1
    relay = args.relay.strip()
    nick = args.nick

    try:
        top = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"Bad JSON in {p}: {e}", file=sys.stderr)
        return 1
    if not isinstance(top, dict):
        print(f"Expected JSON object in {p}", file=sys.stderr)
        return 1

    # После onboard удобно вызывать: run --file rlink_bot_config.json
    cfg: dict | None = None
    keys_json_path = p
    if "keys_path" in top and "ed25519_private_hex" not in top:
        cfg = top
        keys_json_path = Path(str(top["keys_path"])).expanduser().resolve()
    else:
        cfg_path = p.parent / "rlink_bot_config.json"
        if cfg_path.exists():
            try:
                maybe = json.loads(cfg_path.read_text(encoding="utf-8"))
                if isinstance(maybe, dict) and maybe.get("keys_path"):
                    cfg = maybe
            except (OSError, json.JSONDecodeError, TypeError):
                pass

    if not keys_json_path.exists():
        print(f"Missing keys file {keys_json_path}", file=sys.stderr)
        return 1
    try:
        keys = BotKeys.from_json_dict(
            json.loads(keys_json_path.read_text(encoding="utf-8"))
        )
    except KeyError as e:
        print(
            f"{keys_json_path} is not a bot keys file (need ed25519_*). "
            f"Use `run --file rlink_bot_config.json` after onboard, or `--file bot_keys.json`. "
            f"Missing: {e}",
            file=sys.stderr,
        )
        return 1

    if cfg:
        try:
            r = str(cfg.get("relay_url") or "").strip()
            if r:
                relay = r
            if nick is None:
                h = cfg.get("handle")
                if isinstance(h, str) and h.strip():
                    hn = h.strip()
                    nick = hn if hn.startswith("@") else ("@" + hn)
                    nick = nick[:64]
        except (TypeError, AttributeError):
            pass
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

    onboard = sub.add_parser(
        "onboard",
        help="Завершить регистрацию: вставьте claimId/claimCode из Lib (relay по умолчанию как в Rlink)",
    )
    onboard.add_argument(
        "claim_id",
        help="Скопируйте из ответа Lib после /newbot (32 hex или ABCD-EFGH-JKLM)",
    )
    onboard.add_argument("--file", default="rlink_bot_keys.json")
    onboard.add_argument(
        "--relay",
        default="",
        help=f"Необязательно; по умолчанию {DEFAULT_RELAY_WS}",
    )
    onboard.add_argument("--nick", default=None)
    onboard.add_argument("--out", default="rlink_bot_config.json")
    onboard.set_defaults(func=cmd_onboard)

    c = sub.add_parser(
        "claim",
        help="То же, что onboard: claim на relay (явный --relay при другом сервере)",
    )
    c.add_argument("claim_id")
    c.add_argument("--file", default="rlink_bot_keys.json")
    c.add_argument("--relay", default=DEFAULT_RELAY)
    c.add_argument("--nick", default=None)
    c.add_argument("--out", default="rlink_bot_config.json")
    c.set_defaults(func=cmd_claim)

    sub.add_parser(
        "code",
        help="Print a random claimCode-style string (demo only)",
    ).set_defaults(func=cmd_code)

    r = sub.add_parser(
        "run",
        help="Connect and echo DMs; --file = bot_keys.json или rlink_bot_config.json после onboard",
    )
    r.add_argument(
        "--file",
        default="rlink_bot_keys.json",
        help="Ключи бота (JSON) или rlink_bot_config.json из onboard",
    )
    r.add_argument("--relay", default=DEFAULT_RELAY)
    r.add_argument("--nick", default=None)
    r.set_defaults(func=cmd_run)

    args = ap.parse_args()
    raise SystemExit(args.func(args))
