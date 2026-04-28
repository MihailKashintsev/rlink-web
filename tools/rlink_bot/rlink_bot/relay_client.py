"""WebSocket client for Rlink relay (register, packet, presence, bot_claim)."""

from __future__ import annotations

import base64
import json
import ssl
import uuid
from typing import Any, Callable

import websocket

from rlink_bot.crypto_rlink import BotKeys, build_msg_packet, decrypt_dm

# После register relay сразу шлёт снимки каталогов и presence в тот же WS;
# их нужно пропустить, пока не дождёмся ответа на bot_claim.
_SKIP_UNTIL_BOT_CLAIM_ACK = frozenset(
    {
        "channel_dir_snapshot",
        "bot_dir_snapshot",
        "presence",
        "account_sync_blob",
        "packet",
        "pong",
        "search_result",
        "delivery_status",
    }
)


class RelayBotSession:
    def __init__(self, relay_url: str, keys: BotKeys):
        self.relay_url = relay_url
        self.keys = keys
        self.ws: websocket.WebSocket | None = None
        self.peer_x25519: dict[str, str] = {}

    def connect(self, nick: str | None = None) -> None:
        sslopt: dict[str, Any] = {}
        if self.relay_url.startswith("wss://"):
            sslopt = {"cert_reqs": ssl.CERT_NONE}
        self.ws = websocket.create_connection(self.relay_url, sslopt=sslopt, timeout=60)
        nk = nick if nick else ("@" + self.keys.ed25519_public_hex[:10])
        reg = {
            "type": "register",
            "publicKey": self.keys.ed25519_public_hex,
            "nick": nk[:64],
            "x25519": self.keys.x25519_public_b64,
        }
        self.ws.send(json.dumps(reg))
        raw = self.ws.recv()
        if not isinstance(raw, str):
            raw = raw.decode("utf-8")
        msg = json.loads(raw)
        if msg.get("type") != "registered":
            raise RuntimeError(f"register failed: {msg}")

    def close(self) -> None:
        if self.ws:
            try:
                self.ws.close()
            except Exception:
                pass
            self.ws = None

    def claim(self, claim_id: str) -> dict[str, Any]:
        assert self.ws
        # claimCode: только нормализация пробелов/дефисов; 32 hex — lower.
        cid = claim_id.strip()
        if len(cid) == 32 and all(c in "0123456789abcdefABCDEF" for c in cid):
            cid = cid.lower()
        self.ws.send(json.dumps({"type": "bot_claim", "claimId": cid}))
        for _ in range(2048):
            raw = self.ws.recv()
            if not isinstance(raw, str):
                raw = raw.decode("utf-8")
            msg = json.loads(raw)
            t = msg.get("type")
            if t in _SKIP_UNTIL_BOT_CLAIM_ACK:
                if t == "presence":
                    pk = (msg.get("publicKey") or "").lower()
                    x = msg.get("x25519")
                    if pk and isinstance(x, str) and x:
                        self.peer_x25519[pk] = x
                continue
            if t == "bot_claim_ack":
                return msg
            if t == "error":
                return msg
            raise RuntimeError(f"Неожиданное сообщение relay при claim: {msg!r}")
        raise RuntimeError("Слишком много сообщений до bot_claim_ack — проверьте relay/сеть.")

    def recv_loop(
        self,
        on_dm: Callable[[str, str], None],
        log: Callable[[str], None] | None = None,
    ) -> None:
        assert self.ws
        L = log or (lambda s: None)
        while True:
            raw = self.ws.recv()
            if not isinstance(raw, str):
                raw = raw.decode("utf-8")
            msg = json.loads(raw)
            t = msg.get("type")
            if t == "presence":
                pk = (msg.get("publicKey") or "").lower()
                x = msg.get("x25519")
                if pk and isinstance(x, str) and x:
                    self.peer_x25519[pk] = x
                continue
            if t == "packet":
                self._handle_packet(msg, on_dm, L)
                continue
            if t in (
                "pong",
                "registered",
                "search_result",
                "delivery_status",
                "channel_dir_snapshot",
                "bot_dir_snapshot",
                "account_sync_blob",
            ):
                continue
            L(f"[relay] {t}")

    def _handle_packet(
        self,
        msg: dict[str, Any],
        on_dm: Callable[[str, str], None],
        L: Callable[[str], None],
    ) -> None:
        assert self.ws
        from_id = (msg.get("from") or "").lower()
        data_b64 = msg.get("data")
        relay_msg_id = msg.get("relayMsgId")
        if not from_id or not data_b64:
            return
        try:
            inner = json.loads(base64.b64decode(data_b64).decode("utf-8"))
        except Exception as e:
            L(f"[packet] bad inner: {e}")
            return
        if inner.get("t") != "msg":
            return
        p = inner.get("p")
        if not isinstance(p, dict):
            return
        try:
            text = decrypt_dm(
                self.keys,
                str(p["epk"]),
                str(p["n"]),
                str(p["ct"]),
                str(p["mac"]),
            )
        except Exception as e:
            L(f"[decrypt] {e}")
            return
        if relay_msg_id:
            self.ws.send(json.dumps({"type": "relay_ack", "msgId": relay_msg_id}))
        on_dm(from_id, text)

    def send_dm(self, to_ed25519_hex: str, text: str) -> None:
        assert self.ws
        to = to_ed25519_hex.lower().strip()
        x = self.peer_x25519.get(to)
        if not x:
            raise RuntimeError(f"No x25519 for peer {to[:8]}… — wait for presence or search bot on relay.")
        raw = build_msg_packet(self.keys, to, x, text)
        out = {
            "type": "packet",
            "to": to,
            "data": base64.b64encode(raw).decode("ascii"),
            "msgId": str(uuid.uuid4()),
        }
        self.ws.send(json.dumps(out))
