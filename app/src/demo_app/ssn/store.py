"""Vault storage. The token service connects with its own login, which is
a member of ssn_vault_rw. app_user has no access to ssn_vault or
ssn_ticket at all."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Protocol

import psycopg

from ..db import DbSettings

# Claim statuses (V7) that count as open. denied and withdrawn are closed.
# approved stays open: the claim is still being paid, and staff may need to
# check identity on a payment.
OPEN_CLAIM_STATUSES = ("submitted", "in_review", "approved")

# Why a ticket was refused. Logged as a category only, never the ticket.
REJECT_UNKNOWN = "unknown"
REJECT_EXPIRED = "expired"
REJECT_USED = "used"
REJECT_REVOKED = "revoked"
REJECT_CLAIM_CLOSED = "claim_closed"
REJECT_NOT_HOLDER = "not_holder"


@dataclass(frozen=True)
class VaultRow:
    id: int
    ssn_token: str
    ssn_hmac: bytes
    ssn_ciphertext: bytes
    key_id: str


@dataclass(frozen=True)
class TicketRow:
    id: int
    ticket: str
    vault_id: int
    claim_id: int
    issued_by: str
    issued_at: datetime
    expires_at: datetime


@dataclass(frozen=True)
class AuditEntry:
    actor: str
    action: str
    record_type: str
    record_id: int
    reason: str
    after_data: dict[str, Any]


class TicketRejected(LookupError):
    """The ticket can't be used. category says why, for the log only. The
    caller always gets the same answer, so it can't probe which."""

    def __init__(self, category: str) -> None:
        super().__init__(category)
        self.category = category


class VaultStore(Protocol):
    def find_by_hmac(self, ssn_hmac: bytes) -> VaultRow | None: ...

    def insert(self, row: VaultRow) -> VaultRow:
        """Insert, or return the existing row if this hmac is already there
        (two requests for the same SSN at once)."""
        ...

    def issue_ticket(
        self,
        ssn_token: str,
        claim_id: int,
        ticket: str,
        ttl_hours: int,
        actor: str,
        audit: Callable[[TicketRow], AuditEntry],
    ) -> TicketRow | None:
        """In one transaction: add a ticket for an open claim whose claimant
        has this ssn_token, and write the audit entry. None if the token is
        unknown, or the claim is missing, closed, or someone else's."""
        ...

    def reveal_ticket(
        self,
        ticket: str,
        audit: Callable[[VaultRow, TicketRow], AuditEntry],
        use: Callable[[VaultRow], str],
    ) -> tuple[str, VaultRow, TicketRow]:
        """In one transaction: burn the ticket if it is unused, unrevoked,
        unexpired and its claim is open; write the audit entry; call use()
        (the decrypt). Raises TicketRejected if the ticket can't be used.
        Any failure rolls back, so the ticket isn't burned and no SSN is
        returned unaudited."""
        ...

    def refresh_ticket(
        self,
        ticket: str,
        actor: str,
        new_ticket: str,
        ttl_hours: int,
        audit: Callable[[TicketRow, TicketRow], AuditEntry],
    ) -> TicketRow:
        """In one transaction: revoke the old ticket (unused, unrevoked,
        issued to this actor, claim still open; expired is fine), add the
        new one, link old to new, and write the audit entry. Raises
        TicketRejected otherwise."""
        ...


def _audit_sql(conn: psycopg.Connection[Any], entry: AuditEntry) -> None:
    conn.execute(
        """
        INSERT INTO audit_event (actor, action, record_type, record_id, after_data, reason)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (entry.actor, entry.action, entry.record_type, entry.record_id, json.dumps(entry.after_data), entry.reason),
    )


class PostgresVaultStore:
    """password_provider, if given, is called for every connection. In AWS
    it mints an IAM auth token, so the vault login has no stored password.

    Every time check uses the database clock (now()), so app servers with
    drifting clocks can't stretch a ticket."""

    def __init__(self, settings: DbSettings, password_provider: Callable[[], str] | None = None) -> None:
        self._settings = settings
        self._password = password_provider

    def _connect(self) -> psycopg.Connection[Any]:
        s = self._settings
        return psycopg.connect(
            host=s.host,
            port=s.port,
            dbname=s.dbname,
            user=s.user,
            password=self._password() if self._password else s.password,
            sslmode=s.sslmode,
            connect_timeout=s.connect_timeout,
            application_name="migdemo-ssn-token",
        )

    @staticmethod
    def _row(r: tuple[Any, ...] | None) -> VaultRow | None:
        if r is None:
            return None
        return VaultRow(id=r[0], ssn_token=r[1], ssn_hmac=bytes(r[2]), ssn_ciphertext=bytes(r[3]), key_id=r[4])

    @staticmethod
    def _ticket(r: tuple[Any, ...] | None) -> TicketRow | None:
        if r is None:
            return None
        return TicketRow(id=r[0], ticket=r[1], vault_id=r[2], claim_id=r[3], issued_by=r[4], issued_at=r[5], expires_at=r[6])

    _cols = "id, ssn_token, ssn_hmac, ssn_ciphertext, key_id"
    _tcols = "id, ticket, vault_id, claim_id, issued_by, issued_at, expires_at"
    # The claim is open. %s is the ticket's claim_id column or a value.
    _claim_open = "EXISTS (SELECT 1 FROM claim c WHERE c.id = {claim} AND c.status = ANY(%s))"

    def find_by_hmac(self, ssn_hmac: bytes) -> VaultRow | None:
        with self._connect() as conn:
            r = conn.execute(f"SELECT {self._cols} FROM ssn_vault WHERE ssn_hmac = %s", (ssn_hmac,)).fetchone()  # nosec B608 - fixed column list
            return self._row(r)

    def insert(self, row: VaultRow) -> VaultRow:
        with self._connect() as conn:
            r = conn.execute(
                f"""
                INSERT INTO ssn_vault (ssn_token, ssn_hmac, ssn_ciphertext, key_id)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (ssn_hmac) DO NOTHING
                RETURNING {self._cols}
                """,  # nosec B608 - fixed column list
                (row.ssn_token, row.ssn_hmac, row.ssn_ciphertext, row.key_id),
            ).fetchone()
            if r is None:
                r = conn.execute(
                    f"SELECT {self._cols} FROM ssn_vault WHERE ssn_hmac = %s", (row.ssn_hmac,)  # nosec B608
                ).fetchone()
            found = self._row(r)
            assert found is not None  # nosec B101 - conflict means the row exists
            return found

    def issue_ticket(
        self,
        ssn_token: str,
        claim_id: int,
        ticket: str,
        ttl_hours: int,
        actor: str,
        audit: Callable[[TicketRow], AuditEntry],
    ) -> TicketRow | None:
        with self._connect() as conn, conn.transaction():
            r = conn.execute(
                f"""
                INSERT INTO ssn_ticket (ticket, vault_id, claim_id, issued_by, issued_at, expires_at)
                SELECT %s, v.id, c.id, %s, now(), now() + make_interval(hours => %s)
                FROM ssn_vault v
                JOIN claimant p ON p.ssn_token = v.ssn_token
                JOIN claim c ON c.claimant_id = p.id
                WHERE v.ssn_token = %s AND c.id = %s AND c.status = ANY(%s)
                RETURNING {self._tcols}
                """,  # nosec B608 - fixed column list
                (ticket, actor, ttl_hours, ssn_token, claim_id, list(OPEN_CLAIM_STATUSES)),
            ).fetchone()
            row = self._ticket(r)
            if row is None:
                return None
            _audit_sql(conn, audit(row))
        return row

    def _why_rejected(self, conn: psycopg.Connection[Any], ticket: str, actor: str | None) -> str:
        r = conn.execute(
            f"""
            SELECT t.used_at IS NOT NULL, t.revoked_at IS NOT NULL, t.expires_at <= now(),
                   {self._claim_open.format(claim="t.claim_id")}, t.issued_by = %s
            FROM ssn_ticket t WHERE t.ticket = %s
            """,  # nosec B608 - fixed text
            (list(OPEN_CLAIM_STATUSES), actor or "", ticket),
        ).fetchone()
        if r is None:
            return REJECT_UNKNOWN
        used, revoked, expired, claim_open, holder = r
        if used:
            return REJECT_USED
        if revoked:
            return REJECT_REVOKED
        if not claim_open:
            return REJECT_CLAIM_CLOSED
        if actor is not None and not holder:
            return REJECT_NOT_HOLDER
        return REJECT_EXPIRED if expired else REJECT_UNKNOWN

    def reveal_ticket(
        self,
        ticket: str,
        audit: Callable[[VaultRow, TicketRow], AuditEntry],
        use: Callable[[VaultRow], str],
    ) -> tuple[str, VaultRow, TicketRow]:
        with self._connect() as conn, conn.transaction():
            # The check and the burn are one statement. Two reveals at once
            # queue on the row lock, and the second sees used_at set.
            t = self._ticket(
                conn.execute(
                    f"""
                    UPDATE ssn_ticket t SET used_at = now()
                    WHERE t.ticket = %s AND t.used_at IS NULL AND t.revoked_at IS NULL
                      AND t.expires_at > now() AND {self._claim_open.format(claim="t.claim_id")}
                    RETURNING {self._tcols}
                    """,  # nosec B608 - fixed column list
                    (ticket, list(OPEN_CLAIM_STATUSES)),
                ).fetchone()
            )
            if t is None:
                raise TicketRejected(self._why_rejected(conn, ticket, None))
            row = self._row(
                conn.execute(f"SELECT {self._cols} FROM ssn_vault WHERE id = %s", (t.vault_id,)).fetchone()  # nosec B608
            )
            if row is None:
                raise TicketRejected(REJECT_UNKNOWN)
            _audit_sql(conn, audit(row, t))
            value = use(row)
        # Only reached once the burn and the audit row committed.
        return value, row, t

    def refresh_ticket(
        self,
        ticket: str,
        actor: str,
        new_ticket: str,
        ttl_hours: int,
        audit: Callable[[TicketRow, TicketRow], AuditEntry],
    ) -> TicketRow:
        with self._connect() as conn, conn.transaction():
            old = self._ticket(
                conn.execute(
                    f"""
                    UPDATE ssn_ticket t SET revoked_at = now()
                    WHERE t.ticket = %s AND t.used_at IS NULL AND t.revoked_at IS NULL
                      AND t.issued_by = %s AND {self._claim_open.format(claim="t.claim_id")}
                    RETURNING {self._tcols}
                    """,  # nosec B608 - fixed column list
                    (ticket, actor, list(OPEN_CLAIM_STATUSES)),
                ).fetchone()
            )
            if old is None:
                raise TicketRejected(self._why_rejected(conn, ticket, actor))
            new = self._ticket(
                conn.execute(
                    f"""
                    INSERT INTO ssn_ticket (ticket, vault_id, claim_id, issued_by, issued_at, expires_at)
                    VALUES (%s, %s, %s, %s, now(), now() + make_interval(hours => %s))
                    RETURNING {self._tcols}
                    """,  # nosec B608 - fixed column list
                    (new_ticket, old.vault_id, old.claim_id, actor, ttl_hours),
                ).fetchone()
            )
            assert new is not None  # nosec B101 - INSERT ... RETURNING always returns the row
            conn.execute("UPDATE ssn_ticket SET replaced_by = %s WHERE id = %s", (new.id, old.id))
            _audit_sql(conn, audit(old, new))
        return new
