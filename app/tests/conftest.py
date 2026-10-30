"""Shared fakes for the SSN tests. Every SSN here uses the 9xx area, which
is never issued, so none of them can be a real person's number."""

import dataclasses
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from demo_app.main import app, get_reauth_verifier, get_ssn_service
from demo_app.ssn import FakeEncryptor, HeaderReauthVerifier, SsnTokenService
from demo_app.ssn.store import (
    OPEN_CLAIM_STATUSES,
    REJECT_CLAIM_CLOSED,
    REJECT_EXPIRED,
    REJECT_NOT_HOLDER,
    REJECT_REVOKED,
    REJECT_UNKNOWN,
    REJECT_USED,
    TicketRejected,
    TicketRow,
)

PEPPER = bytes(range(32))  # test-only key
T0 = datetime(2026, 1, 5, 9, 0, tzinfo=timezone.utc)


class FakeVaultStore:
    """In memory, with the same rules and the same all-or-nothing
    transactions as the Postgres store. now is the database clock."""

    def __init__(self):
        self.rows = []
        self.audit = []
        self.fail_audit = False
        self.now = T0
        self.claims = {}  # claim_id -> [claimant ssn_token, status]
        self.tickets = []  # dicts, one per ssn_ticket row

    # --- test helpers
    def add_claim(self, claim_id, ssn_token, status="submitted"):
        self.claims[claim_id] = [ssn_token, status]

    def ticket(self, value):
        return next((t for t in self.tickets if t["ticket"] == value), None)

    def _commit_audit(self, entry):
        if self.fail_audit:
            raise RuntimeError("audit insert failed")
        self.audit.append(entry)

    @staticmethod
    def _row(t):
        return TicketRow(id=t["id"], ticket=t["ticket"], vault_id=t["vault_id"], claim_id=t["claim_id"],
                         issued_by=t["issued_by"], issued_at=t["issued_at"], expires_at=t["expires_at"])

    def _claim_open(self, claim_id):
        c = self.claims.get(claim_id)
        return c is not None and c[1] in OPEN_CLAIM_STATUSES

    def _why(self, t, actor):
        if t is None:
            return REJECT_UNKNOWN
        if t["used_at"]:
            return REJECT_USED
        if t["revoked_at"]:
            return REJECT_REVOKED
        if not self._claim_open(t["claim_id"]):
            return REJECT_CLAIM_CLOSED
        if actor is not None and t["issued_by"] != actor:
            return REJECT_NOT_HOLDER
        return REJECT_EXPIRED if t["expires_at"] <= self.now else REJECT_UNKNOWN

    def _new(self, value, vault_id, claim_id, actor, ttl_hours):
        assert ttl_hours <= 72  # V11's CHECK
        return {"id": len(self.tickets) + 1, "ticket": value, "vault_id": vault_id, "claim_id": claim_id,
                "issued_by": actor, "issued_at": self.now, "expires_at": self.now + timedelta(hours=ttl_hours),
                "used_at": None, "revoked_at": None, "replaced_by": None}

    # --- VaultStore
    def find_by_hmac(self, ssn_hmac):
        return next((r for r in self.rows if r.ssn_hmac == ssn_hmac), None)

    def insert(self, row):
        existing = self.find_by_hmac(row.ssn_hmac)
        if existing:
            return existing
        row = dataclasses.replace(row, id=len(self.rows) + 1)
        self.rows.append(row)
        return row

    def issue_ticket(self, ssn_token, claim_id, ticket, ttl_hours, actor, audit):
        vault = next((r for r in self.rows if r.ssn_token == ssn_token), None)
        claim = self.claims.get(claim_id)
        if vault is None or claim is None or claim[0] != ssn_token or not self._claim_open(claim_id):
            return None
        t = self._new(ticket, vault.id, claim_id, actor, ttl_hours)
        row = self._row(t)
        self._commit_audit(audit(row))
        self.tickets.append(t)
        return row

    def reveal_ticket(self, ticket, audit, use):
        t = self.ticket(ticket)
        ok = (t is not None and not t["used_at"] and not t["revoked_at"]
              and t["expires_at"] > self.now and self._claim_open(t["claim_id"]))
        if not ok:
            raise TicketRejected(self._why(t, None))
        vault = next(r for r in self.rows if r.id == t["vault_id"])
        trow = self._row(t)
        entry = audit(vault, trow)
        value = use(vault)
        self._commit_audit(entry)
        t["used_at"] = self.now  # commit
        return value, vault, trow

    def refresh_ticket(self, ticket, actor, new_ticket, ttl_hours, audit):
        old = self.ticket(ticket)
        ok = (old is not None and not old["used_at"] and not old["revoked_at"]
              and old["issued_by"] == actor and self._claim_open(old["claim_id"]))
        if not ok:
            raise TicketRejected(self._why(old, actor))
        new = self._new(new_ticket, old["vault_id"], old["claim_id"], actor, ttl_hours)
        new["id"] = len(self.tickets) + 1
        self._commit_audit(audit(self._row(old), self._row(new)))
        self.tickets.append(new)
        old["revoked_at"] = self.now
        old["replaced_by"] = new["id"]
        return self._row(new)


@pytest.fixture
def store():
    return FakeVaultStore()


@pytest.fixture
def svc(store):
    return SsnTokenService(store, FakeEncryptor(), PEPPER)


@pytest.fixture
def reauth_clock():
    # Seconds since the epoch, as the demo verifier sees them.
    return {"now": T0.timestamp()}


@pytest.fixture
def client(svc, reauth_clock):
    app.dependency_overrides[get_ssn_service] = lambda: svc
    app.dependency_overrides[get_reauth_verifier] = lambda: HeaderReauthVerifier(clock=lambda: reauth_clock["now"])
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def issue(svc, store):
    """Tokenize an SSN, open a claim for it, and get a reveal ticket.
    Returns (ssn_token, TicketRow)."""
    counter = {"n": 0}

    def _issue(ssn, actor="staff-1", status="submitted"):
        counter["n"] += 1
        claim_id = 100 + counter["n"]
        token = svc.tokenize(ssn).ssn_token
        store.add_claim(claim_id, token, status)
        return token, svc.issue_ticket(token, claim_id, actor=actor, reason="identity check")

    return _issue
