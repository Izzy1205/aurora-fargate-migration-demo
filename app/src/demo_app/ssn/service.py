"""Tokenize, reveal tickets, reveal and refresh.

The permanent ssn_token on claimant can't reveal anything by itself. To
see an SSN, staff get a reveal ticket for one open claim. The ticket
works once, lives while the claim is open and never more than 72 hours,
and can be swapped for a fresh one only after the actor signs in again.
Issue, reveal and refresh each write their own audit_event row.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import re
import secrets
from dataclasses import dataclass

from .crypto import Encryptor
from .store import AuditEntry, TicketRejected, TicketRow, VaultRow, VaultStore

log = logging.getLogger("demo_app.ssn")

# Nine digits, with or without the usual dashes or spaces. Format only: this
# service doesn't judge whether a number was ever issued.
_SSN_INPUT_RE = re.compile(r"^\s*(\d{3})[- ]?(\d{2})[- ]?(\d{4})\s*$")
TOKEN_RE = re.compile(r"^tok_[A-Za-z0-9_-]{32}$")
TICKET_RE = re.compile(r"^rtk_[A-Za-z0-9_-]{32}$")
REVEAL_ACTION = "ssn.reveal"
ISSUE_ACTION = "ssn.ticket_issue"
REFRESH_ACTION = "ssn.ticket_refresh"
# The hard cap. V11's CHECK refuses anything longer, whatever this says.
TICKET_TTL_HOURS = 72
MIN_PEPPER_BYTES = 32


class InvalidSsn(ValueError):
    """Deliberately carries no detail, so the value can't leak via str(exc)."""

    def __init__(self) -> None:
        super().__init__("invalid SSN format")


class RevealNotAllowed(ValueError):
    pass


class TokenNotFound(LookupError):
    pass


class TicketNotValid(LookupError):
    """Unknown, expired, used, revoked, or its claim is closed. One error
    for all of them, so a caller can't probe which."""


class NoOpenClaim(LookupError):
    """Token unknown, or the claim is missing, closed, or not this SSN's."""


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


def new_ticket() -> str:
    # Same size as a token, different prefix. Random, carries nothing.
    return "rtk_" + secrets.token_urlsafe(24)


def load_pepper_from_env(var: str = "SSN_HMAC_KEY") -> bytes:
    """Hex string from an env var. Local runs and tests only; in AWS the
    pepper is read from Secrets Manager (see config.py). Never in code."""
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

    @staticmethod
    def _require(actor: str, reason: str) -> tuple[str, str]:
        actor = (actor or "").strip()
        reason = (reason or "").strip()
        if not actor:
            raise RevealNotAllowed("actor is required")
        if not reason:
            raise RevealNotAllowed("reason is required")
        return actor, reason

    def issue_ticket(self, ssn_token: str, claim_id: int, actor: str, reason: str) -> TicketRow:
        actor, reason = self._require(actor, reason)
        if not TOKEN_RE.match(ssn_token or "") or claim_id <= 0:
            raise NoOpenClaim()

        def audit(t: TicketRow) -> AuditEntry:
            # The ticket is a bearer value, so the audit row names it by id
            # only. app_user can read audit_event and must not find live
            # tickets there.
            return AuditEntry(
                actor=actor,
                action=ISSUE_ACTION,
                record_type="ssn_ticket",
                record_id=t.id,
                reason=reason,
                after_data={
                    "ssn_token": ssn_token,
                    "claim_id": t.claim_id,
                    "expires_at": t.expires_at.isoformat(),
                },
            )

        row = self._store.issue_ticket(ssn_token, claim_id, new_ticket(), TICKET_TTL_HOURS, actor, audit)
        if row is None:
            raise NoOpenClaim()
        log.info("ssn ticket issued")
        return row

    def reveal(self, ticket: str, actor: str, reason: str) -> tuple[str, VaultRow, TicketRow]:
        """Returns (ssn digits, vault row, the ticket just burned)."""
        actor, reason = self._require(actor, reason)
        if not TICKET_RE.match(ticket or ""):
            # A permanent tok_ token lands here too: it can't reveal.
            log.info("ssn reveal refused reason=malformed")
            raise TicketNotValid()

        def audit(row: VaultRow, t: TicketRow) -> AuditEntry:
            # Who, why, which SSN token and which ticket (by id). Never the
            # SSN, never the ticket value.
            return AuditEntry(
                actor=actor,
                action=REVEAL_ACTION,
                record_type="ssn_vault",
                record_id=row.id,
                reason=reason,
                after_data={"ssn_token": row.ssn_token, "ticket_id": t.id, "claim_id": t.claim_id},
            )

        def decrypt(row: VaultRow) -> str:
            return self._enc.decrypt(row.ssn_ciphertext, _context(row.ssn_token)).decode("ascii")

        try:
            result = self._store.reveal_ticket(ticket, audit, decrypt)
        except TicketRejected as exc:
            # The category only: no ticket, no actor.
            log.info("ssn reveal refused reason=%s", exc.category)
            raise TicketNotValid() from exc
        log.info("ssn revealed")
        return result

    def refresh(self, ticket: str, actor: str, reason: str) -> TicketRow:
        """Swap a ticket for a new one. The caller must have checked the
        re-authentication first (see reauth.py). The old ticket must be
        unused, unrevoked, issued to this actor, and its claim still open.
        An expired one is fine: that's what refresh is for."""
        actor, reason = self._require(actor, reason)
        if not TICKET_RE.match(ticket or ""):
            log.info("ssn ticket refresh refused reason=malformed")
            raise TicketNotValid()

        def audit(old: TicketRow, new: TicketRow) -> AuditEntry:
            return AuditEntry(
                actor=actor,
                action=REFRESH_ACTION,
                record_type="ssn_ticket",
                record_id=new.id,
                reason=reason,
                after_data={
                    "replaces_ticket_id": old.id,
                    "claim_id": new.claim_id,
                    "expires_at": new.expires_at.isoformat(),
                },
            )

        try:
            row = self._store.refresh_ticket(ticket, actor, new_ticket(), TICKET_TTL_HOURS, audit)
        except TicketRejected as exc:
            log.info("ssn ticket refresh refused reason=%s", exc.category)
            raise TicketNotValid() from exc
        log.info("ssn ticket refreshed")
        return row
