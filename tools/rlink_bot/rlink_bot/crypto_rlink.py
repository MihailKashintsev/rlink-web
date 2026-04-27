"""X25519 + ChaCha20-Poly1305 compatible with Rlink Flutter CryptoService."""

from __future__ import annotations

import base64
import json
import os
import time
import uuid
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, PublicFormat, NoEncryption


def _b64e(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _b64d(s: str) -> bytes:
    return base64.b64decode(s, validate=True)


def _hexe(b: bytes) -> str:
    return b.hex()


def _hexd(s: str) -> bytes:
    return bytes.fromhex(s)


def rid8(pub_hex: str) -> str:
    k = pub_hex.strip().lower()
    return k[:8] if len(k) >= 8 else k


@dataclass
class BotKeys:
    ed25519_private: ed25519.Ed25519PrivateKey
    x25519_private: x25519.X25519PrivateKey

    @property
    def ed25519_public_hex(self) -> str:
        pub = self.ed25519_private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return _hexe(pub)

    @property
    def x25519_public_b64(self) -> str:
        pub = self.x25519_private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return _b64e(pub)

    def to_json_dict(self) -> dict[str, str]:
        ed_pr = self.ed25519_private.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
        x_pr = self.x25519_private.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
        return {
            "ed25519_private_hex": _hexe(ed_pr),
            "ed25519_public_hex": self.ed25519_public_hex,
            "x25519_private_b64": _b64e(x_pr),
            "x25519_public_b64": self.x25519_public_b64,
        }

    @staticmethod
    def generate() -> "BotKeys":
        return BotKeys(
            ed25519_private=ed25519.Ed25519PrivateKey.generate(),
            x25519_private=x25519.X25519PrivateKey.generate(),
        )

    @staticmethod
    def from_json_dict(d: dict[str, Any]) -> "BotKeys":
        ed_pr = _hexd(str(d["ed25519_private_hex"]))
        x_pr = _b64d(str(d["x25519_private_b64"]))
        return BotKeys(
            ed25519_private=ed25519.Ed25519PrivateKey.from_private_bytes(ed_pr),
            x25519_private=x25519.X25519PrivateKey.from_private_bytes(x_pr),
        )


def decrypt_dm(
    keys: BotKeys,
    epk_b64: str,
    nonce_b64: str,
    ct_b64: str,
    mac_b64: str,
) -> str:
    """Decrypt payload from EncryptedMessage fields (Flutter gossip type msg)."""
    epk = x25519.X25519PublicKey.from_public_bytes(_b64d(epk_b64))
    shared = keys.x25519_private.exchange(epk)
    key = shared[:32]
    nonce = _b64d(nonce_b64)
    ct = _b64d(ct_b64)
    tag = _b64d(mac_b64)
    cipher = ChaCha20Poly1305(key)
    plain = cipher.decrypt(nonce, ct + tag, None)
    return plain.decode("utf-8")


def encrypt_dm(
    keys: BotKeys,
    recipient_ed25519_hex: str,
    recipient_x25519_b64: str,
    plaintext: str,
) -> dict[str, Any]:
    """Build gossip inner payload `p` for type msg (before wrapping in packet JSON)."""
    recip_x = x25519.X25519PublicKey.from_public_bytes(_b64d(recipient_x25519_b64))
    ephemeral = x25519.X25519PrivateKey.generate()
    shared = ephemeral.exchange(recip_x)
    key = shared[:32]
    nonce = os.urandom(12)
    cipher = ChaCha20Poly1305(key)
    body = plaintext.encode("utf-8")
    ct_tag = cipher.encrypt(nonce, body, None)
    tag = ct_tag[-16:]
    ct = ct_tag[:-16]
    epk_raw = ephemeral.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    sender_hex = keys.ed25519_public_hex
    return {
        "from": sender_hex,
        "epk": _b64e(epk_raw),
        "n": _b64e(nonce),
        "ct": _b64e(ct),
        "mac": _b64e(tag),
        "r": rid8(recipient_ed25519_hex),
    }


def build_msg_packet(
    keys: BotKeys,
    recipient_ed25519_hex: str,
    recipient_x25519_b64: str,
    plaintext: str,
    msg_id: str | None = None,
) -> bytes:
    mid = msg_id or str(uuid.uuid4())
    p = encrypt_dm(keys, recipient_ed25519_hex, recipient_x25519_b64, plaintext)
    pkt = {
        "id": mid,
        "t": "msg",
        "ttl": 7,
        "ts": int(time.time() * 1000),
        "p": p,
    }
    return json.dumps(pkt, separators=(",", ":")).encode("utf-8")
