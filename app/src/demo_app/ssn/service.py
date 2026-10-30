"""Tokenize and reveal."""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import re
import secrets
from dataclasses import dataclass

from .crypto import Encryptor
from .store import AuditEntry, VaultRow, VaultStore

log = logging.getLogger("demo_app.ssn")

# Nine digits, with or without the usual dashes or spaces. Format only: this
# service doesn't judge whether a number was ever issued.
_SSN_INPUT_RE = re.compile(r"^\s*(\d{3})[- ]?(\d{2})[- ]?(\d{4})\s*$")
TOKEN_RE = re.compile(r"^tok_[A-Za-z0-9_-]{32}$")
REVEAL_ACTION = "ssn.reveal"
MIN_PEPPER_BYTES = 32


class InvalidSsn(ValueError):
    """Deliberately carries no detail, so the value can't leak via str(exc)."""

    def __init__(self) -> None:
        super().__init__("invalid SSN format")


class RevealNotAllowed(ValueError):
    pass


class TokenNotFound(LookupError):
    pass


@dataclass(frozen=True)
class TokenizeResult:
    ssn_token: str
    ssn_hmac: bytes
    created: bool


def normalize_ssn(raw: str) -> str:
    m = _SSN_INPUT_RE.match(raw or "")
    if not m:
        raise InvalidSsn()
    return "".join(m.groups())


def hmac_ssn(pepper: bytes, normalized: str) -> bytes:
    """HMAC-SHA256 of the nine digits, no dashes. The wage loader must use
    the same key and the same normalization so wage_quarter matches."""
    return hmac.new(pepper, normalized.encode("ascii"), hashlib.sha256).digest()


def new_token() -> str:
    # 24 random bytes, 32 URL-safe characters. Carries nothing about the SSN.
    return "tok_" + secrets.token_urlsafe(24)


def load_pepper_from_env(var: str = "SSN_HMAC_KEY") -> bytes:
    """Hex string, injected by ECS from Secrets Manager. Never in code."""
    value = os.environ.get(var, "")
    try:
        pepper = bytes.fromhex(value)
    except ValueError as exc:
        raise RuntimeError(f"{var} must be hex") from exc
    if len(pepper) < MIN_PEPPER_BYTES:
        raise RuntimeError(f"{var} must be at least {MIN_PEPPER_BYTES} bytes")
    return pepper


def _context(token: str) -> dict[str, str]:
    return {"purpose": "ssn", "token": token}


class SsnTokenService:
    def __init__(self, store: VaultStore, encryptor: Encryptor, pepper: bytes) -> None:
        if len(pepper) < MIN_PEPPER_BYTES:
            raise ValueError("pepper too short")
        self._store = store
        self._enc = encryptor
        self._pepper = pepper

    def tokenize(self, raw_ssn: str) -> TokenizeResult:
        digits = normalize_ssn(raw_ssn)
        digest = hmac_ssn(self._pepper, digits)
        existing = self._store.find_by_hmac(digest)
        if existing is not None:
            return TokenizeResult(existing.ssn_token, existing.ssn_hmac, created=False)

        token = new_token()
        blob = self._enc.encrypt(digits.encode("ascii"), _context(token))
        row = self._store.insert(
            VaultRow(id=0, ssn_token=token, ssn_hmac=digest, ssn_ciphertext=blob, key_id=self._enc.key_id)
        )
        created = row.ssn_token == token
        # No token or SSN in logs; the vault row and audit_event are the record.
        log.info("ssn tokenized created=%s", created)
        return TokenizeResult(row.ssn_token, row.ssn_hmac, created=created)

    def reveal(self, token: str, actor: str, reason: str) -> str:
        actor = (actor or "").strip()
        reason = (reason or "").strip()
        if not actor:
            raise RevealNotAllowed("actor is required")
        if not reason:
            raise RevealNotAllowed("reason is required")
        if not TOKEN_RE.match(token or ""):
            raise TokenNotFound()

        def audit(row: VaultRow) -> AuditEntry:
            # Who, why, which token. Never the SSN.
            return AuditEntry(
                actor=actor,
                action=REVEAL_ACTION,
                record_type="ssn_vault",
                record_id=row.id,
                reason=reason,
                after_data={"ssn_token": row.ssn_token},
            )

        def decrypt(row: VaultRow) -> str:
            return self._enc.decrypt(row.ssn_ciphertext, _context(row.ssn_token)).decode("ascii")

        value = self._store.reveal(token, audit, decrypt)
        if value is None:
            raise TokenNotFound()
        # The audit_event row holds who, why, and which token.
        log.info("ssn revealed")
        return value
