"""SSN token service. Every SSN here uses the 9xx area, which is never
issued, so none of them can be a real person's number."""

import logging
import re

import pytest
from fastapi.testclient import TestClient

from demo_app.main import app
from demo_app.ssn import FakeEncryptor, InvalidSsn, RevealNotAllowed, TicketNotValid
from demo_app.ssn.redact import RedactSsnFilter, redact
from demo_app.ssn.service import TOKEN_RE, hmac_ssn, load_pepper_from_env, normalize_ssn

FAKE_SSN = "900-00-0001"
FAKE_DIGITS = "900000001"
OTHER_SSN = "900-00-0002"
from conftest import PEPPER  # noqa: E402 - shared test-only key
# claimant.ssn_token's CHECK from V6, applied here the way Postgres would.
CLAIMANT_CHECK = re.compile(r"^[0-9]{3}-?[0-9]{2}-?[0-9]{4}$")


def all_stored_bytes(store):
    out = []
    for r in store.rows:
        out += [r.ssn_token.encode(), r.ssn_hmac, r.ssn_ciphertext, r.key_id.encode()]
    for a in store.audit:
        out += [repr(a).encode()]
    return out


# --- service ---------------------------------------------------------------

def test_tokenize_is_idempotent(svc, store):
    a = svc.tokenize(FAKE_SSN)
    b = svc.tokenize(FAKE_DIGITS)  # same number, no dashes
    assert a.created and not b.created
    assert a.ssn_token == b.ssn_token and a.ssn_hmac == b.ssn_hmac
    assert len(store.rows) == 1
    assert svc.tokenize(OTHER_SSN).ssn_token != a.ssn_token


def test_token_passes_claimant_check_and_vault_format(svc):
    token = svc.tokenize(FAKE_SSN).ssn_token
    assert not CLAIMANT_CHECK.match(token)
    assert TOKEN_RE.match(token)
    assert FAKE_DIGITS not in token


def test_hmac_is_keyed_sha256_of_digits(svc):
    result = svc.tokenize(FAKE_SSN)
    assert len(result.ssn_hmac) == 32
    assert result.ssn_hmac == hmac_ssn(PEPPER, FAKE_DIGITS)
    assert result.ssn_hmac != hmac_ssn(bytes(32), FAKE_DIGITS)


def test_raw_ssn_only_in_ciphertext(svc, store, issue):
    _, t = issue(FAKE_SSN)
    svc.reveal(t.ticket, actor="staff-1", reason="identity check")
    for blob in all_stored_bytes(store):
        assert FAKE_DIGITS.encode() not in blob
        assert FAKE_SSN.encode() not in blob


def test_encryption_context_binds_token(svc, store):
    svc.tokenize(FAKE_SSN)
    row = store.rows[0]
    enc = FakeEncryptor()
    with pytest.raises(ValueError):
        enc.decrypt(row.ssn_ciphertext, {"purpose": "ssn", "token": "tok_" + "x" * 32})
    assert enc.decrypt(row.ssn_ciphertext, {"purpose": "ssn", "token": row.ssn_token}) == FAKE_DIGITS.encode()


@pytest.mark.parametrize("bad", ["", "12345678", "1234567890", "abc-de-fghi", "900-00-00011", None])
def test_invalid_input_rejected_without_echo(bad):
    with pytest.raises(InvalidSsn) as exc:
        normalize_ssn(bad)
    assert str(bad) not in str(exc.value) or not bad


def test_reveal_needs_actor_and_reason(svc, store, issue):
    _, t = issue(FAKE_SSN)
    issued = list(store.audit)
    for actor, reason in [("", "why"), ("staff-1", ""), ("staff-1", "   ")]:
        with pytest.raises(RevealNotAllowed):
            svc.reveal(t.ticket, actor=actor, reason=reason)
    assert store.audit == issued
    assert store.ticket(t.ticket)["used_at"] is None


def test_reveal_writes_one_audit_row_without_ssn(svc, store, issue):
    token, t = issue(FAKE_SSN)
    assert svc.reveal(t.ticket, actor="staff-1", reason="claimant called, verifying")[0] == FAKE_DIGITS
    reveals = [a for a in store.audit if a.action == "ssn.reveal"]
    assert len(reveals) == 1
    a = reveals[0]
    assert (a.actor, a.action, a.reason, a.record_type) == ("staff-1", "ssn.reveal", "claimant called, verifying", "ssn_vault")
    assert a.after_data == {"ssn_token": token, "ticket_id": t.id, "claim_id": t.claim_id}
    assert FAKE_DIGITS not in repr(a) and t.ticket not in repr(a)


def test_failed_audit_returns_no_ssn(svc, store, issue):
    _, t = issue(FAKE_SSN)
    issued = list(store.audit)
    store.fail_audit = True
    with pytest.raises(RuntimeError):
        svc.reveal(t.ticket, actor="staff-1", reason="why")
    assert store.audit == issued


def test_unknown_or_permanent_token_cannot_reveal(svc, issue):
    token, _ = issue(FAKE_SSN)
    for value in ("rtk_" + "A" * 32, token, FAKE_SSN, ""):
        with pytest.raises(TicketNotValid):
            svc.reveal(value, actor="staff-1", reason="why")


def test_pepper_from_env(monkeypatch):
    monkeypatch.setenv("SSN_HMAC_KEY", "ab" * 32)
    assert load_pepper_from_env() == b"\xab" * 32
    monkeypatch.setenv("SSN_HMAC_KEY", "ab" * 8)
    with pytest.raises(RuntimeError):
        load_pepper_from_env()
    monkeypatch.delenv("SSN_HMAC_KEY")
    with pytest.raises(RuntimeError):
        load_pepper_from_env()


def test_ssn_never_in_logs(svc, issue, caplog):
    caplog.set_level(logging.DEBUG)
    _, t = issue(FAKE_SSN)
    svc.reveal(t.ticket, actor="staff-1", reason="why")
    with pytest.raises(InvalidSsn):
        svc.tokenize("900-00-00019")
    assert caplog.records
    for rec in caplog.records:
        assert FAKE_DIGITS not in rec.getMessage() and FAKE_SSN not in rec.getMessage()


def test_log_filter_masks_ssn_shapes():
    assert redact(f"oops {FAKE_SSN} and {FAKE_DIGITS} and 900 00 0001") == (
        "oops [REDACTED-SSN] and [REDACTED-SSN] and [REDACTED-SSN]"
    )
    assert redact("order 1234567890 total 12") == "order 1234567890 total 12"
    rec = logging.LogRecord("x", logging.INFO, __file__, 1, "value=%s", (FAKE_SSN,), None)
    RedactSsnFilter().filter(rec)
    assert rec.getMessage() == "value=[REDACTED-SSN]"


# --- HTTP ------------------------------------------------------------------

def test_http_tokenize(client):
    r = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    assert r.status_code == 201
    body = r.json()
    assert TOKEN_RE.match(body["ssn_token"]) and len(bytes.fromhex(body["ssn_hmac"])) == 32
    assert FAKE_DIGITS not in r.text
    again = client.post("/ssn/tokenize", json={"ssn": FAKE_DIGITS})
    assert again.status_code == 200 and again.json() == body


def test_http_tokenize_bad_input_does_not_echo(client):
    r = client.post("/ssn/tokenize", json={"ssn": "900-00-00019"})
    assert r.status_code == 400 and "900" not in r.text
    r = client.post("/ssn/tokenize", json={"ssn": 900000001})  # wrong type, 422
    assert r.status_code == 422 and "900000001" not in r.text


def test_http_reveal_flow(client, store):
    token = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN}).json()["ssn_token"]
    store.add_claim(7, token)
    actor = {"X-Actor": "staff-1"}

    r = client.post("/ssn/tickets", json={"ssn_token": token, "claim_id": 7, "reason": "verify identity"}, headers=actor)
    assert r.status_code == 201 and r.headers["cache-control"] == "no-store"
    ticket = r.json()["ticket"]
    issued = len(store.audit)

    r = client.post("/ssn/reveal", json={"ticket": ticket}, headers=actor)
    assert r.status_code == 400 and len(store.audit) == issued
    assert r.headers["cache-control"] == "no-store"

    r = client.post("/ssn/reveal", json={"ticket": ticket, "reason": "why"})
    assert r.status_code == 401 and len(store.audit) == issued

    r = client.post("/ssn/reveal", json={"ticket": "rtk_" + "A" * 32, "reason": "why"}, headers=actor)
    assert r.status_code == 404 and len(store.audit) == issued

    # The permanent token is not a ticket any more.
    r = client.post("/ssn/reveal", json={"ticket": token, "reason": "why"}, headers=actor)
    assert r.status_code == 404 and len(store.audit) == issued

    r = client.post("/ssn/reveal", json={"ticket": ticket, "reason": "verify identity"}, headers=actor)
    assert r.status_code == 200
    assert r.json() == {"ssn_token": token, "claim_id": 7, "ssn": FAKE_DIGITS}
    assert r.headers["cache-control"] == "no-store"
    assert store.audit[-1].actor == "staff-1" and store.audit[-1].action == "ssn.reveal"


def test_http_old_reveal_body_is_rejected(client):
    # Callers still sending {"token": ...} get a bare 422, nothing echoed.
    r = client.post("/ssn/reveal", json={"token": "tok_" + "A" * 32, "reason": "why"}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 422 and r.json() == {"detail": "invalid request"}


def test_http_reveal_audit_failure_is_503_without_ssn(client, store, issue):
    _, t = issue(FAKE_SSN)
    store.fail_audit = True
    r = client.post("/ssn/reveal", json={"ticket": t.ticket, "reason": "why"}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 503 and FAKE_DIGITS not in r.text
    assert store.ticket(t.ticket)["used_at"] is None


def test_unconfigured_service_is_503(monkeypatch):
    # Outside ECS with no override, the name prefix is unknown: fail closed.
    for var in ("SSN_NAME_PREFIX", "ECS_CONTAINER_METADATA_URI_V4"):
        monkeypatch.delenv(var, raising=False)
    from demo_app.main import _ssn_service

    _ssn_service.reset()
    r = TestClient(app).post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    _ssn_service.reset()
    assert r.status_code == 503 and r.json() == {"detail": "ssn service unavailable"}


def test_kms_encryptor_passes_key_and_context():
    from demo_app.ssn import KmsEncryptor

    class StubKms:
        def __init__(self):
            self.calls = []

        def encrypt(self, **kw):
            self.calls.append(("encrypt", kw))
            return {"CiphertextBlob": b"blob"}

        def decrypt(self, **kw):
            self.calls.append(("decrypt", kw))
            return {"Plaintext": b"900000001"}

    stub = StubKms()
    enc = KmsEncryptor("arn:aws:kms:us-east-2:000000000000:key/test", client=stub)
    ctx = {"purpose": "ssn", "token": "tok_" + "A" * 32}
    assert enc.encrypt(b"900000001", ctx) == b"blob"
    assert enc.decrypt(b"blob", ctx) == b"900000001"
    for _, kw in stub.calls:
        assert kw["KeyId"] == enc.key_id and kw["EncryptionContext"] == ctx
