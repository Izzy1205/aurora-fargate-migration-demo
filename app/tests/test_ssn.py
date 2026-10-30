"""SSN token service. Every SSN here uses the 9xx area, which is never
issued, so none of them can be a real person's number."""

import dataclasses
import logging
import re

import pytest
from fastapi.testclient import TestClient

from demo_app.main import app, get_ssn_service
from demo_app.ssn import FakeEncryptor, InvalidSsn, RevealNotAllowed, SsnTokenService, TokenNotFound
from demo_app.ssn.redact import RedactSsnFilter, redact
from demo_app.ssn.service import TOKEN_RE, hmac_ssn, load_pepper_from_env, normalize_ssn

FAKE_SSN = "900-00-0001"
FAKE_DIGITS = "900000001"
OTHER_SSN = "900-00-0002"
PEPPER = bytes(range(32))  # test-only key
# claimant.ssn_token's CHECK from V6, applied here the way Postgres would.
CLAIMANT_CHECK = re.compile(r"^[0-9]{3}-?[0-9]{2}-?[0-9]{4}$")


class FakeVaultStore:
    """In memory, with the same all-or-nothing reveal as the Postgres store."""

    def __init__(self):
        self.rows = []
        self.audit = []
        self.fail_audit = False

    def find_by_hmac(self, ssn_hmac):
        return next((r for r in self.rows if r.ssn_hmac == ssn_hmac), None)

    def insert(self, row):
        existing = self.find_by_hmac(row.ssn_hmac)
        if existing:
            return existing
        row = dataclasses.replace(row, id=len(self.rows) + 1)
        self.rows.append(row)
        return row

    def reveal(self, token, audit, use):
        row = next((r for r in self.rows if r.ssn_token == token), None)
        if row is None:
            return None
        pending = audit(row)
        if self.fail_audit:
            raise RuntimeError("audit insert failed")
        value = use(row)
        self.audit.append(pending)  # commit
        return value


@pytest.fixture
def store():
    return FakeVaultStore()


@pytest.fixture
def svc(store):
    return SsnTokenService(store, FakeEncryptor(), PEPPER)


@pytest.fixture
def client(svc):
    app.dependency_overrides[get_ssn_service] = lambda: svc
    yield TestClient(app)
    app.dependency_overrides.clear()


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


def test_raw_ssn_only_in_ciphertext(svc, store):
    svc.tokenize(FAKE_SSN)
    svc.reveal(store.rows[0].ssn_token, actor="staff-1", reason="identity check")
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


def test_reveal_needs_actor_and_reason(svc, store):
    token = svc.tokenize(FAKE_SSN).ssn_token
    for actor, reason in [("", "why"), ("staff-1", ""), ("staff-1", "   ")]:
        with pytest.raises(RevealNotAllowed):
            svc.reveal(token, actor=actor, reason=reason)
    assert store.audit == []


def test_reveal_writes_one_audit_row_without_ssn(svc, store):
    token = svc.tokenize(FAKE_SSN).ssn_token
    assert svc.reveal(token, actor="staff-1", reason="claimant called, verifying") == FAKE_DIGITS
    assert len(store.audit) == 1
    a = store.audit[0]
    assert (a.actor, a.action, a.reason, a.record_type) == ("staff-1", "ssn.reveal", "claimant called, verifying", "ssn_vault")
    assert a.after_data == {"ssn_token": token}
    assert FAKE_DIGITS not in repr(a)


def test_failed_audit_returns_no_ssn(svc, store):
    token = svc.tokenize(FAKE_SSN).ssn_token
    store.fail_audit = True
    with pytest.raises(RuntimeError):
        svc.reveal(token, actor="staff-1", reason="why")
    assert store.audit == []


def test_unknown_token(svc):
    with pytest.raises(TokenNotFound):
        svc.reveal("tok_" + "A" * 32, actor="staff-1", reason="why")
    with pytest.raises(TokenNotFound):
        svc.reveal(FAKE_SSN, actor="staff-1", reason="why")


def test_pepper_from_env(monkeypatch):
    monkeypatch.setenv("SSN_HMAC_KEY", "ab" * 32)
    assert load_pepper_from_env() == b"\xab" * 32
    monkeypatch.setenv("SSN_HMAC_KEY", "ab" * 8)
    with pytest.raises(RuntimeError):
        load_pepper_from_env()
    monkeypatch.delenv("SSN_HMAC_KEY")
    with pytest.raises(RuntimeError):
        load_pepper_from_env()


def test_ssn_never_in_logs(svc, caplog):
    caplog.set_level(logging.DEBUG)
    token = svc.tokenize(FAKE_SSN).ssn_token
    svc.reveal(token, actor="staff-1", reason="why")
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

    r = client.post("/ssn/reveal", json={"token": token}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 400 and store.audit == []
    assert r.headers["cache-control"] == "no-store"

    r = client.post("/ssn/reveal", json={"token": token, "reason": "why"})
    assert r.status_code == 401 and store.audit == []

    r = client.post("/ssn/reveal", json={"token": "tok_" + "A" * 32, "reason": "why"}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 404 and store.audit == []

    r = client.post("/ssn/reveal", json={"token": token, "reason": "verify identity"}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 200
    assert r.json() == {"ssn_token": token, "ssn": FAKE_DIGITS}
    assert r.headers["cache-control"] == "no-store"
    assert len(store.audit) == 1 and store.audit[0].actor == "staff-1"


def test_http_reveal_audit_failure_is_503_without_ssn(client, store):
    token = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN}).json()["ssn_token"]
    store.fail_audit = True
    r = client.post("/ssn/reveal", json={"token": token, "reason": "why"}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 503 and FAKE_DIGITS not in r.text


def test_unconfigured_service_is_503(monkeypatch):
    for var in ("SSN_KMS_KEY_ID", "SSN_HMAC_KEY", "SSN_DB_USER", "DB_HOST"):
        monkeypatch.delenv(var, raising=False)
    from demo_app.main import _build_ssn_service

    _build_ssn_service.cache_clear()
    r = TestClient(app).post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    assert r.status_code == 503


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
