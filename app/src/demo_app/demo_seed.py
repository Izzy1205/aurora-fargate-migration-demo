"""Testing only: seed one fake claimant and one open claim.

The reveal ticket flow needs a claimant row and an open claim, and nothing
in the app creates those yet (claimant sign-up isn't built). This gives
testing a way to make them from a token /ssn/tokenize already returned, so
the whole flow can be tried with curl:

    tokenize -> seed claim -> issue ticket -> reveal -> refresh

Where it runs:
- Only when the environment name prefix ends in "-testing". On ECS the
  prefix comes from the task family in the Fargate task metadata
  (<name_prefix>-app, set by modules/ecs), and nothing else: the
  SSN_NAME_PREFIX override is ignored when the metadata endpoint is there,
  so an env var can't turn this on in stage or production.
- Off the metadata endpoint (a laptop or CI), SSN_NAME_PREFIX decides.
- If the prefix can't be worked out, it's off. Every "off" answer is the
  same 404 FastAPI gives for a route that doesn't exist, before the body
  is even read.

What it touches:
- The app's own login (app_user), which already has row access to
  employer, claimant, claim and audit_event. No new grants, and nothing on
  ssn_vault or ssn_ticket, which app_user can't reach anyway.
- One fake employer (FEIN 000000000, which the IRS never issues), the
  claimant for the given token, and one open claim. Re-running with the
  same token reuses all three.
- One audit_event row per call that creates something, action
  demo.seed_claim. It never holds the token or the HMAC.
"""

from __future__ import annotations

import os
import re
import threading
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Protocol

import psycopg

from .db import DbSettings
from .ssn.config import METADATA_ENV, NAME_PREFIX_ENV, fetch_task_metadata, resolve_name_prefix
from .ssn.store import OPEN_CLAIM_STATUSES

TESTING_SUFFIX = "-testing"

TOKEN_RE = re.compile(r"^tok_[A-Za-z0-9_-]{32}$")  # same shape as ssn_vault's CHECK
HMAC_RE = re.compile(r"^[0-9a-fA-F]{64}$")  # 32 bytes, hex, as /ssn/tokenize returns it

# Obviously fake. 00 is not an IRS campus prefix, so 000000000 is never a
# real FEIN. example.invalid can never resolve.
FAKE_EMPLOYER_FEIN = "000000000"
FAKE_EMPLOYER_NAME = "Demo Test Employer (FAKE)"
FAKE_FIRST_NAME = "Test"
FAKE_LAST_NAME = "Claimant (FAKE)"
FAKE_EMAIL = "test.claimant@example.invalid"
SEED_CLAIM_TYPE = "medical"
SEED_CLAIM_STATUS = "submitted"
SEED_ACTION = "demo.seed_claim"


def is_testing_prefix(prefix: str | None) -> bool:
    return bool(prefix) and prefix.endswith(TESTING_SUFFIX) and len(prefix) > len(TESTING_SUFFIX)


def environment_prefix(
    env: Mapping[str, str],
    metadata: Callable[[str], dict[str, Any]] = fetch_task_metadata,
) -> str:
    """The name prefix, with the ECS task family winning over any env var.
    Raises on anything it can't work out (the caller fails closed)."""
    if env.get(METADATA_ENV, "").strip():
        # On ECS: ignore SSN_NAME_PREFIX, the task family decides.
        env = {k: v for k, v in env.items() if k != NAME_PREFIX_ENV}
    prefix, _ = resolve_name_prefix(env, metadata)
    return prefix


class TestingOnlyGuard:
    """True only in a "-testing" environment. Any error means False.

    A good answer is cached for the life of the process, since a task never
    moves environments. A failure isn't cached, so a slow metadata endpoint
    at startup doesn't turn it off for good, but it still says no."""

    __test__ = False  # not a pytest test class

    def __init__(
        self,
        env: Mapping[str, str] | None = None,
        metadata: Callable[[str], dict[str, Any]] = fetch_task_metadata,
    ) -> None:
        self._env = env
        self._metadata = metadata
        self._lock = threading.Lock()
        self._prefix: str | None = None

    def allowed(self) -> bool:
        with self._lock:
            if self._prefix is None:
                try:
                    self._prefix = environment_prefix(os.environ if self._env is None else self._env, self._metadata)
                except Exception:  # noqa: BLE001 - fail closed on anything
                    return False
            return is_testing_prefix(self._prefix)


class SeedInputError(ValueError):
    """Bad token or HMAC. The message never echoes the input."""


class SeedConflict(RuntimeError):
    """The token or HMAC already belongs to a different claimant."""


@dataclass(frozen=True)
class SeedResult:
    claimant_id: int
    claim_id: int
    claim_status: str
    employer_id: int
    created: bool


def check_seed_input(ssn_token: Any, ssn_hmac: Any) -> tuple[str, bytes]:
    if not isinstance(ssn_token, str) or not TOKEN_RE.fullmatch(ssn_token):
        raise SeedInputError("ssn_token must be a tok_ value from /ssn/tokenize")
    if not isinstance(ssn_hmac, str) or not HMAC_RE.fullmatch(ssn_hmac):
        raise SeedInputError("ssn_hmac must be the 64 hex characters from /ssn/tokenize")
    return ssn_token, bytes.fromhex(ssn_hmac)


class SeedStore(Protocol):
    def seed_claim(self, ssn_token: str, ssn_hmac: bytes, actor: str) -> SeedResult: ...


class PostgresSeedStore:
    """Uses the app's own login (DB_USER, app_user). One transaction."""

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
            application_name="migdemo-app-seed",
        )

    def seed_claim(self, ssn_token: str, ssn_hmac: bytes, actor: str) -> SeedResult:
        with self._connect() as conn, conn.transaction():
            return seed_claim_sql(conn, ssn_token, ssn_hmac, actor)


def seed_claim_sql(conn: psycopg.Connection[Any], ssn_token: str, ssn_hmac: bytes, actor: str) -> SeedResult:
    """Runs inside the caller's transaction."""
    created = False

    r = conn.execute(
        "INSERT INTO employer (fein, legal_name) VALUES (%s, %s) ON CONFLICT (fein) DO NOTHING RETURNING id",
        (FAKE_EMPLOYER_FEIN, FAKE_EMPLOYER_NAME),
    ).fetchone()
    if r is None:
        r = conn.execute("SELECT id FROM employer WHERE fein = %s", (FAKE_EMPLOYER_FEIN,)).fetchone()
    employer_id = int(r[0])

    # DO NOTHING on either unique column. If the token is new but the HMAC
    # is someone else's, nothing is added and the lookup below finds no row.
    r = conn.execute(
        """
        INSERT INTO claimant (ssn_token, ssn_hmac, first_name, last_name, email)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT DO NOTHING
        RETURNING id
        """,
        (ssn_token, ssn_hmac, FAKE_FIRST_NAME, FAKE_LAST_NAME, FAKE_EMAIL),
    ).fetchone()
    created = created or r is not None

    # Lock the claimant so two seeds at once can't both add a claim.
    r = conn.execute("SELECT id, ssn_hmac FROM claimant WHERE ssn_token = %s FOR UPDATE", (ssn_token,)).fetchone()
    if r is None or bytes(r[1]) != ssn_hmac:
        raise SeedConflict("token and HMAC don't match an existing claimant")
    claimant_id = int(r[0])

    r = conn.execute(
        "SELECT id, status FROM claim WHERE claimant_id = %s AND status = ANY(%s) ORDER BY id LIMIT 1",
        (claimant_id, list(OPEN_CLAIM_STATUSES)),
    ).fetchone()
    if r is None:
        r = conn.execute(
            "INSERT INTO claim (claimant_id, employer_id, claim_type, status) VALUES (%s, %s, %s, %s) RETURNING id, status",
            (claimant_id, employer_id, SEED_CLAIM_TYPE, SEED_CLAIM_STATUS),
        ).fetchone()
        created = True
    claim_id, status = int(r[0]), str(r[1])

    if created:
        # Ids only. Never the token or the HMAC.
        conn.execute(
            """
            INSERT INTO audit_event (actor, action, record_type, record_id, after_data, reason)
            VALUES (%s, %s, 'claim', %s, jsonb_build_object('claimant_id', %s::bigint, 'employer_id', %s::bigint,
                    'status', %s::text, 'fake', true), 'testing seed')
            """,
            (actor, SEED_ACTION, claim_id, claimant_id, employer_id, status),
        )
    return SeedResult(claimant_id, claim_id, status, employer_id, created)
