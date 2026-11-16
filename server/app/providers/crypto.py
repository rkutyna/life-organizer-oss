"""Encryption of connected accounts' credentials at rest.

The key is derived from `ORGANIZER_SECRET_KEY` (environment only, never the database), so a
copy of the database alone holds no usable password or token. Fernet: AES-128-CBC with an
HMAC-SHA256, authenticated, with a timestamp.
"""

import base64
import json
from typing import Any

from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MIN_KEY_LENGTH = 32
_INFO = b"organizer provider credentials v1"


class CryptoUnavailable(Exception):
    """ORGANIZER_SECRET_KEY is missing or too short (HTTP 503)."""


class CredentialsUnreadable(Exception):
    """Stored credentials do not decrypt, e.g. the key was changed."""


def _fernet(secret_key: str) -> Fernet:
    if len(secret_key) < MIN_KEY_LENGTH:
        raise CryptoUnavailable(
            f"ORGANIZER_SECRET_KEY must be set to at least {MIN_KEY_LENGTH} characters "
            "before accounts can be connected (openssl rand -base64 32)"
        )
    derived = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=_INFO).derive(
        secret_key.encode()
    )
    return Fernet(base64.urlsafe_b64encode(derived))


def encrypt(secret_key: str, data: dict[str, Any]) -> str:
    return _fernet(secret_key).encrypt(json.dumps(data, sort_keys=True).encode()).decode()


def decrypt(secret_key: str, token: str) -> dict[str, Any]:
    try:
        return json.loads(_fernet(secret_key).decrypt(token.encode()))
    except InvalidToken as exc:
        raise CredentialsUnreadable(
            "stored credentials cannot be decrypted (was ORGANIZER_SECRET_KEY changed?); "
            "reconnect the account"
        ) from exc
