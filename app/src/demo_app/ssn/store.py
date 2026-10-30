"""Vault storage. The token service connects with its own login, which is
a member of ssn_vault_rw. app_user has no access to ssn_vault at all."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable, Protocol

import psycopg

from ..db import DbSettings


@dataclass(frozen=True)
class VaultRow:
    id: int
    ssn_token: str
    ssn_hmac: bytes
    ssn_ciphertext: bytes
    key_id: str


@dataclass(frozen=True)
class AuditEntry:
    actor: str
    action: str
    record_type: str
    record_id: int
    reason: str
    after_data: dict[str, Any]


class VaultStore(Protocol):
    def find_by_hmac(self, ssn_hmac: bytes) -> VaultRow | None: ...

    def insert(self, row: VaultRow) -> VaultRow:
        """Insert, or return the existing row if this hmac is already there
        (two requests for the same SSN at once)."""
        ...

    def reveal(
        self, token: str, audit: Callable[[VaultRow], AuditEntry], use: Callable[[VaultRow], str]
    ) -> str | None:
        """In one transaction: read the row, write the audit entry, call
        use() (the decrypt). Returns None if the token is unknown. Any
        failure rolls back and raises, so no SSN is returned unaudited."""
        ...


class PostgresVaultStore:
    def __init__(self, settings: DbSettings) -> None:
        self._settings = settings

    def _connect(self) -> psycopg.Connection[Any]:
        s = self._settings
        return psycopg.connect(
            host=s.host,
            port=s.port,
            dbname=s.dbname,
            user=s.user,
            password=s.password,
            sslmode=s.sslmode,
            connect_timeout=s.connect_timeout,
            application_name="migdemo-ssn-token",
        )

    @staticmethod
    def _row(r: tuple[Any, ...] | None) -> VaultRow | None:
        if r is None:
            return None
        return VaultRow(id=r[0], ssn_token=r[1], ssn_hmac=bytes(r[2]), ssn_ciphertext=bytes(r[3]), key_id=r[4])

    _cols = "id, ssn_token, ssn_hmac, ssn_ciphertext, key_id"

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

    def reveal(
        self, token: str, audit: Callable[[VaultRow], AuditEntry], use: Callable[[VaultRow], str]
    ) -> str | None:
        with self._connect() as conn, conn.transaction():
            row = self._row(
                conn.execute(f"SELECT {self._cols} FROM ssn_vault WHERE ssn_token = %s", (token,)).fetchone()  # nosec B608
            )
            if row is None:
                return None
            entry = audit(row)
            conn.execute(
                """
                INSERT INTO audit_event (actor, action, record_type, record_id, after_data, reason)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (entry.actor, entry.action, entry.record_type, entry.record_id, json.dumps(entry.after_data), entry.reason),
            )
            value = use(row)
        # Only reached once the transaction, audit row included, committed.
        return value
