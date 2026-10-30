"""Reveal tickets: expiry, single use, refresh with re-auth, and the audit
types each step writes. Fake 9xx SSNs only."""

import logging
from datetime import timedelta

import pytest

from demo_app.ssn import HeaderReauthVerifier, NoOpenClaim, RevealNotAllowed, TicketNotValid
from demo_app.ssn.service import TICKET_RE, TICKET_TTL_HOURS, TOKEN_RE

FAKE_SSN = "900-00-0001"
FAKE_DIGITS = "900000001"
OTHER_SSN = "900-00-0002"
STAFF = {"X-Actor": "staff-1"}
GONE = {"detail": "ticket not found or no longer valid"}


def reauth_headers(clock, actor="staff-1", age=10):
    return {"X-Actor": actor, "X-Reauth-Actor": actor, "X-Reauth-At": str(int(clock["now"] - age))}


def actions(store):
    return [a.action for a in store.audit]


# --- issue -----------------------------------------------------------------

def test_issue_gives_a_ticket_capped_at_72_hours(svc, store, issue):
    token, t = issue(FAKE_SSN)
    assert TICKET_RE.match(t.ticket) and not TOKEN_RE.match(t.ticket)
    assert t.expires_at - t.issued_at == timedelta(hours=72) and TICKET_TTL_HOURS == 72
    assert actions(store) == ["ssn.ticket_issue"]
    a = store.audit[0]
    assert (a.actor, a.record_type, a.record_id, a.reason) == ("staff-1", "ssn_ticket", t.id, "identity check")
    assert a.after_data == {"ssn_token": token, "claim_id": t.claim_id, "expires_at": t.expires_at.isoformat()}
    # The ticket is a bearer value. app_user can read audit_event, so it's not there.
    assert t.ticket not in repr(store.audit)


def test_issue_needs_actor_and_reason(svc, store):
    token = svc.tokenize(FAKE_SSN).ssn_token
    store.add_claim(1, token)
    for actor, reason in [("", "why"), ("staff-1", ""), ("staff-1", "  ")]:
        with pytest.raises(RevealNotAllowed):
            svc.issue_ticket(token, 1, actor=actor, reason=reason)
    assert store.tickets == [] and store.audit == []


@pytest.mark.parametrize("status", ["denied", "withdrawn"])
def test_no_ticket_for_a_closed_claim(svc, store, status):
    token = svc.tokenize(FAKE_SSN).ssn_token
    store.add_claim(1, token, status)
    with pytest.raises(NoOpenClaim):
        svc.issue_ticket(token, 1, actor="staff-1", reason="why")
    assert store.tickets == [] and store.audit == []


def test_no_ticket_for_someone_elses_claim_or_unknown_token(svc, store):
    mine = svc.tokenize(FAKE_SSN).ssn_token
    theirs = svc.tokenize(OTHER_SSN).ssn_token
    store.add_claim(1, theirs)
    for token, claim_id in [(mine, 1), (mine, 999), ("tok_" + "Q" * 32, 1), (FAKE_SSN, 1)]:
        with pytest.raises(NoOpenClaim):
            svc.issue_ticket(token, claim_id, actor="staff-1", reason="why")
    assert store.tickets == []


# --- expiry ----------------------------------------------------------------

def test_ticket_works_just_before_72_hours(svc, store, issue):
    _, t = issue(FAKE_SSN)
    store.now += timedelta(hours=72) - timedelta(seconds=1)
    assert svc.reveal(t.ticket, actor="staff-1", reason="why")[0] == FAKE_DIGITS


def test_expired_ticket_is_rejected(svc, store, issue):
    _, t = issue(FAKE_SSN)
    store.now += timedelta(hours=72)
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-1", reason="why")
    assert actions(store) == ["ssn.ticket_issue"]
    assert store.ticket(t.ticket)["used_at"] is None


@pytest.mark.parametrize("status", ["denied", "withdrawn"])
def test_ticket_dies_when_the_claim_closes(svc, store, issue, status):
    _, t = issue(FAKE_SSN)
    store.claims[t.claim_id][1] = status
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-1", reason="why")
    assert actions(store) == ["ssn.ticket_issue"]


def test_approved_claim_is_still_open(svc, store, issue):
    _, t = issue(FAKE_SSN)
    store.claims[t.claim_id][1] = "approved"
    assert svc.reveal(t.ticket, actor="staff-1", reason="why")[0] == FAKE_DIGITS


# --- single use ------------------------------------------------------------

def test_second_reveal_of_the_same_ticket_is_rejected(svc, store, issue):
    _, t = issue(FAKE_SSN)
    assert svc.reveal(t.ticket, actor="staff-1", reason="first")[0] == FAKE_DIGITS
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-1", reason="second")
    with pytest.raises(TicketNotValid):
        svc.reveal(t.ticket, actor="staff-2", reason="someone else")
    assert actions(store) == ["ssn.ticket_issue", "ssn.reveal"]


def test_failed_audit_does_not_burn_the_ticket(svc, store, issue):
    _, t = issue(FAKE_SSN)
    store.fail_audit = True
    with pytest.raises(RuntimeError):
        svc.reveal(t.ticket, actor="staff-1", reason="why")
    assert store.ticket(t.ticket)["used_at"] is None
    store.fail_audit = False
    assert svc.reveal(t.ticket, actor="staff-1", reason="why")[0] == FAKE_DIGITS


# --- refresh ---------------------------------------------------------------

def test_refresh_issues_a_new_ticket_and_kills_the_old_one(svc, store, issue):
    _, old = issue(FAKE_SSN)
    store.now += timedelta(hours=10)
    new = svc.refresh(old.ticket, actor="staff-1", reason="still working the claim")
    assert new.ticket != old.ticket and TICKET_RE.match(new.ticket)
    assert new.claim_id == old.claim_id and new.vault_id == old.vault_id
    # Each ticket gets its own 72 hours from its own issue time.
    assert new.issued_at == store.now and new.expires_at == store.now + timedelta(hours=72)
    rec = store.ticket(old.ticket)
    assert rec["revoked_at"] == store.now and rec["replaced_by"] == new.id

    with pytest.raises(TicketNotValid):
        svc.reveal(old.ticket, actor="staff-1", reason="old one")
    with pytest.raises(TicketNotValid):
        svc.refresh(old.ticket, actor="staff-1", reason="old one again")
    assert svc.reveal(new.ticket, actor="staff-1", reason="new one")[0] == FAKE_DIGITS


def test_refresh_writes_one_refresh_audit_line(svc, store, issue):
    _, old = issue(FAKE_SSN)
    new = svc.refresh(old.ticket, actor="staff-1", reason="more time")
    svc.reveal(new.ticket, actor="staff-1", reason="verify")
    # Three steps, three distinct audit types, one line each.
    assert actions(store) == ["ssn.ticket_issue", "ssn.ticket_refresh", "ssn.reveal"]
    a = store.audit[1]
    assert (a.actor, a.record_type, a.record_id, a.reason) == ("staff-1", "ssn_ticket", new.id, "more time")
    assert a.after_data == {"replaces_ticket_id": old.id, "claim_id": old.claim_id,
                            "expires_at": new.expires_at.isoformat()}
    assert old.ticket not in repr(store.audit) and new.ticket not in repr(store.audit)
    assert FAKE_DIGITS not in repr(store.audit)


def test_an_expired_unused_ticket_can_be_refreshed(svc, store, issue):
    _, old = issue(FAKE_SSN)
    store.now += timedelta(hours=100)
    new = svc.refresh(old.ticket, actor="staff-1", reason="back from leave")
    assert svc.reveal(new.ticket, actor="staff-1", reason="verify")[0] == FAKE_DIGITS


def test_a_used_ticket_cannot_be_refreshed(svc, store, issue):
    _, t = issue(FAKE_SSN)
    svc.reveal(t.ticket, actor="staff-1", reason="verify")
    with pytest.raises(TicketNotValid):
        svc.refresh(t.ticket, actor="staff-1", reason="again")
    assert actions(store) == ["ssn.ticket_issue", "ssn.reveal"]


def test_only_the_holder_can_refresh(svc, store, issue):
    _, t = issue(FAKE_SSN, actor="staff-1")
    with pytest.raises(TicketNotValid):
        svc.refresh(t.ticket, actor="staff-2", reason="mine now")
    assert store.ticket(t.ticket)["revoked_at"] is None


def test_refresh_cannot_outlive_the_claim(svc, store, issue):
    _, t = issue(FAKE_SSN)
    store.claims[t.claim_id][1] = "withdrawn"
    with pytest.raises(TicketNotValid):
        svc.refresh(t.ticket, actor="staff-1", reason="more time")


def test_refresh_audit_failure_keeps_the_old_ticket(svc, store, issue):
    _, t = issue(FAKE_SSN)
    store.fail_audit = True
    with pytest.raises(RuntimeError):
        svc.refresh(t.ticket, actor="staff-1", reason="more time")
    assert store.ticket(t.ticket)["revoked_at"] is None and len(store.tickets) == 1


def test_logs_carry_no_ticket_token_actor_or_ssn(svc, store, issue, caplog):
    caplog.set_level(logging.DEBUG)
    token, t = issue(FAKE_SSN, actor="staff-secret-name")
    new = svc.refresh(t.ticket, actor="staff-secret-name", reason="r")
    svc.reveal(new.ticket, actor="staff-secret-name", reason="r")
    with pytest.raises(TicketNotValid):
        svc.reveal(new.ticket, actor="staff-secret-name", reason="r")
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "reason=used" in text
    for value in (token, t.ticket, new.ticket, "staff-secret-name", FAKE_DIGITS, FAKE_SSN):
        assert value not in text


# --- re-auth placeholder ---------------------------------------------------

def test_header_reauth_verifier():
    now = 1_800_000_000
    v = HeaderReauthVerifier(max_age_seconds=300, clock=lambda: now)
    ok = {"x-reauth-actor": "staff-1", "x-reauth-at": str(now - 60)}
    assert v.verify("staff-1", ok)
    assert not v.verify("staff-2", ok)                                        # someone else's sign-in
    assert not v.verify("staff-1", {**ok, "x-reauth-at": str(now - 301)})      # too old
    assert not v.verify("staff-1", {**ok, "x-reauth-at": str(now + 120)})      # from the future
    assert not v.verify("staff-1", {**ok, "x-reauth-at": "yesterday"})
    assert not v.verify("staff-1", {"x-reauth-at": str(now)})                 # no actor assertion
    assert not v.verify("", ok)
    with pytest.raises(ValueError):
        HeaderReauthVerifier(max_age_seconds=0)


# --- HTTP ------------------------------------------------------------------

def _ticket(client, store, claim_id=7, ssn=FAKE_SSN):
    token = client.post("/ssn/tokenize", json={"ssn": ssn}).json()["ssn_token"]
    store.add_claim(claim_id, token)
    r = client.post("/ssn/tickets", json={"ssn_token": token, "claim_id": claim_id, "reason": "verify"}, headers=STAFF)
    assert r.status_code == 201
    body = r.json()
    assert set(body) == {"ticket", "claim_id", "expires_at"} and body["claim_id"] == claim_id
    return token, body["ticket"]


def test_http_issue_errors(client, store):
    token = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN}).json()["ssn_token"]
    store.add_claim(7, token, "denied")
    body = {"ssn_token": token, "claim_id": 7, "reason": "verify"}
    assert client.post("/ssn/tickets", json=body).status_code == 401
    assert client.post("/ssn/tickets", json={**body, "reason": ""}, headers=STAFF).status_code == 400
    r = client.post("/ssn/tickets", json=body, headers=STAFF)
    assert r.status_code == 404 and r.json() == {"detail": "no open claim for this token"}
    assert client.post("/ssn/tickets", json={**body, "claim_id": 0}, headers=STAFF).status_code == 422
    assert store.audit == []


def test_http_rejections_all_look_the_same(client, store):
    _, used = _ticket(client, store, 1)
    assert client.post("/ssn/reveal", json={"ticket": used, "reason": "r"}, headers=STAFF).status_code == 200
    _, expired = _ticket(client, store, 2, OTHER_SSN)
    store.now += timedelta(hours=73)
    answers = [client.post("/ssn/reveal", json={"ticket": t, "reason": "r"}, headers=STAFF)
               for t in (used, expired, "rtk_" + "Z" * 32)]
    assert {r.status_code for r in answers} == {404}
    assert all(r.json() == GONE for r in answers)


def test_http_refresh_flow(client, store, reauth_clock):
    _, old = _ticket(client, store)
    body = {"ticket": old, "reason": "more time"}

    # No actor, no reason, then no or bad re-auth: refused, nothing changes.
    assert client.post("/ssn/tickets/refresh", json=body).status_code == 401
    assert client.post("/ssn/tickets/refresh", json={"ticket": old}, headers=STAFF).status_code == 400
    r = client.post("/ssn/tickets/refresh", json=body, headers=STAFF)
    assert r.status_code == 401 and r.json() == {"detail": "re-authentication required"}
    stale = reauth_headers(reauth_clock, age=3600)
    assert client.post("/ssn/tickets/refresh", json=body, headers=stale).status_code == 401
    other = {**reauth_headers(reauth_clock), "X-Reauth-Actor": "staff-2"}
    assert client.post("/ssn/tickets/refresh", json=body, headers=other).status_code == 401
    assert actions(store) == ["ssn.ticket_issue"] and store.ticket(old)["revoked_at"] is None

    r = client.post("/ssn/tickets/refresh", json=body, headers=reauth_headers(reauth_clock))
    assert r.status_code == 201 and r.headers["cache-control"] == "no-store"
    new = r.json()["ticket"]
    assert new != old

    r = client.post("/ssn/reveal", json={"ticket": old, "reason": "r"}, headers=STAFF)
    assert r.status_code == 404 and r.json() == GONE
    r = client.post("/ssn/tickets/refresh", json=body, headers=reauth_headers(reauth_clock))
    assert r.status_code == 404 and r.json() == GONE
    r = client.post("/ssn/reveal", json={"ticket": new, "reason": "r"}, headers=STAFF)
    assert r.status_code == 200 and r.json()["ssn"] == FAKE_DIGITS
    assert actions(store) == ["ssn.ticket_issue", "ssn.ticket_refresh", "ssn.reveal"]


def test_http_refresh_by_someone_else_is_404(client, store, reauth_clock):
    _, t = _ticket(client, store)
    r = client.post("/ssn/tickets/refresh", json={"ticket": t, "reason": "r"},
                    headers=reauth_headers(reauth_clock, actor="staff-2"))
    assert r.status_code == 404 and r.json() == GONE
