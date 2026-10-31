"""The app's /ssn routes only forward to the SSN vault service. When the
vault can't answer, or answers 5xx, the app returns 503 and runs no SSN
code of its own. Fake 9xx SSNs only.

The fake vault below runs the real vault app (demo_app.vault) on an
in-memory store."""

import http.server
import json
import logging
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from demo_app import main, ssn_api, ssn_vault_client, vault
from demo_app.ssn import HeaderReauthVerifier
from demo_app.ssn_api import TICKET_GONE, get_reauth_verifier, get_ssn_service
from demo_app.ssn_vault_client import (
    EVENT_LOGGER,
    VaultClient,
    VaultResponse,
    VaultUnavailable,
    get_vault_client,
    vault_host,
)

from conftest import PEPPER, T0  # noqa: E402 - shared test-only key

SSN = "900-12-3456"
ACTOR = {"X-Actor": "staff-7"}
SSN_PATHS = {"/ssn/tokenize", "/ssn/tickets", "/ssn/reveal", "/ssn/tickets/refresh"}


class FakeVault:
    """Stands in for VaultClient. mode:
    ok            the real vault app answers
    status:<n>    answers <n> without touching the vault app
    down          connection refused, nothing sent
    then_500      the vault app does the work, then the caller sees a 500
    then_drop     the vault app does the work, then the connection drops"""

    name_prefix = "migdemo-testing"

    def __init__(self):
        self.mode = "ok"
        self.calls = []
        self.client = TestClient(vault.app)

    def send(self, path, body, headers):
        sent = {h: headers[h] for h in ssn_vault_client.FORWARD_HEADERS if headers.get(h) is not None}
        self.calls.append((path, sent))
        if self.mode == "down":
            raise VaultUnavailable("connect_error", "ConnectionRefusedError")
        if self.mode.startswith("status:"):
            code = int(self.mode.split(":")[1])
            return VaultResponse(code, {"content-type": "application/json"}, json.dumps({"detail": f"vault {code}"}).encode())
        r = self.client.post(path, content=body, headers=sent)
        if self.mode == "then_500":
            return VaultResponse(500, {"content-type": "text/plain"}, b"Internal Server Error")
        if self.mode == "then_drop":
            raise VaultUnavailable("bad_response", "RemoteDisconnected")
        keep = {k: v for k, v in r.headers.items() if k in ssn_vault_client.RETURN_HEADERS}
        return VaultResponse(r.status_code, keep, r.content)


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
def events():
    h = Events()
    lg = logging.getLogger(EVENT_LOGGER)
    lg.addHandler(h)
    yield h
    lg.removeHandler(h)


@pytest.fixture
def fake_vault(svc, reauth_clock):
    fv = FakeVault()
    reauth = lambda: HeaderReauthVerifier(clock=lambda: reauth_clock["now"])  # noqa: E731
    vault.app.dependency_overrides[get_ssn_service] = lambda: svc
    vault.app.dependency_overrides[get_reauth_verifier] = reauth
    main.app.dependency_overrides[get_vault_client] = lambda: fv
    yield fv
    vault.app.dependency_overrides.clear()


@pytest.fixture
def app_client(fake_vault):
    # The app, not the vault: its /ssn routes forward to fake_vault.
    return TestClient(main.app)


UNAVAILABLE = {"detail": "ssn service unavailable"}


def assert_unavailable(r):
    assert r.status_code == 503 and r.json() == UNAVAILABLE
    assert r.headers["cache-control"] == "no-store" and r.headers["pragma"] == "no-cache"


def tokenize(c):
    r = c.post("/ssn/tokenize", json={"ssn": SSN})
    assert r.status_code in (200, 201), r.text
    return r.json()["ssn_token"]


def ticket_for(c, store, token, claim_id=501):
    store.add_claim(claim_id, token)
    r = c.post("/ssn/tickets", json={"ssn_token": token, "claim_id": claim_id, "reason": "identity check"}, headers=ACTOR)
    assert r.status_code == 201, r.text
    return r.json()["ticket"]


def reveal(c, ticket):
    return c.post("/ssn/reveal", json={"ticket": ticket, "reason": "identity check"}, headers=ACTOR)


def reveals(store):
    return [a for a in store.audit if a.action == "ssn.reveal"]


# --- wiring


def test_app_ssn_routes_forward_and_vault_routes_do_not():
    app_eps = {r.path: r.endpoint for r in main.app.routes if isinstance(r, APIRoute) and r.path in SSN_PATHS}
    assert set(app_eps) == SSN_PATHS
    assert all(ep is main.ssn_via_vault for ep in app_eps.values())
    for r in vault.app.routes:
        if isinstance(r, APIRoute):
            assert r.endpoint is not main.ssn_via_vault


def test_vault_url_is_derived_from_the_name_prefix(monkeypatch):
    assert vault_host("migdemo-testing") == "ssn-vault.migdemo-testing.internal"
    monkeypatch.setenv("SSN_NAME_PREFIX", "migdemo-testing")
    monkeypatch.setattr(ssn_vault_client, "_client", ssn_vault_client.CachedOnSuccess(ssn_vault_client._build_client))
    c = get_vault_client()
    assert c is not None and c.base_url == "http://ssn-vault.migdemo-testing.internal:8080"
    assert (c.connect_timeout, c.read_timeout) == (2.0, 25.0)


def test_no_name_prefix_means_no_vault_client(monkeypatch):
    monkeypatch.delenv("SSN_NAME_PREFIX", raising=False)
    monkeypatch.delenv("ECS_CONTAINER_METADATA_URI_V4", raising=False)
    monkeypatch.setattr(ssn_vault_client, "_client", ssn_vault_client.CachedOnSuccess(ssn_vault_client._build_client))
    assert get_vault_client() is None


def test_vault_url_matches_the_terraform_module():
    tf = Path(__file__).resolve().parents[2] / "terraform/modules/ssn_vault_service"
    if not tf.is_dir():
        pytest.skip("terraform tree not present")
    text = (tf / "network.tf").read_text() + (tf / "variables.tf").read_text() + (tf / "outputs.tf").read_text()
    assert f'"{ssn_vault_client.VAULT_SERVICE_NAME}"' in text
    assert '"${var.name_prefix}.internal"' in text
    assert f"default     = {ssn_vault_client.VAULT_PORT}" in text or f"default = {ssn_vault_client.VAULT_PORT}" in text


# --- vault answers


def test_full_flow_is_served_by_the_vault(app_client, fake_vault, store, events):
    token = tokenize(app_client)
    t = ticket_for(app_client, store, token)
    r = reveal(app_client, t)
    assert r.status_code == 200 and r.json()["ssn"] == "900123456"
    assert r.headers["cache-control"] == "no-store"
    again = reveal(app_client, t)
    assert again.status_code == 404  # used ticket stays a 404
    assert again.json() == {"detail": TICKET_GONE}
    assert [p for p, _ in fake_vault.calls] == ["/ssn/tokenize", "/ssn/tickets", "/ssn/reveal", "/ssn/reveal"]
    assert events.docs("ssn_vault_unavailable") == []
    assert [(d["route"], d["status"]) for d in events.docs("ssn_vault_call")] == [
        ("/ssn/tokenize", 201), ("/ssn/tickets", 201), ("/ssn/reveal", 200), ("/ssn/reveal", 404),
    ]
    assert len(reveals(store)) == 1


@pytest.mark.parametrize("code", [400, 401, 403, 404, 409, 422, 429])
def test_vault_4xx_is_passed_through(app_client, fake_vault, store, events, code):
    token = tokenize(app_client)
    t = ticket_for(app_client, store, token)
    fake_vault.mode = f"status:{code}"
    r = reveal(app_client, t)
    assert r.status_code == code
    assert r.json() == {"detail": f"vault {code}"}
    assert reveals(store) == []
    assert store.ticket(t)["used_at"] is None
    assert events.docs("ssn_vault_unavailable") == []


def test_vault_validation_and_auth_errors_pass_through(app_client, fake_vault, events):
    assert app_client.post("/ssn/tokenize", json={"ssn": "12"}).status_code == 400
    r = app_client.post("/ssn/tokenize", json={"nope": SSN})
    assert r.status_code == 422 and SSN not in r.text
    r = app_client.post("/ssn/reveal", json={"ticket": "rtk_x", "reason": "r"})
    assert r.status_code == 401
    assert len(fake_vault.calls) == 3
    assert events.docs("ssn_vault_unavailable") == []


def test_refresh_through_the_vault_forwards_reauth_headers(app_client, fake_vault, store, reauth_clock):
    token = tokenize(app_client)
    t = ticket_for(app_client, store, token)
    headers = {**ACTOR, "X-Reauth-Actor": "staff-7", "X-Reauth-At": str(int(reauth_clock["now"])),
               "Cookie": "session=abc", "Authorization": "Bearer xyz"}
    r = app_client.post("/ssn/tickets/refresh", json={"ticket": t, "reason": "still checking"}, headers=headers)
    assert r.status_code == 201, r.text
    path, sent = fake_vault.calls[-1]
    assert path == "/ssn/tickets/refresh"
    assert sent["x-actor"] == "staff-7"
    assert sent["x-reauth-actor"] == "staff-7"
    assert sent["x-reauth-at"] == str(int(reauth_clock["now"]))
    assert "cookie" not in sent and "authorization" not in sent


# --- vault unavailable: 503, no SSN code in the app


def test_vault_5xx_is_a_503(app_client, fake_vault, store, events):
    fake_vault.mode = "status:503"
    r = app_client.post("/ssn/tokenize", json={"ssn": SSN})
    assert_unavailable(r)
    assert store.rows == []  # nothing ran in the app
    [ev] = events.docs("ssn_vault_unavailable")
    assert (ev["route"], ev["reason"], ev["vault_status"], ev["level"]) == ("/ssn/tokenize", "vault_5xx", 503, "WARN")
    assert ev["ssn_vault_unavailable"] == 1


@pytest.mark.parametrize("code", [500, 502, 503, 504])
def test_vault_5xx_body_is_not_passed_on(app_client, fake_vault, code):
    fake_vault.mode = f"status:{code}"
    r = app_client.post("/ssn/tokenize", json={"ssn": SSN})
    assert_unavailable(r)
    assert "vault" not in r.text


@pytest.mark.parametrize("path", sorted(SSN_PATHS))
def test_connection_error_is_a_503_on_every_route(app_client, fake_vault, store, events, path):
    fake_vault.mode = "down"
    r = app_client.post(path, json={"ticket": "rtk_x", "ssn_token": "tok_x", "claim_id": 1, "ssn": SSN,
                                    "reason": "r"}, headers=ACTOR)
    assert_unavailable(r)
    assert store.rows == [] and store.audit == []
    [ev] = events.docs("ssn_vault_unavailable")
    assert (ev["route"], ev["reason"], ev["error"]) == (path, "connect_error", "ConnectionRefusedError")


def test_no_vault_url_is_a_503(store, events):
    # conftest's autouse fixture gives the app no vault client.
    r = TestClient(main.app).post("/ssn/tokenize", json={"ssn": SSN})
    assert_unavailable(r)
    assert store.rows == []
    [ev] = events.docs("ssn_vault_unavailable")
    assert ev["reason"] == "no_vault_url" and ev["NamePrefix"] == "unknown"


@pytest.mark.parametrize("mode", ["then_500", "then_drop"])
def test_vault_burns_the_ticket_then_fails_is_a_503_and_no_retry(app_client, fake_vault, store, events, mode):
    token = tokenize(app_client)
    t = ticket_for(app_client, store, token)
    fake_vault.mode = mode
    r = reveal(app_client, t)
    # The vault revealed and burned the ticket; the caller never saw it.
    assert_unavailable(r)
    assert "900123456" not in r.text
    assert len(reveals(store)) == 1
    assert [p for p, _ in fake_vault.calls].count("/ssn/reveal") == 1  # not retried
    fake_vault.mode = "ok"
    assert reveal(app_client, t).status_code == 404
    assert len(reveals(store)) == 1


def test_bad_json_on_the_app_is_forwarded_not_echoed(app_client, fake_vault):
    # The app doesn't validate /ssn bodies any more; the vault does, with
    # the same bare 422.
    r = app_client.post("/ssn/tokenize", json={"ssn": [SSN]})
    assert r.status_code == 422 and r.json() == {"detail": "invalid request"} and "900" not in r.text
    assert len(fake_vault.calls) == 1


# --- the app has no SSN code

SSN_ONLY_MODULES = [
    "demo_app.ssn_api",
    "demo_app.ssn.config",
    "demo_app.ssn.crypto",
    "demo_app.ssn.service",
    "demo_app.ssn.store",
    "demo_app.ssn.reauth",
    "boto3",
    "botocore",
]


def _modules_after_import(module):
    code = (
        "import json, sys\n"
        f"import {module}\n"
        "print(json.dumps(sorted(sys.modules)))\n"
    )
    # pytest adds src/ to sys.path (pyproject pythonpath), but a child
    # process doesn't get that, and CI doesn't install the package.
    app_dir = Path(__file__).resolve().parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(p for p in (str(app_dir / "src"), env.get("PYTHONPATH")) if p)
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, cwd=app_dir, env=env)
    assert out.returncode == 0, out.stderr
    return set(json.loads(out.stdout))


def test_importing_the_app_loads_no_ssn_service_kms_or_pepper_code():
    loaded = _modules_after_import("demo_app.main")
    assert "demo_app.main" in loaded
    assert not set(SSN_ONLY_MODULES) & loaded


def test_the_vault_does_load_them():
    # The check above means something: the vault entry point loads them.
    loaded = _modules_after_import("demo_app.vault")
    assert {"demo_app.ssn_api", "demo_app.ssn.config", "demo_app.ssn.service", "demo_app.ssn.store"} <= loaded
    assert "demo_app.main" not in loaded


def test_app_has_no_route_to_the_ssn_handlers():
    handlers = {r.endpoint for r in ssn_api.ssn_router.routes if isinstance(r, APIRoute)}
    assert len(handlers) == 4
    for r in main.app.routes:
        if isinstance(r, APIRoute):
            assert r.endpoint not in handlers
            assert r.endpoint.__module__ != "demo_app.ssn_api"
            for dep in r.dependant.dependencies:
                assert dep.call not in (ssn_api.get_ssn_service, ssn_api.get_reauth_verifier)
    for name in ("get_ssn_service", "get_reauth_verifier", "local_ssn_app", "ssn_local", "add_ssn_routes"):
        assert not hasattr(main, name)


def test_overriding_the_ssn_service_on_the_app_changes_nothing(svc, store, events):
    # Even if something wired the token service onto the app, its /ssn
    # routes still only forward (here: no vault, so 503).
    main.app.dependency_overrides[get_ssn_service] = lambda: svc
    try:
        assert_unavailable(TestClient(main.app).post("/ssn/tokenize", json={"ssn": SSN}))
    finally:
        main.app.dependency_overrides.pop(get_ssn_service, None)
    assert store.rows == []


# --- logs


def test_no_secrets_in_any_log_line(app_client, fake_vault, store, events, caplog, reauth_clock):
    caplog.set_level(logging.DEBUG)
    token = tokenize(app_client)
    t = ticket_for(app_client, store, token)
    headers = {**ACTOR, "X-Reauth-Actor": "staff-7", "X-Reauth-At": str(int(reauth_clock["now"]))}
    t2 = app_client.post("/ssn/tickets/refresh", json={"ticket": t, "reason": "x"}, headers=headers).json()["ticket"]
    fake_vault.mode = "down"
    assert reveal(app_client, t2).status_code == 503
    fake_vault.mode = "then_500"
    assert reveal(app_client, t2).status_code == 503
    text = "\n".join(events.lines + [r.getMessage() for r in caplog.records])
    assert events.lines and events.docs("ssn_vault_unavailable") and events.docs("ssn_vault_call")
    for secret in ["900123456", "900-12-3456", token, t, t2, "staff-7", PEPPER.hex(), str(int(reauth_clock["now"]))]:
        assert secret not in text
    for d in events.docs():
        assert set(d) <= {"_aws", "NamePrefix", "level", "event", "route", "status", "latency_ms", "reason",
                          "vault_status", "error", "ssn_vault_call", "ssn_vault_latency_ms", "ssn_vault_unavailable"}


def test_log_lines_are_cloudwatch_embedded_metrics(app_client, fake_vault, events):
    tokenize(app_client)
    fake_vault.mode = "down"
    assert app_client.post("/ssn/tokenize", json={"ssn": SSN}).status_code == 503
    docs = [d for d in events.docs() if d["event"] != "ssn_vault_served"]
    for d in docs:
        [directive] = d["_aws"]["CloudWatchMetrics"]
        assert directive["Namespace"] == "MigDemo/SsnVault"
        assert directive["Dimensions"] == [["NamePrefix"]]
        for m in directive["Metrics"]:
            assert isinstance(d[m["Name"]], (int, float))
        assert d["NamePrefix"] == "migdemo-testing"
    assert {d["event"] for d in docs} == {"ssn_vault_call", "ssn_vault_unavailable"}


def test_vault_logs_route_status_and_latency_only(svc, events):
    vault.app.dependency_overrides[get_ssn_service] = lambda: svc
    try:
        r = TestClient(vault.app).post("/ssn/tokenize", json={"ssn": SSN})
    finally:
        vault.app.dependency_overrides.clear()
    assert r.status_code == 201
    [d] = events.docs("ssn_vault_served")
    assert set(d) == {"level", "event", "route", "status", "latency_ms"}
    assert (d["route"], d["status"]) == ("/ssn/tokenize", 201)


# --- the real HTTP client


class _Handler(http.server.BaseHTTPRequestHandler):
    seen = []
    status = 200
    delay = 0.0

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        type(self).seen.append((self.path, {k.lower(): v for k, v in self.headers.items()}, body))
        time.sleep(type(self).delay)
        out = b'{"ok":true}'
        self.send_response(type(self).status)
        self.send_header("content-type", "application/json")
        self.send_header("cache-control", "no-store")
        self.send_header("x-internal", "secret")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        try:
            self.wfile.write(out)
        except OSError:
            pass  # the client gave up (read timeout test)

    def log_message(self, *args):
        pass


@pytest.fixture
def server():
    _Handler.seen, _Handler.status, _Handler.delay = [], 200, 0.0
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    yield srv
    srv.shutdown()
    srv.server_close()


def test_client_forwards_only_the_needed_headers(server):
    c = VaultClient("127.0.0.1", server.server_address[1])
    r = c.send("/ssn/reveal", b'{"ticket":"rtk_x"}', {
        "content-type": "application/json", "x-actor": "a1", "x-reauth-actor": "a1", "x-reauth-at": "1",
        "cookie": "c", "authorization": "b", "x-forwarded-for": "1.2.3.4",
    })
    assert (r.status, r.body) == (200, b'{"ok":true}')
    assert r.headers == {"content-type": "application/json", "cache-control": "no-store"}
    [(path, headers, body)] = _Handler.seen
    assert path == "/ssn/reveal" and body == b'{"ticket":"rtk_x"}'
    assert headers["x-actor"] == "a1" and headers["x-reauth-actor"] == "a1" and headers["x-reauth-at"] == "1"
    assert not {"cookie", "authorization", "x-forwarded-for"} & set(headers)


def test_client_returns_5xx_as_an_answer(server):
    _Handler.status = 503
    assert VaultClient("127.0.0.1", server.server_address[1]).send("/ssn/tokenize", b"{}", {}).status == 503


def test_client_read_timeout(server):
    _Handler.delay = 0.5
    c = VaultClient("127.0.0.1", server.server_address[1], read_timeout=0.1)
    with pytest.raises(VaultUnavailable) as e:
        c.send("/ssn/tokenize", b"{}", {})
    assert e.value.reason == "read_timeout"


def test_client_connection_refused():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    with pytest.raises(VaultUnavailable) as e:
        VaultClient("127.0.0.1", port).send("/ssn/tokenize", b"{}", {})
    assert e.value.reason == "connect_error"


@pytest.mark.parametrize("exc,reason", [(socket.gaierror(-2, "Name or service not known"), "dns"),
                                        (TimeoutError("timed out"), "connect_timeout")])
def test_client_dns_and_connect_timeout(monkeypatch, exc, reason):
    def boom(*a, **k):
        raise exc

    monkeypatch.setattr(socket, "create_connection", boom)
    with pytest.raises(VaultUnavailable) as e:
        VaultClient("ssn-vault.migdemo-testing.internal").send("/ssn/reveal", b"{}", {})
    assert e.value.reason == reason


def test_client_refuses_other_paths():
    with pytest.raises(ValueError):
        VaultClient("127.0.0.1").send("/orders", b"", {})


def test_fixture_clock_is_fixed():
    assert T0.year == 2026
