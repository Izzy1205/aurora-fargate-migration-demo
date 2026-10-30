"""Runtime config for the SSN token service: name prefix, KMS alias, pepper
secret, IAM DB auth, caching and fail-closed 503s. AWS is stubbed with
botocore's Stubber, so nothing here calls a real account. Fake SSNs use the
never-issued 9xx area."""

import logging

import boto3
import pytest
from botocore.stub import Stubber
from fastapi.testclient import TestClient

from demo_app import main
from demo_app.ssn import FakeEncryptor, KmsEncryptor, SsnTokenService
from demo_app.ssn.config import (
    CachedOnSuccess,
    SsnConfigError,
    fetch_task_metadata,
    iam_auth_password,
    load_runtime_config,
    resolve_name_prefix,
    resolve_region,
)

REGION = "us-east-2"
KEY_ARN = "arn:aws:kms:us-east-2:000000000000:key/11111111-2222-3333-4444-555555555555"
PEPPER_HEX = bytes(range(32)).hex()  # test-only value
FAKE_SSN = "900-00-0001"
META = {
    "Family": "migdemo-testing-app",
    "TaskARN": "arn:aws:ecs:us-east-2:000000000000:task/migdemo-testing/abc",
}
ECS_ENV = {"ECS_CONTAINER_METADATA_URI_V4": "http://169.254.170.2/v4/abc", "AWS_REGION": REGION}


def client_for(service):
    return boto3.session.Session(
        region_name=REGION, aws_access_key_id="testing", aws_secret_access_key="testing"  # nosec B106 - fake
    ).client(service)


class Aws:
    """Stubbed kms and secretsmanager clients handed out by name."""

    def __init__(self):
        self.kms = client_for("kms")
        self.sm = client_for("secretsmanager")
        self.kms_stub = Stubber(self.kms)
        self.sm_stub = Stubber(self.sm)
        self.kms_stub.activate()
        self.sm_stub.activate()

    def __call__(self, service, region):
        assert region == REGION
        return {"kms": self.kms, "secretsmanager": self.sm}[service]

    def key_ok(self, alias="alias/migdemo-testing-ssn", state="Enabled"):
        self.kms_stub.add_response(
            "describe_key",
            {"KeyMetadata": {"KeyId": KEY_ARN.rsplit("/", 1)[1], "Arn": KEY_ARN, "KeyState": state}},
            {"KeyId": alias},
        )

    def pepper(self, value=PEPPER_HEX, name="migdemo-testing/ssn/hmac-pepper"):
        self.sm_stub.add_response(
            "get_secret_value", {"Name": name, "SecretString": value}, {"SecretId": name}
        )


@pytest.fixture
def aws():
    return Aws()


def meta(_uri):
    return META


# name prefix ----------------------------------------------------------------

def test_prefix_from_task_family():
    assert resolve_name_prefix(ECS_ENV, meta) == ("migdemo-testing", META)


def test_prefix_override_skips_metadata():
    def boom(_uri):
        raise AssertionError("metadata should not be read")

    assert resolve_name_prefix({"SSN_NAME_PREFIX": "migdemo-local"}, boom)[0] == "migdemo-local"


@pytest.mark.parametrize("env", [{}, {"SSN_NAME_PREFIX": "Bad Prefix!"}])
def test_prefix_missing_or_invalid(env):
    with pytest.raises(SsnConfigError):
        resolve_name_prefix(env, meta)


def test_prefix_rejects_other_family():
    with pytest.raises(SsnConfigError, match="-app"):
        resolve_name_prefix(ECS_ENV, lambda _u: {"Family": "migdemo-testing-migrate"})


def test_metadata_failure_is_config_error():
    def down(_uri):
        raise OSError("connection refused")

    with pytest.raises(SsnConfigError, match="OSError"):
        resolve_name_prefix(ECS_ENV, down)


@pytest.mark.parametrize("uri", ["file:///etc/passwd", "http://example.com/v4/x", "https://169.254.170.2/v4"])
def test_metadata_only_from_fargate_endpoint(uri):
    with pytest.raises(SsnConfigError):
        fetch_task_metadata(uri)


def test_region_from_env_then_task_arn():
    assert resolve_region({"AWS_REGION": "us-west-2"}, META) == "us-west-2"
    assert resolve_region({}, META) == "us-east-2"
    with pytest.raises(SsnConfigError):
        resolve_region({}, None)


# KMS alias and pepper -------------------------------------------------------

def test_load_runtime_config(aws):
    aws.key_ok()
    aws.pepper()
    cfg = load_runtime_config(ECS_ENV, aws, meta)
    assert cfg.name_prefix == "migdemo-testing"
    assert cfg.key_alias == "alias/migdemo-testing-ssn"
    assert cfg.key_arn == KEY_ARN
    assert cfg.pepper == bytes(range(32))
    assert cfg.db_user == "ssn_vault_login"
    assert PEPPER_HEX not in repr(cfg)
    aws.kms_stub.assert_no_pending_responses()
    aws.sm_stub.assert_no_pending_responses()


def test_missing_kms_key(aws):
    aws.kms_stub.add_client_error("describe_key", "NotFoundException", "Alias arn:aws:kms:... is not found.")
    with pytest.raises(SsnConfigError) as err:
        load_runtime_config(ECS_ENV, aws, meta)
    assert "NotFoundException" in str(err.value) and "arn:" not in str(err.value)


def test_disabled_kms_key(aws):
    aws.key_ok(state="Disabled")
    with pytest.raises(SsnConfigError, match="not enabled"):
        load_runtime_config(ECS_ENV, aws, meta)


def test_pepper_never_set(aws):
    # What Secrets Manager answers for a secret Terraform made with no value.
    aws.key_ok()
    aws.sm_stub.add_client_error(
        "get_secret_value", "ResourceNotFoundException", "can't find the specified secret value"
    )
    with pytest.raises(SsnConfigError, match="no value yet"):
        load_runtime_config(ECS_ENV, aws, meta)


def test_pepper_access_denied(aws):
    aws.key_ok()
    aws.sm_stub.add_client_error("get_secret_value", "AccessDeniedException", "not authorized on arn:...")
    with pytest.raises(SsnConfigError) as err:
        load_runtime_config(ECS_ENV, aws, meta)
    assert "AccessDeniedException" in str(err.value) and "arn:" not in str(err.value)


@pytest.mark.parametrize("value", ["not-hex", "00" * 16])
def test_bad_pepper_value_is_not_echoed(aws, value):
    aws.key_ok()
    aws.pepper(value)
    with pytest.raises(SsnConfigError) as err:
        load_runtime_config(ECS_ENV, aws, meta)
    assert value not in str(err.value)


# IAM DB auth -----------------------------------------------------------------

def test_iam_auth_token_per_connection():
    rds = client_for("rds")
    token = iam_auth_password(rds, "db.example.internal", 5432, "ssn_vault_login", REGION)
    t1 = token()
    assert t1.startswith("db.example.internal:5432/?Action=connect") and "DBUser=ssn_vault_login" in t1


# caching -----------------------------------------------------------------------

def test_cache_keeps_success_and_backs_off_on_failure():
    now = [0.0]
    calls = []

    def build():
        calls.append(1)
        if len(calls) == 1:
            raise SsnConfigError("first try fails")
        return "ok"

    cache = CachedOnSuccess(build, retry_after=30, clock=lambda: now[0])
    with pytest.raises(SsnConfigError):
        cache.get()
    now[0] = 10
    with pytest.raises(SsnConfigError):
        cache.get()  # inside the back-off, not rebuilt
    assert len(calls) == 1
    now[0] = 31
    assert cache.get() == "ok" and cache.get() == "ok"
    assert len(calls) == 2


# end to end through the HTTP API with the real builder ------------------------

class MemoryStore:
    def __init__(self):
        self.rows, self.audit = [], []

    def find_by_hmac(self, h):
        return next((r for r in self.rows if r.ssn_hmac == h), None)

    def insert(self, row):
        import dataclasses

        if (found := self.find_by_hmac(row.ssn_hmac)) is not None:
            return found
        row = dataclasses.replace(row, id=len(self.rows) + 1)
        self.rows.append(row)
        return row

    def reveal(self, token, audit, use):
        row = next((r for r in self.rows if r.ssn_token == token), None)
        if row is None:
            return None
        entry = audit(row)
        value = use(row)
        self.audit.append(entry)
        return value


@pytest.fixture
def wired(monkeypatch, aws):
    """The real _build_ssn_service with AWS stubbed, the metadata endpoint
    faked and an in-memory store."""
    monkeypatch.setenv("ECS_CONTAINER_METADATA_URI_V4", ECS_ENV["ECS_CONTAINER_METADATA_URI_V4"])
    monkeypatch.setenv("AWS_REGION", REGION)
    monkeypatch.delenv("SSN_NAME_PREFIX", raising=False)
    monkeypatch.delenv("SSN_DB_PASSWORD", raising=False)
    monkeypatch.setenv("DB_HOST", "db.example.internal")
    monkeypatch.setenv("DB_NAME", "demo")
    store = MemoryStore()
    seen = {}

    def fake_store(settings, password_provider=None):
        seen["settings"], seen["provider"] = settings, password_provider
        return store

    monkeypatch.setattr(main, "PostgresVaultStore", fake_store)
    monkeypatch.setattr(main, "load_runtime_config", lambda: load_runtime_config(dict(ECS_ENV), aws, meta))
    monkeypatch.setattr(main, "KmsEncryptor", lambda key_id, client: FakeEncryptor())
    main._ssn_service.reset()
    yield TestClient(main.app), aws, store, seen
    main._ssn_service.reset()


def test_wired_tokenize_and_reveal(wired):
    client, aws, store, seen = wired
    aws.key_ok()
    aws.pepper()
    r = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    assert r.status_code == 201
    token = r.json()["ssn_token"]
    assert seen["settings"].user == "ssn_vault_login" and seen["settings"].password == ""
    assert seen["provider"] is not None  # IAM auth token per connection
    r = client.post("/ssn/reveal", json={"token": token, "reason": "case 1"}, headers={"X-Actor": "staff-1"})
    assert r.status_code == 200 and r.json()["ssn"] == "900000001"
    assert len(store.audit) == 1 and store.audit[0].after_data == {"ssn_token": token}
    # Config was read once and cached: no more stubbed responses were used.
    assert client.post("/ssn/tokenize", json={"ssn": FAKE_SSN}).status_code == 200


def test_wired_missing_pepper_is_503_with_safe_log(wired, caplog):
    client, aws, _store, _seen = wired
    aws.key_ok()
    aws.sm_stub.add_client_error("get_secret_value", "ResourceNotFoundException", "no value")
    with caplog.at_level(logging.WARNING, logger="demo_app"):
        r = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    assert r.status_code == 503 and r.json() == {"detail": "ssn service unavailable"}
    assert "pepper secret missing or has no value yet" in caplog.text
    assert "900" not in caplog.text and "arn:" not in caplog.text


def test_wired_missing_key_is_503(wired):
    client, aws, _store, _seen = wired
    aws.kms_stub.add_client_error("describe_key", "NotFoundException", "not found")
    r = client.post("/ssn/reveal", json={"token": "tok_" + "A" * 32, "reason": "x"}, headers={"X-Actor": "a"})
    assert r.status_code == 503


def test_kms_failure_on_reveal_is_503_and_rolls_back(monkeypatch):
    """KMS Decrypt fails after the audit row is written: no SSN comes back,
    and the store's transaction (here, the in-memory commit) never lands."""
    store = MemoryStore()
    kms = client_for("kms")
    stub = Stubber(kms)
    stub.activate()
    stub.add_response("encrypt", {"CiphertextBlob": b"blob", "KeyId": KEY_ARN})
    stub.add_client_error("decrypt", "KMSInvalidStateException", "key disabled")
    svc = SsnTokenService(store, KmsEncryptor(KEY_ARN, client=kms), bytes(range(32)))
    main.app.dependency_overrides[main.get_ssn_service] = lambda: svc
    try:
        client = TestClient(main.app)
        token = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN}).json()["ssn_token"]
        r = client.post("/ssn/reveal", json={"token": token, "reason": "x"}, headers={"X-Actor": "a"})
    finally:
        main.app.dependency_overrides.clear()
    assert r.status_code == 503 and "900" not in r.text
    assert store.audit == []


def test_kms_failure_on_tokenize_is_503(monkeypatch):
    kms = client_for("kms")
    stub = Stubber(kms)
    stub.activate()
    stub.add_client_error("encrypt", "AccessDeniedException", "denied")
    svc = SsnTokenService(MemoryStore(), KmsEncryptor(KEY_ARN, client=kms), bytes(range(32)))
    main.app.dependency_overrides[main.get_ssn_service] = lambda: svc
    try:
        r = TestClient(main.app).post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    finally:
        main.app.dependency_overrides.clear()
    assert r.status_code == 503 and "900" not in r.text


def test_malformed_and_unknown_tickets(wired):
    client, aws, _store, _seen = wired
    aws.key_ok()
    aws.pepper()
    h = {"X-Actor": "staff-1"}
    # Tickets are permanent identifiers stored on claimant rows; there is no
    # expiry. A ticket is either well formed and known, or it is refused.
    for bad in ("", "tok_short", "900-00-0001", "tok_" + "!" * 32):
        r = client.post("/ssn/reveal", json={"token": bad, "reason": "x"}, headers=h)
        assert r.status_code == 404 and "900" not in r.text
    r = client.post("/ssn/reveal", json={"token": "tok_" + "B" * 32, "reason": "x"}, headers=h)
    assert r.status_code == 404
