"""Testing-only claim seed: the environment guard and the endpoint.

Every SSN here is in the 9xx area, which is never issued."""

import pytest
from fastapi.testclient import TestClient

from demo_app import main
from demo_app.demo_seed import (
    SeedConflict,
    SeedInputError,
    SeedResult,
    TestingOnlyGuard,
    check_seed_input,
    environment_prefix,
    is_testing_prefix,
)
from demo_app.ssn import SsnTokenService, FakeEncryptor
from demo_app.ssn.config import METADATA_ENV, NAME_PREFIX_ENV, SsnConfigError

FARGATE = "http://169.254.170.2/v4/abc"
TOKEN = "tok_" + "A" * 32
HMAC = "ab" * 32


def _meta(family):
    def read(uri):
        return {"Family": family, "TaskARN": "arn:aws:ecs:us-east-2:111122223333:task/x/y"}
    return read


def _boom(uri):
    raise OSError("metadata endpoint down")


# --- the guard -------------------------------------------------------------

@pytest.mark.parametrize("prefix,ok", [
    ("migdemo-testing", True),
    ("other-testing", True),
    ("migdemo-stage", False),
    ("migdemo-production", False),
    ("migdemo-testing-2", False),
    ("migdemo-testingx", False),
    ("-testing", False),
    ("testing", False),
    ("", False),
    (None, False),
])
def test_is_testing_prefix(prefix, ok):
    assert is_testing_prefix(prefix) is ok


@pytest.mark.parametrize("family,ok", [
    ("migdemo-testing-app", True),
    ("migdemo-stage-app", False),
    ("migdemo-production-app", False),
    ("migdemo-testing-migrate", False),  # not the app task: refused
    ("", False),
])
def test_guard_on_ecs_uses_the_task_family(family, ok):
    assert TestingOnlyGuard({METADATA_ENV: FARGATE}, _meta(family)).allowed() is ok


def test_guard_on_ecs_ignores_the_env_override():
    # A stage or production task can't be switched on by setting the env var.
    env = {METADATA_ENV: FARGATE, NAME_PREFIX_ENV: "migdemo-testing"}
    assert TestingOnlyGuard(env, _meta("migdemo-production-app")).allowed() is False
    assert TestingOnlyGuard(env, _meta("migdemo-stage-app")).allowed() is False
    assert environment_prefix(env, _meta("migdemo-stage-app")) == "migdemo-stage"


@pytest.mark.parametrize("env", [
    {},  # prefix unknown
    {METADATA_ENV: FARGATE},  # metadata read fails
    {METADATA_ENV: "http://example.com/v4"},  # not the Fargate endpoint
    {METADATA_ENV: "file:///etc/passwd"},
    {NAME_PREFIX_ENV: "not a valid prefix!"},
])
def test_guard_fails_closed_when_the_prefix_is_unknown(env):
    assert TestingOnlyGuard(env, _boom).allowed() is False


def test_guard_rejects_a_bad_metadata_host_with_the_real_reader():
    # The real reader refuses any host but Fargate's, before any network call.
    assert TestingOnlyGuard({METADATA_ENV: "http://10.0.0.1/v4"}).allowed() is False


@pytest.mark.parametrize("prefix,ok", [("migdemo-testing", True), ("migdemo-stage", False), ("migdemo-production", False)])
def test_guard_off_ecs_uses_the_env_override(prefix, ok):
    assert TestingOnlyGuard({NAME_PREFIX_ENV: prefix}, _boom).allowed() is ok


def test_guard_does_not_cache_a_failure_but_caches_a_good_answer():
    calls = []

    def flaky(uri):
        calls.append(uri)
        if len(calls) == 1:
            raise OSError("not yet")
        return {"Family": "migdemo-testing-app"}

    g = TestingOnlyGuard({METADATA_ENV: FARGATE}, flaky)
    assert g.allowed() is False
    assert g.allowed() is True
    assert g.allowed() is True
    assert len(calls) == 2


def test_environment_prefix_raises_when_unknown():
    with pytest.raises(SsnConfigError):
        environment_prefix({}, _boom)


# --- input checks ----------------------------------------------------------

def test_check_seed_input_accepts_tokenize_output():
    token, h = check_seed_input(TOKEN, HMAC)
    assert token == TOKEN and h == bytes.fromhex(HMAC) and len(h) == 32


@pytest.mark.parametrize("token,hmac", [
    ("900-12-3456", HMAC),  # a raw SSN is never a token
    ("900123456", HMAC),
    ("tok_short", HMAC),
    ("rtk_" + "A" * 32, HMAC),  # a reveal ticket isn't a token
    (None, HMAC),
    (TOKEN, "zz" * 32),
    (TOKEN, "ab" * 31),
    (TOKEN, None),
    (TOKEN, 123),
])
def test_check_seed_input_rejects_bad_values(token, hmac):
    with pytest.raises(SeedInputError) as e:
        check_seed_input(token, hmac)
    assert "900" not in str(e.value)


# --- the endpoint ----------------------------------------------------------

class FakeGuard:
    def __init__(self, ok):
        self.ok = ok

    def allowed(self):
        return self.ok


class FakeSeedStore:
    """Same rules as PostgresSeedStore: one claimant per token and per HMAC,
    one open claim reused, created only when something was added."""

    def __init__(self):
        self.claimants = {}  # token -> (id, hmac)
        self.claims = {}  # claimant_id -> claim_id
        self.calls = 0
        self.fail = False
        self.audit = []

    def seed_claim(self, ssn_token, ssn_hmac, actor):
        self.calls += 1
        if self.fail:
            raise RuntimeError("db down")
        created = False
        if ssn_token not in self.claimants:
            if any(h == ssn_hmac for _, h in self.claimants.values()):
                raise SeedConflict("x")
            self.claimants[ssn_token] = (len(self.claimants) + 1, ssn_hmac)
            created = True
        cid, h = self.claimants[ssn_token]
        if h != ssn_hmac:
            raise SeedConflict("x")
        if cid not in self.claims:
            self.claims[cid] = len(self.claims) + 100
            created = True
        if created:
            self.audit.append((actor, "demo.seed_claim", self.claims[cid]))
        return SeedResult(cid, self.claims[cid], "submitted", 1, created)


@pytest.fixture
def seed_store():
    return FakeSeedStore()


def _client(monkeypatch, ok, store):
    monkeypatch.setattr(main, "get_testing_guard", lambda: FakeGuard(ok))
    monkeypatch.setattr(main, "get_seed_store", lambda: store)
    return TestClient(main.app)


def _post(client, body=None, actor="izzy", **kw):
    headers = {"X-Actor": actor} if actor else {}
    return client.post("/demo/seed-claim", json=body if body is not None else {"ssn_token": TOKEN, "ssn_hmac": HMAC},
                       headers=headers, **kw)


@pytest.mark.parametrize("family", ["migdemo-stage-app", "migdemo-production-app", None])
def test_endpoint_is_a_plain_404_outside_testing(monkeypatch, seed_store, family):
    # Real guard, fed stage, production, or no metadata at all.
    env = {METADATA_ENV: FARGATE} if family else {}
    guard = TestingOnlyGuard(env, _meta(family) if family else _boom)
    monkeypatch.setattr(main, "get_testing_guard", lambda: guard)
    monkeypatch.setattr(main, "get_seed_store", lambda: seed_store)
    client = TestClient(main.app)
    unknown = client.post("/demo/no-such-route", json={})
    for r in (
        _post(client),
        _post(client, actor=None),
        _post(client, body={"ssn": "900-12-3456"}),
        client.post("/demo/seed-claim", content=b"not json", headers={"X-Actor": "izzy"}),
        client.get("/demo/seed-claim"),
        client.delete("/demo/seed-claim"),
    ):
        assert r.status_code == 404
        assert r.json() == unknown.json() == {"detail": "Not Found"}
    assert seed_store.calls == 0


def test_endpoint_seeds_in_testing_and_is_idempotent(monkeypatch, seed_store):
    guard = TestingOnlyGuard({METADATA_ENV: FARGATE}, _meta("migdemo-testing-app"))
    monkeypatch.setattr(main, "get_testing_guard", lambda: guard)
    monkeypatch.setattr(main, "get_seed_store", lambda: seed_store)
    client = TestClient(main.app)
    first = _post(client)
    assert first.status_code == 201
    body = first.json()
    assert body["created"] is True and body["claim_status"] == "submitted"
    assert first.headers["cache-control"] == "no-store"
    again = _post(client)
    assert again.status_code == 200
    assert again.json() == {**body, "created": False}
    assert len(seed_store.audit) == 1
    # Never echoes the token or the HMAC.
    assert TOKEN not in first.text and HMAC not in first.text


def test_endpoint_errors_in_testing(monkeypatch, seed_store):
    client = _client(monkeypatch, True, seed_store)
    assert _post(client, actor=None).status_code == 401
    assert _post(client, actor="   ").status_code == 401
    r = _post(client, body={"ssn_token": "900-12-3456", "ssn_hmac": HMAC})
    assert r.status_code == 400 and "900" not in r.text
    r = client.post("/demo/seed-claim", content=b"not json", headers={"X-Actor": "izzy"})
    assert r.status_code == 422
    assert _post(client, body=["x"]).status_code == 422
    assert client.get("/demo/seed-claim").status_code == 405
    assert seed_store.calls == 0
    # Same HMAC under a different token: someone else's.
    assert _post(client).status_code == 201
    assert _post(client, body={"ssn_token": "tok_" + "B" * 32, "ssn_hmac": HMAC}).status_code == 409
    seed_store.fail = True
    r = _post(client)
    assert r.status_code == 503 and r.json() == {"detail": "database unavailable"}


def test_validation_errors_on_demo_do_not_echo_input(monkeypatch, seed_store):
    # Nothing on /demo uses FastAPI validation today, but if it ever does,
    # the /ssn rule applies: no echo of the input.
    client = _client(monkeypatch, True, seed_store)
    r = _post(client, body={"ssn_token": "900-12-3456"})
    assert "900-12-3456" not in r.text


def test_seed_then_ticket_flow_with_fakes(monkeypatch, store):
    """Tokenize, seed, issue, reveal, reveal again (404), refresh, old
    ticket 404, new ticket 200. The seeded claim is copied into the fake
    vault store, standing in for the shared database."""
    from demo_app.main import get_reauth_verifier, get_ssn_service
    from demo_app.ssn import HeaderReauthVerifier
    import time

    svc = SsnTokenService(store, FakeEncryptor(), bytes(range(32)))
    seed = FakeSeedStore()
    monkeypatch.setattr(main, "get_testing_guard", lambda: FakeGuard(True))
    monkeypatch.setattr(main, "get_seed_store", lambda: seed)
    main.app.dependency_overrides[get_ssn_service] = lambda: svc
    main.app.dependency_overrides[get_reauth_verifier] = lambda: HeaderReauthVerifier()
    try:
        c = TestClient(main.app)
        tok = c.post("/ssn/tokenize", json={"ssn": "900-12-3456"}).json()
        s = c.post("/demo/seed-claim", json=tok, headers={"X-Actor": "izzy"})
        assert s.status_code == 201
        claim_id = s.json()["claim_id"]
        store.add_claim(claim_id, tok["ssn_token"])
        h = {"X-Actor": "izzy"}
        t1 = c.post("/ssn/tickets", json={"ssn_token": tok["ssn_token"], "claim_id": claim_id, "reason": "demo"}, headers=h)
        assert t1.status_code == 201
        t1 = t1.json()["ticket"]
        r = c.post("/ssn/reveal", json={"ticket": t1, "reason": "demo"}, headers=h)
        assert r.status_code == 200 and r.json()["ssn"] == "900123456"
        assert c.post("/ssn/reveal", json={"ticket": t1, "reason": "demo"}, headers=h).status_code == 404
        t2 = c.post("/ssn/tickets", json={"ssn_token": tok["ssn_token"], "claim_id": claim_id, "reason": "demo"}, headers=h).json()["ticket"]
        reauth = {**h, "X-Reauth-Actor": "izzy", "X-Reauth-At": str(int(time.time()))}
        t3 = c.post("/ssn/tickets/refresh", json={"ticket": t2, "reason": "demo"}, headers=reauth)
        assert t3.status_code == 201
        t3 = t3.json()["ticket"]
        assert c.post("/ssn/reveal", json={"ticket": t2, "reason": "demo"}, headers=h).status_code == 404
        assert c.post("/ssn/reveal", json={"ticket": t3, "reason": "demo"}, headers=h).status_code == 200
    finally:
        main.app.dependency_overrides.clear()
