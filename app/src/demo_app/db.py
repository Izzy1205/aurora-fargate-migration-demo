"""Database access. One short-lived connection per request.

No connection pool on purpose: with no open connections, Aurora Serverless v2
can pause at 0 ACUs between demo sessions. A real service would use a pool
or RDS Proxy.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import Any

import psycopg
from psycopg import sql
from psycopg.rows import dict_row

from .presenters import order_columns_to_select


@dataclass(frozen=True)
class DbSettings:
    host: str
    port: int
    dbname: str
    user: str
    password: str = field(repr=False)  # never printed
    sslmode: str = "require"
    connect_timeout: int = 20

    @classmethod
    def from_env(cls) -> "DbSettings":
        # DB_USER and DB_PASSWORD are injected by ECS from Secrets Manager.
        return cls(
            host=os.environ["DB_HOST"],
            port=int(os.environ.get("DB_PORT", "5432")),
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            sslmode=os.environ.get("DB_SSLMODE", "require"),
            # Long enough for a paused Aurora cluster to resume.
            connect_timeout=int(os.environ.get("DB_CONNECT_TIMEOUT", "20")),
        )


class Repository:
    """Read-only queries the app needs."""

    _columns_ttl_seconds = 30.0

    def __init__(self, settings: DbSettings) -> None:
        self._settings = settings
        self._order_columns: set[str] | None = None
        self._order_columns_at = 0.0

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
            application_name="migdemo-app",
            row_factory=dict_row,
        )

    def ping(self) -> None:
        with self._connect() as conn:
            conn.execute("SELECT 1")

    def _existing_order_columns(self, conn: psycopg.Connection[Any]) -> set[str]:
        # Cached briefly so a new column shows up within seconds of the
        # migration, without a restart.
        now = time.monotonic()
        if self._order_columns is None or now - self._order_columns_at > self._columns_ttl_seconds:
            rows = conn.execute(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = current_schema() AND table_name = 'orders'
                """
            ).fetchall()
            self._order_columns = {r["column_name"] for r in rows}
            self._order_columns_at = now
        return self._order_columns

    def has_priority_column(self) -> bool:
        with self._connect() as conn:
            return "priority" in self._existing_order_columns(conn)

    def list_orders(self, limit: int) -> list[dict[str, Any]]:
        with self._connect() as conn:
            cols = order_columns_to_select(self._existing_order_columns(conn))
            # Column names come from a fixed allow-list and are quoted as
            # identifiers; the limit is a bound parameter.
            query = sql.SQL("SELECT {cols} FROM orders ORDER BY id DESC LIMIT %s").format(
                cols=sql.SQL(", ").join(sql.Identifier(c) for c in cols)
            )
            return conn.execute(query, (limit,)).fetchall()

    def list_customers(self, limit: int) -> list[dict[str, Any]]:
        with self._connect() as conn:
            return conn.execute(
                "SELECT id, full_name, email, created_at FROM customers ORDER BY id LIMIT %s",
                (limit,),
            ).fetchall()
