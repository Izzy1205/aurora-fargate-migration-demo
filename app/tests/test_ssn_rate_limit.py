"""Per-actor rate limit on the vault's tokenize, ticket and reveal routes,
and the metric lines behind the SSN audit alarms. Fake 9xx SSNs only.
The tokenize caller check and its limit over HTTP are in
test_ssn_tokenize_caller.py."""

import json
import logging
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from demo_app import ssn_events, vault
from demo_app.ssn import ratelimit
from demo_app.ssn.ratelimit import (
    DEFAULT_REVEAL_LIMIT,
    DEFAULT_TICKET_LIMIT,
    DEFAULT_TOKENIZE_LIMIT,
    REVEAL_BUCKET,
    REVEAL_LIMIT_ENV,
    TICKET_LIMIT_ENV,
    TICKETS_BUCKET,
    TOKENIZE_BUCKET,
    TOKENIZE_LIMIT_ENV,
    SlidingWindowLimiter,
    limiter_from_env,
)
from demo_app.ssn_api import TICKET_GONE, TOO_MANY, get_rate_limiter
from demo_app.ssn_vault_client import EVENT_LOGGER, RETURN_HEADERS
from conftest import CALLER, CALLER_NAME  # noqa: E402

FAKE_SSN = "900-55-0001"
ROOT = Path(__file__).resolve().parents[2]


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
    """Swap in a small limiter on a fake clock: 3 reveals, 2 ticket calls,
    2 tokenizes."""
    lim = SlidingWindowLimiter({REVEAL_BUCKET: 3, TICKETS_BUCKET: 2, TOKENIZE_BUCKET: 2}, clock=clock)
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


def reveal(client, ticket, actor="staff-1"):
    return client.post("/ssn/reveal", json={"ticket": ticket, "reason": "identity check"}, headers={"X-Actor": actor})


def tickets(client, token, claim_id, actor="staff-1"):
    body = {"ssn_token": token, "claim_id": claim_id, "reason": "identity check"}
    return client.post("/ssn/tickets", json=body, headers={"X-Actor": actor})


def assert_429(r):
    assert r.status_code == 429
    assert r.json() == {"detail": TOO_MANY}
    assert r.headers["cache-control"] == "no-store" and r.headers["pragma"] == "no-cache"
    assert int(r.headers["retry-after"]) >= 1


# --- the limiter on its own


def test_under_the_limit_is_allowed_and_the_next_is_not(clock):
    lim = SlidingWindowLimiter({REVEAL_BUCKET: 3}, clock=clock)
    assert [lim.check(REVEAL_BUCKET, "a").allowed for _ in range(4)] == [True, True, True, False]


def test_window_slides(clock):
    lim = SlidingWindowLimiter({REVEAL_BUCKET: 2}, clock=clock)
    assert lim.check(REVEAL_BUCKET, "a").allowed
    clock.now += 30
    assert lim.check(REVEAL_BUCKET, "a").allowed
    denied = lim.check(REVEAL_BUCKET, "a")
    assert not denied.allowed and denied.retry_after == 30  # the first hit leaves the window in 30 s
    clock.now += 30
    assert lim.check(REVEAL_BUCKET, "a").allowed  # first hit has aged out
    assert not lim.check(REVEAL_BUCKET, "a").allowed
    clock.now += 61
    assert lim.check(REVEAL_BUCKET, "a").allowed and lim.check(REVEAL_BUCKET, "a").allowed


def test_denied_requests_do_not_count(clock):
    lim = SlidingWindowLimiter({REVEAL_BUCKET: 1}, clock=clock)
    assert lim.check(REVEAL_BUCKET, "a").allowed
    for _ in range(50):
        clock.now += 1
        assert not lim.check(REVEAL_BUCKET, "a").allowed
    clock.now = 1000.0 + 60.5
    assert lim.check(REVEAL_BUCKET, "a").allowed


def test_actors_and_buckets_are_separate(clock):
    lim = SlidingWindowLimiter({REVEAL_BUCKET: 1, TICKETS_BUCKET: 1}, clock=clock)
    assert lim.check(REVEAL_BUCKET, "a").allowed
    assert not lim.check(REVEAL_BUCKET, "a").allowed
    assert lim.check(REVEAL_BUCKET, "b").allowed
    assert lim.check(TICKETS_BUCKET, "a").allowed


def test_key_count_is_bounded(clock):
    lim = SlidingWindowLimiter({REVEAL_BUCKET: 1}, clock=clock, max_keys=10)
    for i in range(100):
        lim.check(REVEAL_BUCKET, f"actor-{i}")
    assert len(lim._hits) <= 11
    # the most recent actor is still tracked
    assert not lim.check(REVEAL_BUCKET, "actor-99").allowed


DEFAULTS = {
    REVEAL_BUCKET: DEFAULT_REVEAL_LIMIT,
    TICKETS_BUCKET: DEFAULT_TICKET_LIMIT,
    TOKENIZE_BUCKET: DEFAULT_TOKENIZE_LIMIT,
}


def test_defaults_when_env_is_unset():
    lim = limiter_from_env({})
    assert lim.limits == DEFAULTS
    assert (DEFAULT_REVEAL_LIMIT, DEFAULT_TICKET_LIMIT, DEFAULT_TOKENIZE_LIMIT) == (5, 10, 60)
    assert lim.window == 60


def test_env_sets_the_limits():
    lim = limiter_from_env({REVEAL_LIMIT_ENV: "2", TICKET_LIMIT_ENV: " 7 ", TOKENIZE_LIMIT_ENV: "30"})
    assert lim.limits == {REVEAL_BUCKET: 2, TICKETS_BUCKET: 7, TOKENIZE_BUCKET: 30}


@pytest.mark.parametrize("bad", ["0", "-1", "1001", "five", "2.5", "1e3"])
def test_bad_env_falls_back_to_the_default(bad, caplog):
    caplog.set_level(logging.WARNING)
    lim = limiter_from_env({REVEAL_LIMIT_ENV: bad, TICKET_LIMIT_ENV: bad, TOKENIZE_LIMIT_ENV: bad})
    assert lim.limits == DEFAULTS
    # The variable name and the default, never the value that was set.
    heads = {r.getMessage().split(", using the default")[0] for r in caplog.records}
    names = (REVEAL_LIMIT_ENV, TICKET_LIMIT_ENV, TOKENIZE_LIMIT_ENV)
    assert heads <= {f"{n} is out of range" for n in names} | {f"{n} is not a whole number" for n in names}
    assert len(caplog.records) == 3


def test_vault_reads_the_env_once(monkeypatch):
    monkeypatch.setenv(REVEAL_LIMIT_ENV, "3")
    get_rate_limiter.cache_clear()
    assert get_rate_limiter().limits[REVEAL_BUCKET] == 3
    monkeypatch.setenv(REVEAL_LIMIT_ENV, "9")
    assert get_rate_limiter().limits[REVEAL_BUCKET] == 3


# --- over HTTP, on the vault


def test_reveal_limit_returns_429(client, issue, limits):
    ok = [issue(FAKE_SSN.replace("0001", f"000{i}"))[1].ticket for i in range(1, 4)]
    for t in ok:
        r = reveal(client, t)
        assert r.status_code == 200 and r.json()["ssn"].startswith("900")
    _, spare = issue("900-55-0009")
    assert_429(reveal(client, spare.ticket))


def test_404s_count_toward_the_reveal_limit(client, limits, issue):
    for _ in range(3):
        r = reveal(client, "rtk_" + "B" * 32)
        assert r.status_code == 404 and r.json() == {"detail": TICKET_GONE}
    _, good = issue(FAKE_SSN)
    assert_429(reveal(client, good.ticket))


def test_429_does_not_burn_the_ticket(client, store, issue, limits, clock):
    for _ in range(3):
        reveal(client, "rtk_" + "B" * 32)
    _, t = issue(FAKE_SSN)
    assert_429(reveal(client, t.ticket))
    assert not [a for a in store.audit if a.action == "ssn.reveal"]
    clock.now += 61
    assert reveal(client, t.ticket).status_code == 200


def test_limit_is_per_actor(client, issue, limits):
    for _ in range(3):
        reveal(client, "rtk_" + "B" * 32, actor="staff-1")
    assert_429(reveal(client, "rtk_" + "B" * 32, actor="staff-1"))
    assert_429(reveal(client, "rtk_" + "B" * 32, actor=" staff-1 "))  # same actor once stripped
    _, t = issue(FAKE_SSN, actor="staff-2")
    assert reveal(client, t.ticket, actor="staff-2").status_code == 200


def test_window_reset_over_http(client, limits, clock):
    for _ in range(3):
        reveal(client, "rtk_" + "B" * 32)
    assert_429(reveal(client, "rtk_" + "B" * 32))
    clock.now += 61
    assert reveal(client, "rtk_" + "B" * 32).status_code == 404


def test_ticket_issue_and_refresh_share_a_bucket(client, svc, store, limits, reauth_clock):
    token = svc.tokenize(FAKE_SSN, caller=CALLER_NAME).ssn_token
    store.add_claim(11, token)
    r = tickets(client, token, 11)
    assert r.status_code == 201
    h = {"X-Actor": "staff-1", "X-Reauth-Actor": "staff-1", "X-Reauth-At": str(int(reauth_clock["now"]))}
    r2 = client.post("/ssn/tickets/refresh", json={"ticket": r.json()["ticket"], "reason": "x"}, headers=h)
    assert r2.status_code == 201
    assert_429(tickets(client, token, 11))
    assert_429(client.post("/ssn/tickets/refresh", json={"ticket": r2.json()["ticket"], "reason": "x"}, headers=h))
    # reveal has its own bucket
    assert reveal(client, r2.json()["ticket"]).status_code == 200


def test_missing_actor_or_reason_is_not_counted(client, limits):
    for _ in range(10):
        assert client.post("/ssn/reveal", json={"ticket": "rtk_x", "reason": "x"}).status_code == 401
        r = client.post("/ssn/reveal", json={"ticket": "rtk_x"}, headers={"X-Actor": "staff-1"})
        assert r.status_code == 400
    assert reveal(client, "rtk_" + "B" * 32).status_code == 404


def test_default_limits_fit_the_readme_demo(client, issue):
    # Real limiter with defaults: the README walk-through does 4 reveals.
    for i in range(DEFAULT_REVEAL_LIMIT):
        _, t = issue(f"900-55-00{i + 10}")
        assert reveal(client, t.ticket).status_code == 200
    _, t = issue("900-55-0099")
    assert_429(reveal(client, t.ticket))


def test_app_passes_retry_after_back():
    assert "retry-after" in RETURN_HEADERS


# --- metric lines


def _metrics(d):
    [directive] = d["_aws"]["CloudWatchMetrics"]
    assert directive["Namespace"] == "MigDemo/SsnVault"
    assert directive["Dimensions"] == [["NamePrefix"]]
    assert d["NamePrefix"] == "migdemo-testing"
    return {m["Name"] for m in directive["Metrics"]}


def test_audited_actions_emit_metrics(client, svc, store, events, reauth_clock):
    token = client.post("/ssn/tokenize", json={"ssn": FAKE_SSN}, headers=CALLER).json()["ssn_token"]
    store.add_claim(21, token)
    t = tickets(client, token, 21).json()["ticket"]
    h = {"X-Actor": "staff-1", "X-Reauth-Actor": "staff-1", "X-Reauth-At": str(int(reauth_clock["now"]))}
    t2 = client.post("/ssn/tickets/refresh", json={"ticket": t, "reason": "x"}, headers=h).json()["ticket"]
    assert reveal(client, t2).status_code == 200
    docs = events.docs("ssn_audited")
    assert [(d["route"], d["action"]) for d in docs] == [
        ("/ssn/tokenize", "ssn.tokenize"),
        ("/ssn/tickets", "ssn.ticket_issue"),
        ("/ssn/tickets/refresh", "ssn.ticket_refresh"),
        ("/ssn/reveal", "ssn.reveal"),
    ]
    assert [_metrics(d) for d in docs] == [{"ssn_tokenize"}, {"ssn_ticket_issue"}, {"ssn_ticket_refresh"}, {"ssn_reveal"}]
    assert all(d[next(iter(_metrics(d)))] == 1 for d in docs)
    # one metric line per audit row
    assert len(docs) == len(store.audit)


def test_rejections_emit_metrics(client, svc, store, issue, events):
    assert reveal(client, "rtk_" + "B" * 32).status_code == 404
    _, t = issue(FAKE_SSN)
    assert reveal(client, t.ticket).status_code == 200
    assert reveal(client, t.ticket).status_code == 404  # used
    token = svc.tokenize("900-55-0002", caller=CALLER_NAME).ssn_token
    assert tickets(client, token, 999).status_code == 404  # no such claim
    docs = events.docs("ssn_ticket_rejected")
    assert [(d["route"], d["reason"]) for d in docs] == [
        ("/ssn/reveal", "unknown"),
        ("/ssn/reveal", "used"),
        ("/ssn/tickets", "no_open_claim"),
    ]
    assert all(_metrics(d) == {"ssn_ticket_rejected"} for d in docs)


def test_malformed_ticket_is_its_own_category(client, events):
    assert reveal(client, "not-a-ticket").status_code == 404
    [d] = events.docs("ssn_ticket_rejected")
    assert d["reason"] == "malformed"


def test_closed_claim_attempt_emits_its_own_metric(client, store, issue, events):
    _, t = issue(FAKE_SSN)
    store.claims[t.claim_id][1] = "closed"
    r = reveal(client, t.ticket)
    assert r.status_code == 404 and r.json() == {"detail": TICKET_GONE}  # same answer as any other 404
    [d] = events.docs("ssn_ticket_rejected")
    assert d["reason"] == "claim_closed"
    assert _metrics(d) == {"ssn_ticket_rejected", "ssn_closed_claim_attempt"}
    assert d["ssn_closed_claim_attempt"] == 1


def test_429_emits_a_metric(client, limits, events):
    for _ in range(4):
        reveal(client, "rtk_" + "B" * 32)
    [d] = events.docs("ssn_rate_limited")
    assert (d["route"], d["bucket"], d["limit"]) == ("/ssn/reveal", "reveal", 3)
    assert _metrics(d) == {"ssn_rate_limited"}
    # a 429 is not also a rejection
    assert len(events.docs("ssn_ticket_rejected")) == 3


def test_metric_lines_carry_no_actor_ticket_token_or_ssn(client, svc, store, issue, events, limits, caplog):
    caplog.set_level(logging.DEBUG)
    token, t = issue(FAKE_SSN, actor="staff-secret-77")
    reveal(client, t.ticket, actor="staff-secret-77")
    reveal(client, t.ticket, actor="staff-secret-77")
    reveal(client, "rtk_" + "Q" * 32, actor="staff-secret-77")
    reveal(client, "rtk_" + "Q" * 32, actor="staff-secret-77")  # 429
    assert events.docs("ssn_rate_limited")
    text = "\n".join(events.lines + [r.getMessage() for r in caplog.records])
    for secret in ["staff-secret-77", t.ticket, token, "900550001", FAKE_SSN, "Q" * 32]:
        assert secret not in text
    allowed = {"_aws", "NamePrefix", "level", "event", "route", "status", "latency_ms", "reason", "action",
               "bucket", "limit", "ssn_tokenize", "ssn_reveal", "ssn_ticket_issue", "ssn_ticket_refresh",
               "ssn_ticket_rejected", "ssn_closed_claim_attempt", "ssn_rate_limited", "ssn_caller_rejected"}
    for d in events.docs():
        assert set(d) <= allowed


def test_unknown_name_prefix_still_serves(client, issue, monkeypatch, caplog):
    monkeypatch.delenv("SSN_NAME_PREFIX", raising=False)
    monkeypatch.delenv("ECS_CONTAINER_METADATA_URI_V4", raising=False)
    ssn_events._prefix.reset()
    monkeypatch.setattr(ssn_events, "_warned", False)
    caplog.set_level(logging.WARNING)
    _, t = issue(FAKE_SSN)
    assert reveal(client, t.ticket).status_code == 200
    assert reveal(client, t.ticket).status_code == 404
    assert caplog.text.count("ssn metrics name prefix unknown") == 1
    ssn_events._prefix.reset()


# --- the alarms watch these metrics


def _alarms_tf():
    p = ROOT / "terraform/modules/observability/alarms.tf"
    if not p.is_file():
        pytest.skip("terraform tree not present")
    return p.read_text()


@pytest.mark.parametrize(
    "alarm,metric",
    [
        ("ssn-reveals-high", "ssn_reveal"),
        ("ssn-ticket-rejections-high", "ssn_ticket_rejected"),
        ("ssn-closed-claim-attempt", "ssn_closed_claim_attempt"),
        ("ssn-rate-limited", "ssn_rate_limited"),
        ("ssn-tokenize-caller-rejected", "ssn_caller_rejected"),
    ],
)
def test_alarm_watches_a_metric_the_vault_writes(alarm, metric):
    text = _alarms_tf()
    m = re.search(r'\n    "?' + re.escape(alarm) + r'"? = \{(.*?)\n    \}', text, re.S)
    assert m, alarm
    body = m.group(1)
    assert 'namespace   = "MigDemo/SsnVault"' in body
    assert f'metric      = "{metric}"' in body
    assert "local.vault_emf_dims" in body
    assert f'"{metric}"' in Path(ssn_events.__file__).read_text()


def test_limiter_module_never_logs_the_actor():
    src = Path(ratelimit.__file__).read_text()
    assert "actor" not in "".join(line for line in src.splitlines() if "log." in line)
