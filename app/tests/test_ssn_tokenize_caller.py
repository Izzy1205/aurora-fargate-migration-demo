"""The caller check, audit row and per-caller rate limit on /ssn/tokenize.
Fake 9xx SSNs only."""

import json
import logging

import pytest

from demo_app import ssn_events, vault
from demo_app.demo_seed import TestingOnlyGuard
from demo_app.ssn import callers as callers_mod
from demo_app.ssn.callers import (
    CALLERS_ENV,
    DEFAULT_CALLERS,
    DEMO_CALLER,
    REJECT_NO_CALLER,
    REJECT_UNKNOWN_CALLER,
    CallerPolicy,
    policy_from_env,
    read_callers,
)
from demo_app.ssn.ratelimit import TOKENIZE_BUCKET, SlidingWindowLimiter
from demo_app.ssn.service import RevealNotAllowed, hmac_ssn
from demo_app.ssn_api import CALLER_NOT_ALLOWED, TOO_MANY, get_rate_limiter, get_tokenize_callers
from demo_app.ssn_vault_client import EVENT_LOGGER
from conftest import CALLER, CALLER_NAME, PEPPER  # noqa: E402

FAKE_SSN = "900-66-0001"
FAKE_DIGITS = "900660001"


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def limits(clock):
    """A small limiter on a fake clock: 2 tokenizes per caller."""
    lim = SlidingWindowLimiter({TOKENIZE_BUCKET: 2}, clock=clock)
    vault.app.dependency_overrides[get_rate_limiter] = lambda: lim
    yield lim
    vault.app.dependency_overrides.pop(get_rate_limiter, None)


class Events(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())

    def docs(self, event=None):
        out = [json.loads(line) for line in self.lines]
        return [d for d in out if event is None or d["event"] == event]


@pytest.fixture
def events(monkeypatch):
    monkeypatch.setenv("SSN_NAME_PREFIX", "migdemo-testing")
    ssn_events._prefix.reset()
    h = Events()
    lg = logging.getLogger(EVENT_LOGGER)
    lg.addHandler(h)
    yield h
    lg.removeHandler(h)
    ssn_events._prefix.reset()


def tokenize(client, ssn=FAKE_SSN, headers=CALLER):
    return client.post("/ssn/tokenize", json={"ssn": ssn}, headers=headers)


def assert_refused(r):
    assert r.status_code == 403
    assert r.json() == {"detail": CALLER_NOT_ALLOWED}
    assert r.headers["cache-control"] == "no-store" and r.headers["pragma"] == "no-cache"


# --- allowed caller: token and one audit row


def test_allowed_caller_gets_201_then_200_with_an_audit_row_each(client, store):
    r = tokenize(client)
    assert r.status_code == 201
    again = tokenize(client, FAKE_DIGITS, {"X-Caller": "wage-loader"})
    assert again.status_code == 200 and again.json() == r.json()
    [vault_row] = store.rows
    assert [(a.actor, a.action, a.record_type, a.record_id, a.reason, a.after_data) for a in store.audit] == [
        (CALLER_NAME, "ssn.tokenize", "ssn_vault", vault_row.id, None, {"created": True}),
        ("wage-loader", "ssn.tokenize", "ssn_vault", vault_row.id, None, {"created": False}),
    ]


def test_caller_is_stripped(client, store):
    assert tokenize(client, headers={"X-Caller": f"  {CALLER_NAME} "}).status_code == 201
    assert store.audit[0].actor == CALLER_NAME


def test_service_needs_a_caller(svc, store):
    with pytest.raises(RevealNotAllowed):
        svc.tokenize(FAKE_SSN, caller=" ")
    assert store.rows == [] and store.audit == []


def test_failed_audit_write_returns_no_token_and_keeps_no_row(client, store):
    store.fail_audit = True
    r = tokenize(client)
    assert r.status_code == 503 and "tok_" not in r.text
    assert store.rows == [] and store.audit == []
    store.fail_audit = False
    assert tokenize(client).status_code == 201
    store.fail_audit = True
    r = tokenize(client)  # existing SSN, audit fails: still no token
    assert r.status_code == 503 and "tok_" not in r.text
    assert len(store.audit) == 1


def test_bad_ssn_writes_no_audit_row(client, store):
    assert tokenize(client, "900-00-00019").status_code == 400
    assert store.audit == []


# --- missing or unknown caller: 403, nothing written


@pytest.mark.parametrize(
    "headers,category",
    [
        ({}, REJECT_NO_CALLER),
        ({"X-Caller": ""}, REJECT_NO_CALLER),
        ({"X-Caller": "   "}, REJECT_NO_CALLER),
        ({"X-Caller": "someone-else"}, REJECT_UNKNOWN_CALLER),
        ({"X-Caller": "Claimant-Signup"}, REJECT_UNKNOWN_CALLER),  # exact names only
        ({"X-Caller": DEMO_CALLER}, REJECT_UNKNOWN_CALLER),  # demo is off outside -testing
        ({"X-Actor": "staff-1"}, REJECT_NO_CALLER),  # a staff actor is not a caller
    ],
)
def test_missing_or_unknown_caller_is_403_and_writes_nothing(client, store, events, headers, category):
    assert_refused(tokenize(client, headers=headers))
    assert store.rows == [] and store.audit == []
    [d] = events.docs("ssn_caller_rejected")
    assert (d["route"], d["reason"], d["ssn_caller_rejected"]) == ("/ssn/tokenize", category, 1)
    [directive] = d["_aws"]["CloudWatchMetrics"]
    assert directive["Namespace"] == "MigDemo/SsnVault" and directive["Dimensions"] == [["NamePrefix"]]
    assert {m["Name"] for m in directive["Metrics"]} == {"ssn_caller_rejected"}
    assert not events.docs("ssn_audited")


def test_unknown_caller_name_is_not_logged(client, events, caplog):
    caplog.set_level(logging.DEBUG)
    assert_refused(tokenize(client, headers={"X-Caller": "probe-caller-41"}))
    text = "\n".join(events.lines + [r.getMessage() for r in caplog.records])
    assert "probe-caller-41" not in text


def test_existing_ssn_is_not_revealed_to_an_unknown_caller(client):
    assert tokenize(client).status_code == 201
    # Same answer whether the vault has the SSN or not.
    a = tokenize(client, headers={"X-Caller": "nope"})
    b = tokenize(client, "900-66-0002", headers={"X-Caller": "nope"})
    assert_refused(a)
    assert_refused(b)
    assert a.content == b.content


def test_demo_caller_only_when_the_policy_allows_it(client, store):
    vault.app.dependency_overrides[get_tokenize_callers] = lambda: CallerPolicy(DEFAULT_CALLERS, lambda: True)
    assert tokenize(client, headers={"X-Caller": DEMO_CALLER}).status_code == 201
    assert store.audit[0].actor == DEMO_CALLER


# --- per-caller rate limit


def test_tokenize_limit_returns_429_with_retry_after(client, store, limits, clock, events):
    assert tokenize(client).status_code == 201
    assert tokenize(client).status_code == 200
    r = tokenize(client)
    assert r.status_code == 429 and r.json() == {"detail": TOO_MANY}
    assert r.headers["cache-control"] == "no-store" and int(r.headers["retry-after"]) >= 1
    assert len(store.audit) == 2  # the 429 wrote nothing
    [d] = events.docs("ssn_rate_limited")
    assert (d["route"], d["bucket"], d["limit"]) == ("/ssn/tokenize", "tokenize", 2)
    clock.now += 61
    assert tokenize(client).status_code == 200


def test_tokenize_limit_is_per_caller(client, limits):
    for _ in range(2):
        tokenize(client)
    assert tokenize(client).status_code == 429
    assert tokenize(client, headers={"X-Caller": "wage-loader"}).status_code == 200


def test_refused_callers_do_not_count_but_bad_ssns_do(client, limits):
    for _ in range(5):
        assert_refused(tokenize(client, headers={"X-Caller": "nope"}))
    assert tokenize(client, "12").status_code == 400
    assert tokenize(client).status_code == 201
    assert tokenize(client).status_code == 429


# --- nothing secret in the audit row or the logs


def test_no_ssn_hmac_or_token_in_audit_rows_or_logs(client, store, events, caplog):
    caplog.set_level(logging.DEBUG)
    r = tokenize(client)
    tokenize(client)
    tokenize(client, headers={"X-Caller": "nope"})
    token, hmac_hex = r.json()["ssn_token"], r.json()["ssn_hmac"]
    assert hmac_hex == hmac_ssn(PEPPER, FAKE_DIGITS).hex()
    audit = repr(store.audit)
    text = "\n".join(events.lines + [rec.getMessage() for rec in caplog.records])
    for secret in [FAKE_SSN, FAKE_DIGITS, token, hmac_hex, hmac_ssn(PEPPER, FAKE_DIGITS).decode("latin-1")]:
        assert secret not in audit
        assert secret not in text
    assert CALLER_NAME not in text  # the caller goes in the audit row only
    for a in store.audit:
        assert set(a.after_data) == {"created"}


# --- the allowlist


def test_default_allowlist():
    assert read_callers({}) == DEFAULT_CALLERS == frozenset({"claimant-signup", "wage-loader"})
    assert read_callers({CALLERS_ENV: "  "}) == DEFAULT_CALLERS


def test_env_replaces_the_allowlist():
    assert read_callers({CALLERS_ENV: " sign-up-v2 , wage-loader "}) == frozenset({"sign-up-v2", "wage-loader"})


@pytest.mark.parametrize("bad", ["Bad Name", "-x", "a" * 64, "demo", "x;y", ",,,"])
def test_bad_names_are_dropped_and_none_left_means_default(bad, caplog):
    caplog.set_level(logging.WARNING)
    assert read_callers({CALLERS_ENV: bad}) == DEFAULT_CALLERS
    assert read_callers({CALLERS_ENV: f"{bad},wage-loader"}) == frozenset({"wage-loader"})
    # The variable name only, never the value.
    for rec in caplog.records:
        assert CALLERS_ENV in rec.getMessage()
        if bad.strip(","):
            assert bad not in rec.getMessage()


def test_demo_needs_a_testing_environment():
    on = policy_from_env({"SSN_NAME_PREFIX": "migdemo-testing"})
    off = policy_from_env({"SSN_NAME_PREFIX": "migdemo-prod"})
    unknown = policy_from_env({})
    assert on.check(DEMO_CALLER).caller == DEMO_CALLER
    assert off.check(DEMO_CALLER).caller is None
    assert unknown.check(DEMO_CALLER).caller is None
    for p in (on, off, unknown):
        assert p.check("wage-loader").caller == "wage-loader"
        assert p.check(None).reason == REJECT_NO_CALLER


@pytest.mark.parametrize("family,allowed", [("migdemo-prod-ssn-vault", False), ("migdemo-testing-ssn-vault", True)])
def test_on_ecs_the_task_family_decides_not_the_env_var(family, allowed):
    env = {"SSN_NAME_PREFIX": "migdemo-testing", "ECS_CONTAINER_METADATA_URI_V4": "http://169.254.170.2/v4/x"}
    guard = TestingOnlyGuard(env, metadata=lambda uri: {"Family": family})
    assert (CallerPolicy(DEFAULT_CALLERS, guard.allowed).check(DEMO_CALLER).caller == DEMO_CALLER) is allowed


def test_vault_builds_the_policy_once(monkeypatch):
    vault.app.dependency_overrides.pop(get_tokenize_callers, None)
    monkeypatch.setenv(CALLERS_ENV, "one-caller")
    get_tokenize_callers.cache_clear()
    assert get_tokenize_callers().services == frozenset({"one-caller"})
    monkeypatch.setenv(CALLERS_ENV, "other-caller")
    assert get_tokenize_callers().services == frozenset({"one-caller"})
    get_tokenize_callers.cache_clear()


def test_callers_module_never_logs_a_value():
    src = open(callers_mod.__file__).read()
    lines = [line for line in src.splitlines() if "log." in line]
    assert lines and all(line.rstrip().endswith(", name)") for line in lines)
