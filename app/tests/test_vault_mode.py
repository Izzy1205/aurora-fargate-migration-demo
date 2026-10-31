"""The vault-only app (demo_app.vault): serves /health and /ssn/* only, with
the same behavior as the app. Fake 9xx SSNs only."""

import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from demo_app import main, vault
from demo_app.main import get_reauth_verifier, get_repository, get_ssn_service
from demo_app.ssn import HeaderReauthVerifier

FAKE_SSN = "900-00-0001"
SSN_PATHS = {"/ssn/tokenize", "/ssn/tickets", "/ssn/reveal", "/ssn/tickets/refresh"}


def paths(app):
    return {r.path for r in app.routes if isinstance(r, APIRoute)}


@pytest.fixture
def vclient(svc, reauth_clock):
    vault.app.dependency_overrides[get_ssn_service] = lambda: svc
    vault.app.dependency_overrides[get_reauth_verifier] = lambda: HeaderReauthVerifier(
        clock=lambda: reauth_clock["now"]
    )
    yield TestClient(vault.app)
    vault.app.dependency_overrides.clear()


def test_vault_serves_only_health_and_ssn():
    assert paths(vault.app) == {"/health"} | SSN_PATHS


def test_app_routes_unchanged():
    # The app still serves everything it did, /ssn included.
    assert paths(main.app) >= {"/health", "/ready", "/orders", "/customers", "/", "/demo/seed-claim"} | SSN_PATHS


def test_ssn_handlers_are_the_in_process_ones():
    # The vault runs the in-process handlers, never the app's forwarding
    # route, so it can't call itself.
    local = {r.path: r.endpoint for r in main.ssn_local.routes if isinstance(r, APIRoute)}
    assert set(local) == SSN_PATHS
    for r in vault.app.routes:
        if isinstance(r, APIRoute) and r.path in SSN_PATHS:
            assert r.endpoint is local[r.path]
            assert r.endpoint is not main.ssn_via_vault


@pytest.mark.parametrize("method,path", [
    ("GET", "/"), ("GET", "/orders"), ("GET", "/customers"), ("GET", "/ready"),
    ("POST", "/demo/seed-claim"), ("GET", "/docs"), ("GET", "/openapi.json"),
])
def test_other_routes_are_404(method, path):
    # A database override proves a 404 is "no route", not a DB failure.
    vault.app.dependency_overrides[get_repository] = lambda: object()
    try:
        assert TestClient(vault.app).request(method, path).status_code == 404
    finally:
        vault.app.dependency_overrides.clear()


def test_health_needs_nothing():
    r = TestClient(vault.app).get("/health")
    assert r.status_code == 200 and r.json()["mode"] == "ssn-vault"


def test_tokenize_then_reveal(vclient, store):
    r = vclient.post("/ssn/tokenize", json={"ssn": FAKE_SSN})
    assert r.status_code == 201 and r.headers["cache-control"] == "no-store"
    token = r.json()["ssn_token"]
    store.add_claim(501, token)
    staff = {"X-Actor": "staff-1"}
    t = vclient.post("/ssn/tickets", json={"ssn_token": token, "claim_id": 501, "reason": "identity check"},
                     headers=staff)
    assert t.status_code == 201
    r = vclient.post("/ssn/reveal", json={"ticket": t.json()["ticket"], "reason": "identity check"}, headers=staff)
    assert r.status_code == 200 and r.json()["ssn"] == "900000001"


def test_bad_request_does_not_echo_ssn(vclient):
    r = vclient.post("/ssn/tokenize", json={"ssn": ["900-00-0001"]})
    assert r.status_code == 422 and r.json() == {"detail": "invalid request"}
    assert "900" not in r.text


def test_unconfigured_service_is_503(monkeypatch):
    # No override and no name prefix: the real service can't find its config.
    monkeypatch.delenv("SSN_NAME_PREFIX", raising=False)
    monkeypatch.delenv("ECS_CONTAINER_METADATA_URI_V4", raising=False)
    vault.app.dependency_overrides.clear()
    main._ssn_service.reset()
    try:
        r = TestClient(vault.app).post("/ssn/tokenize", json={"ssn": FAKE_SSN})
        assert r.status_code == 503 and r.json() == {"detail": "ssn service unavailable"}
    finally:
        main._ssn_service.reset()
