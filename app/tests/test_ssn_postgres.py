"""SSN vault against a real Postgres. Skipped unless SSN_TEST_PG_DSN points
at a throwaway superuser connection, for example
SSN_TEST_PG_DSN="host=/tmp port=5432 user=postgres dbname=postgres".

Sets up roles the way db-logins does, runs every migration as migrator,
runs afterMigrate, then checks grants and the store. Fake 9xx SSNs only."""

import os
import pathlib
import uuid

import psycopg
import pytest

from demo_app.db import DbSettings
from demo_app.ssn import FakeEncryptor, PostgresVaultStore, SsnTokenService

DSN = os.environ.get("SSN_TEST_PG_DSN")
pytestmark = pytest.mark.skipif(not DSN, reason="SSN_TEST_PG_DSN not set")
MIGRATIONS = pathlib.Path(__file__).resolve().parents[2] / "db" / "migrations"
PEPPER = bytes(range(32))


def _versioned():
    files = [p for p in MIGRATIONS.glob("V*__*.sql")]
    return sorted(files, key=lambda p: int(p.name[1:].split("__")[0]))


@pytest.fixture(scope="module")
def db():
    name = "ssn_" + uuid.uuid4().hex[:8]
    admin = psycopg.connect(DSN, autocommit=True)
    admin.execute(f'CREATE DATABASE "{name}"')
    for role in ("app_user", "migrator"):
        admin.execute(f"DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='{role}') THEN CREATE ROLE {role} LOGIN; END IF; END $$")
    admin.execute("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ssn_vault_rw') THEN CREATE ROLE ssn_vault_rw NOLOGIN; END IF; END $$")
    admin.execute("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ssn_svc') THEN CREATE ROLE ssn_svc LOGIN; END IF; END $$")
    admin.execute("GRANT ssn_vault_rw TO ssn_svc")
    base = psycopg.conninfo.conninfo_to_dict(DSN)
    with psycopg.connect(**{**base, "dbname": name}, autocommit=True) as c:
        # The parts of db-logins.sql that matter here.
        c.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        c.execute("GRANT USAGE, CREATE ON SCHEMA public TO migrator")
        c.execute("GRANT USAGE ON SCHEMA public TO app_user, ssn_vault_rw")
        c.execute("ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user")
        c.execute("ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_user")
    with psycopg.connect(**{**base, "dbname": name, "user": "migrator"}, autocommit=True) as c:
        for f in _versioned():
            c.execute(f.read_text())
        c.execute((MIGRATIONS / "afterMigrate.sql").read_text())
    with psycopg.connect(**{**base, "dbname": name}, autocommit=True) as c:
        # db-logins re-runs its broad grant on every deploy, then the revoke.
        c.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user")
        c.execute("REVOKE ALL ON public.ssn_vault FROM app_user")
        c.execute("REVOKE ALL ON SEQUENCE public.ssn_vault_id_seq FROM app_user")
    yield {**base, "dbname": name}
    admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
    admin.close()


def _svc(conninfo):
    s = DbSettings(host=conninfo.get("host", "localhost"), port=int(conninfo.get("port", 5432)),
                   dbname=conninfo["dbname"], user="ssn_svc", password="", sslmode="disable")
    return SsnTokenService(PostgresVaultStore(s), FakeEncryptor(), PEPPER)


def test_app_user_cannot_read_vault(db):
    with psycopg.connect(**{**db, "user": "app_user"}) as c:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            c.execute("SELECT 1 FROM ssn_vault")
    with psycopg.connect(**{**db, "user": "app_user"}) as c:
        c.execute("SELECT 1 FROM claimant")  # still has its normal tables


def test_vault_role_cannot_update_or_delete(db):
    with psycopg.connect(**{**db, "user": "ssn_svc"}) as c:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            c.execute("DELETE FROM ssn_vault")


def test_tokenize_and_reveal_against_postgres(db):
    svc = _svc(db)
    a = svc.tokenize("900-00-0001")
    assert svc.tokenize("900000001").ssn_token == a.ssn_token
    # The token is accepted by claimant's CHECK.
    with psycopg.connect(**db) as c:
        c.execute("INSERT INTO claimant (ssn_token, ssn_hmac, first_name, last_name) VALUES (%s, %s, 'Test', 'Person')",
                  (a.ssn_token, a.ssn_hmac))
        stored = c.execute("SELECT ssn_token, ssn_hmac, ssn_ciphertext, key_id FROM ssn_vault").fetchall()
        assert all(b"900000001" not in bytes(v if isinstance(v, (bytes, memoryview)) else str(v).encode())
                   for row in stored for v in row)
    assert svc.reveal(a.ssn_token, actor="staff-1", reason="identity check") == "900000001"
    with psycopg.connect(**db) as c:
        rows = c.execute("SELECT actor, action, reason, record_type, after_data::text FROM audit_event").fetchall()
    assert len(rows) == 1
    assert rows[0][:4] == ("staff-1", "ssn.reveal", "identity check", "ssn_vault")
    assert "900000001" not in rows[0][4]


def test_raw_ssn_rejected_as_token(db):
    with psycopg.connect(**db) as c:
        with pytest.raises(psycopg.errors.CheckViolation):
            c.execute("INSERT INTO ssn_vault (ssn_token, ssn_hmac, ssn_ciphertext, key_id) VALUES ('900-00-0001', %s, 'x', 'k')",
                      (bytes(32),))
