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
from demo_app.ssn import FakeEncryptor, PostgresVaultStore, SsnTokenService, TicketNotValid

DSN = os.environ.get("SSN_TEST_PG_DSN")
pytestmark = pytest.mark.skipif(not DSN, reason="SSN_TEST_PG_DSN not set")
MIGRATIONS = pathlib.Path(__file__).resolve().parents[2] / "db" / "migrations"
calls: list[int] = []
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
    # The vault login as db-logins.sql creates it: no password, IAM auth on
    # Aurora (rds_iam does not exist here, so that grant is skipped).
    admin.execute("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ssn_vault_login') THEN CREATE ROLE ssn_vault_login; END IF; END $$")
    admin.execute("ALTER ROLE ssn_vault_login WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD NULL")
    admin.execute("GRANT ssn_vault_rw TO ssn_vault_login")
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
        c.execute("REVOKE ALL ON public.ssn_ticket FROM app_user")
        c.execute("REVOKE ALL ON SEQUENCE public.ssn_ticket_id_seq FROM app_user")
    yield {**base, "dbname": name}
    admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')
    admin.close()


def _svc(conninfo):
    s = DbSettings(host=conninfo.get("host", "localhost"), port=int(conninfo.get("port", 5432)),
                   dbname=conninfo["dbname"], user="ssn_vault_login", password="", sslmode="disable")
    # Stands in for the IAM auth token: called once per connection.
    calls.clear()
    return SsnTokenService(PostgresVaultStore(s, password_provider=lambda: calls.append(1) or ""), FakeEncryptor(), PEPPER)


def test_app_user_cannot_read_vault(db):
    with psycopg.connect(**{**db, "user": "app_user"}) as c:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            c.execute("SELECT 1 FROM ssn_vault")
    with psycopg.connect(**{**db, "user": "app_user"}) as c:
        c.execute("SELECT 1 FROM claimant")  # still has its normal tables


def test_vault_role_cannot_update_or_delete(db):
    with psycopg.connect(**{**db, "user": "ssn_vault_login"}) as c:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            c.execute("DELETE FROM ssn_vault")


def _claim(db, svc, ssn, status="submitted"):
    """Tokenize, add the claimant and an open claim. Returns (token, claim_id)."""
    a = svc.tokenize(ssn)
    with psycopg.connect(**db) as c:
        cid = c.execute("INSERT INTO claimant (ssn_token, ssn_hmac, first_name, last_name) VALUES (%s, %s, 'Test', 'Person') "
                        "ON CONFLICT (ssn_token) DO UPDATE SET first_name = excluded.first_name RETURNING id",
                        (a.ssn_token, a.ssn_hmac)).fetchone()[0]
        claim = c.execute("INSERT INTO claim (claimant_id, claim_type, status) VALUES (%s, 'medical', %s) RETURNING id",
                          (cid, status)).fetchone()[0]
    return a.ssn_token, claim


def _close(db, claim_id, status="denied"):
    with psycopg.connect(**db) as c:
        c.execute("UPDATE claim SET status = %s, decided_at = CASE WHEN %s = 'denied' THEN now() END, "
                  "decision_reason = CASE WHEN %s = 'denied' THEN 'test' END WHERE id = %s",
                  (status, status, status, claim_id))


def _audit(db):
    with psycopg.connect(**db) as c:
        return c.execute("SELECT actor, action, reason, record_type, record_id, after_data::text FROM audit_event ORDER BY id").fetchall()


def _ticket_row(db, ticket):
    with psycopg.connect(**db) as c:
        return c.execute("SELECT used_at, revoked_at, replaced_by, expires_at - issued_at FROM ssn_ticket WHERE ticket = %s",
                         (ticket,)).fetchone()


def test_app_user_cannot_touch_tickets(db):
    for sql in ("SELECT 1 FROM ssn_ticket", "DELETE FROM ssn_ticket", "SELECT nextval('ssn_ticket_id_seq')"):
        with psycopg.connect(**{**db, "user": "app_user"}) as c:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                c.execute(sql)


def test_vault_role_ticket_grants_are_narrow(db):
    for sql in ("DELETE FROM ssn_ticket", "UPDATE ssn_ticket SET expires_at = now()",
                "UPDATE ssn_ticket SET claim_id = 1", "SELECT first_name FROM claimant",
                "SELECT decision_reason FROM claim", "UPDATE claim SET status = 'approved'"):
        with psycopg.connect(**{**db, "user": "ssn_vault_login"}) as c:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                c.execute(sql)


def test_ticket_cap_is_enforced_by_the_database(db):
    svc = _svc(db)
    _, claim = _claim(db, svc, "900-00-0010")
    with psycopg.connect(**db) as c:
        vault = c.execute("SELECT id FROM ssn_vault ORDER BY id DESC LIMIT 1").fetchone()[0]
        for interval in ("73 hours", "0 seconds", "-1 hour"):
            with pytest.raises(psycopg.errors.CheckViolation):
                with c.transaction():
                    c.execute("INSERT INTO ssn_ticket (ticket, vault_id, claim_id, issued_by, expires_at) "
                              "VALUES (%s, %s, %s, 's', now() + %s::interval)",
                              ("rtk_" + "C" * 32, vault, claim, interval))
        with pytest.raises(psycopg.errors.CheckViolation):
            c.execute("INSERT INTO ssn_ticket (ticket, vault_id, claim_id, issued_by, expires_at) "
                      "VALUES ('tok_' || repeat('C', 32), %s, %s, 's', now() + interval '1 hour')", (vault, claim))


def test_tokenize_and_reveal_against_postgres(db):
    svc = _svc(db)
    a = svc.tokenize("900-00-0001")
    assert svc.tokenize("900000001").ssn_token == a.ssn_token
    token, claim = _claim(db, svc, "900-00-0001")  # the token is accepted by claimant's CHECK
    assert token == a.ssn_token
    with psycopg.connect(**db) as c:
        stored = c.execute("SELECT ssn_token, ssn_hmac, ssn_ciphertext, key_id FROM ssn_vault").fetchall()
        assert all(b"900000001" not in bytes(v if isinstance(v, (bytes, memoryview)) else str(v).encode())
                   for row in stored for v in row)
    before = len(_audit(db))
    t = svc.issue_ticket(token, claim, actor="staff-1", reason="identity check")
    assert _ticket_row(db, t.ticket)[3].total_seconds() == 72 * 3600
    ssn, vault, trow = svc.reveal(t.ticket, actor="staff-1", reason="identity check")
    assert ssn == "900000001" and vault.ssn_token == token and trow.claim_id == claim
    rows = _audit(db)[before:]
    assert [r[1] for r in rows] == ["ssn.ticket_issue", "ssn.reveal"]
    assert rows[0][3:5] == ("ssn_ticket", t.id) and rows[1][:4] == ("staff-1", "ssn.reveal", "identity check", "ssn_vault")
    assert all("900000001" not in r[5] and t.ticket not in r[5] for r in rows)
    assert _ticket_row(db, t.ticket)[0] is not None
    # Single use.
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-1", reason="again")
    assert len(_audit(db)) == before + 2
    assert calls, "password provider was not used"


def test_expired_ticket_is_rejected_by_db_clock(db):
    svc = _svc(db)
    token, claim = _claim(db, svc, "900-00-0004")
    t = svc.issue_ticket(token, claim, actor="staff-1", reason="x")
    with psycopg.connect(**db) as c:  # age the ticket: issued 73h ago, expired 1h ago
        c.execute("UPDATE ssn_ticket SET issued_at = now() - interval '73 hours', "
                  "expires_at = now() - interval '1 hour' WHERE ticket = %s", (t.ticket,))
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-1", reason="x")
    assert _ticket_row(db, t.ticket)[0] is None


def test_closed_claim_kills_ticket_and_blocks_issue(db):
    from demo_app.ssn import NoOpenClaim

    svc = _svc(db)
    token, claim = _claim(db, svc, "900-00-0005")
    t = svc.issue_ticket(token, claim, actor="staff-1", reason="x")
    _close(db, claim, "withdrawn")
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-1", reason="x")
    with pytest.raises(TicketNotValid):
        svc.refresh(t.ticket, actor="staff-1", reason="x")
    with pytest.raises(NoOpenClaim):
        svc.issue_ticket(token, claim, actor="staff-1", reason="x")
    # Someone else's claim is not open for this token either.
    other, other_claim = _claim(db, svc, "900-00-0006")
    with pytest.raises(NoOpenClaim):
        svc.issue_ticket(token, other_claim, actor="staff-1", reason="x")


def test_refresh_against_postgres(db):
    svc = _svc(db)
    token, claim = _claim(db, svc, "900-00-0007")
    old = svc.issue_ticket(token, claim, actor="staff-1", reason="x")
    with pytest.raises(TicketNotValid):
        svc.refresh(old.ticket, actor="staff-2", reason="not mine")
    with psycopg.connect(**db) as c:  # expired but unused: refresh still allowed
        c.execute("UPDATE ssn_ticket SET issued_at = now() - interval '80 hours', "
                  "expires_at = now() - interval '8 hours' WHERE ticket = %s", (old.ticket,))
    before = len(_audit(db))
    new = svc.refresh(old.ticket, actor="staff-1", reason="more time")
    used, revoked, replaced_by, _ = _ticket_row(db, old.ticket)
    assert used is None and revoked is not None and replaced_by == new.id
    assert _ticket_row(db, new.ticket)[3].total_seconds() == 72 * 3600
    with pytest.raises(TicketNotValid):
        svc.reveal(old.ticket, actor="staff-1", reason="x")
    with pytest.raises(TicketNotValid):
        svc.refresh(old.ticket, actor="staff-1", reason="x")
    assert svc.reveal(new.ticket, actor="staff-1", reason="x")[0] == "900000007"
    rows = _audit(db)[before:]
    assert [r[1] for r in rows] == ["ssn.ticket_refresh", "ssn.reveal"]
    assert rows[0][3:5] == ("ssn_ticket", new.id)
    assert old.ticket not in rows[0][5] and new.ticket not in rows[0][5]


def test_unknown_ticket_and_audit_failure_against_postgres(db):
    svc = _svc(db)
    with pytest.raises(TicketNotValid):
        svc.reveal("rtk_" + "Z" * 32, actor="staff-1", reason="x")
    token, claim = _claim(db, svc, "900-00-0003")
    t = svc.issue_ticket(token, claim, actor="staff-1", reason="x")
    # Make the audit insert fail: no SSN comes back and the ticket isn't burned.
    with psycopg.connect(**db) as c:
        c.execute("REVOKE INSERT ON audit_event FROM ssn_vault_rw")
    try:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            svc.reveal(t.ticket, actor="staff-1", reason="x")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            svc.refresh(t.ticket, actor="staff-1", reason="x")
        assert _ticket_row(db, t.ticket)[:3] == (None, None, None)
    finally:
        with psycopg.connect(**db) as c:
            c.execute("GRANT INSERT ON audit_event TO ssn_vault_rw")
    assert svc.reveal(t.ticket, actor="staff-1", reason="x")[0] == "900000003"


def test_raw_ssn_rejected_as_token(db):
    with psycopg.connect(**db) as c:
        with pytest.raises(psycopg.errors.CheckViolation):
            c.execute("INSERT INTO ssn_vault (ssn_token, ssn_hmac, ssn_ciphertext, key_id) VALUES ('900-00-0001', %s, 'x', 'k')",
                      (bytes(32),))


# --- testing-only claim seed (demo_seed.py), run as app_user -------------

def _seed_store(conninfo):
    from demo_app.demo_seed import PostgresSeedStore
    s = DbSettings(host=conninfo.get("host", "localhost"), port=int(conninfo.get("port", 5432)),
                   dbname=conninfo["dbname"], user="app_user", password="", sslmode="disable")
    return PostgresSeedStore(s)


def test_seed_claim_as_app_user_is_idempotent(db):
    svc = _svc(db)
    a = svc.tokenize("900-55-0001")
    seed = _seed_store(db)
    first = seed.seed_claim(a.ssn_token, a.ssn_hmac, "izzy")
    again = seed.seed_claim(a.ssn_token, a.ssn_hmac, "izzy")
    assert first.created is True and again.created is False
    assert (again.claimant_id, again.claim_id, again.employer_id) == (first.claimant_id, first.claim_id, first.employer_id)
    assert first.claim_status == "submitted"
    with psycopg.connect(**db) as c:
        assert c.execute("SELECT count(*) FROM claim WHERE claimant_id = %s", (first.claimant_id,)).fetchone()[0] == 1
        assert c.execute("SELECT count(*) FROM employer WHERE fein = '000000000'").fetchone()[0] == 1
        rows = c.execute("SELECT actor, record_type, record_id, after_data::text FROM audit_event "
                         "WHERE action = 'demo.seed_claim' AND record_id = %s", (first.claim_id,)).fetchall()
    assert len(rows) == 1 and rows[0][:3] == ("izzy", "claim", first.claim_id)
    assert a.ssn_token not in rows[0][3] and a.ssn_hmac.hex() not in rows[0][3]


def test_seed_claim_reuses_an_open_claim_and_replaces_a_closed_one(db):
    svc = _svc(db)
    a = svc.tokenize("900-55-0002")
    seed = _seed_store(db)
    first = seed.seed_claim(a.ssn_token, a.ssn_hmac, "izzy")
    _close(db, first.claim_id)
    second = seed.seed_claim(a.ssn_token, a.ssn_hmac, "izzy")
    assert second.created is True and second.claim_id != first.claim_id
    assert second.claimant_id == first.claimant_id


def test_seed_claim_refuses_a_mismatched_token_and_hmac(db):
    from demo_app.demo_seed import SeedConflict
    svc = _svc(db)
    a = svc.tokenize("900-55-0003")
    b = svc.tokenize("900-55-0004")
    seed = _seed_store(db)
    seed.seed_claim(a.ssn_token, a.ssn_hmac, "izzy")
    with pytest.raises(SeedConflict):
        seed.seed_claim(b.ssn_token, a.ssn_hmac, "izzy")  # a's HMAC under b's token
    with pytest.raises(SeedConflict):
        seed.seed_claim(a.ssn_token, b.ssn_hmac, "izzy")  # a's token with b's HMAC
    with psycopg.connect(**db) as c:
        assert c.execute("SELECT count(*) FROM claimant WHERE ssn_token = %s", (b.ssn_token,)).fetchone()[0] == 0


def test_seeded_claim_runs_the_whole_ticket_flow(db):
    """tokenize -> seed (app_user) -> issue -> reveal -> reveal again
    refused -> issue -> refresh -> old ticket dead -> new ticket reveals."""
    svc = _svc(db)
    a = svc.tokenize("900-55-0005")
    claim = _seed_store(db).seed_claim(a.ssn_token, a.ssn_hmac, "izzy").claim_id
    t1 = svc.issue_ticket(a.ssn_token, claim, actor="izzy", reason="demo")
    assert svc.reveal(t1.ticket, actor="izzy", reason="demo")[0] == "900550005"
    with pytest.raises(TicketNotValid):
        svc.reveal(t1.ticket, actor="izzy", reason="demo")
    t2 = svc.issue_ticket(a.ssn_token, claim, actor="izzy", reason="demo")
    t3 = svc.refresh(t2.ticket, actor="izzy", reason="demo")
    with pytest.raises(TicketNotValid):
        svc.reveal(t2.ticket, actor="izzy", reason="demo")
    assert svc.reveal(t3.ticket, actor="izzy", reason="demo")[0] == "900550005"


def test_seed_needs_no_new_grants(db):
    # app_user still can't see the vault or tickets, and the vault login
    # still can't write claimants or claims.
    with psycopg.connect(**{**db, "user": "app_user"}) as c:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            c.execute("SELECT 1 FROM ssn_ticket")
    for sql in ("INSERT INTO employer (fein, legal_name) VALUES ('000000001', 'x')",
                "UPDATE claim SET status = 'submitted'"):
        with psycopg.connect(**{**db, "user": "ssn_vault_login"}) as c:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                c.execute(sql)
