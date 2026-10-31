"""HTTP API for the demo.

/health  liveness, never touches the database (used by the ALB)
/ready   readiness, checks the database
/orders  JSON, includes priority whether or not the V3 column exists
/customers JSON
/        small HTML page for the live demo
/ssn/tokenize        POST
/ssn/tickets         POST
/ssn/reveal          POST
/ssn/tickets/refresh POST
                     The four /ssn routes only forward to the private SSN
                     vault service (see ssn_vault_client.py and ssn_api.py).
                     If the vault can't answer, they return 503. The app
                     has no SSN code of its own: it never imports the token
                     service, KMS, the pepper or the vault database login.
/demo/seed-claim     POST, testing only: fake claimant and open claim for a
                     token (see demo_seed.py). 404 in every other environment.
"""

from __future__ import annotations

import html
import logging
import time
from functools import lru_cache
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse, Response

from .db import DbSettings, Repository
from .demo_seed import (
    PostgresSeedStore,
    SeedConflict,
    SeedInputError,
    SeedStore,
    TestingOnlyGuard,
    check_seed_input,
)
from .presenters import present_customer, present_order
from .ssn_vault_client import (
    SSN_PATHS,
    VaultClient,
    VaultUnavailable,
    get_vault_client,
    log_unavailable,
    log_vault_call,
)
from .web import APP_VERSION, NO_STORE, SSN_UNAVAILABLE, db_unavailable, setup_logging, validation_error

setup_logging()
log = logging.getLogger("demo_app")

app = FastAPI(title="Migration demo", version=APP_VERSION, docs_url=None, redoc_url=None)
app.add_exception_handler(RequestValidationError, validation_error)


@lru_cache(maxsize=1)
def get_repository() -> Repository:
    return Repository(DbSettings.from_env())


Repo = Annotated[Repository, Depends(get_repository)]
Limit = Annotated[int, Query(ge=1, le=100)]


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "version": APP_VERSION}


@app.get("/ready")
def ready(repo: Repo) -> dict[str, str]:
    try:
        repo.ping()
    except Exception as exc:  # noqa: BLE001 - any failure means not ready
        raise db_unavailable(exc) from exc
    return {"status": "ready"}


@app.get("/orders")
def orders(repo: Repo, limit: Limit = 20) -> dict[str, Any]:
    try:
        has_priority = repo.has_priority_column()
        rows = repo.list_orders(limit)
    except Exception as exc:  # noqa: BLE001
        raise db_unavailable(exc) from exc
    return {
        "version": APP_VERSION,
        "schema_has_priority": has_priority,
        "orders": [present_order(r) for r in rows],
    }


@app.get("/customers")
def customers(repo: Repo, limit: Limit = 20) -> dict[str, Any]:
    try:
        rows = repo.list_customers(limit)
    except Exception as exc:  # noqa: BLE001
        raise db_unavailable(exc) from exc
    return {"customers": [present_customer(r) for r in rows]}


VaultDep = Annotated[VaultClient | None, Depends(get_vault_client)]


def _unavailable() -> JSONResponse:
    return JSONResponse({"detail": SSN_UNAVAILABLE}, status_code=503, headers=NO_STORE)


async def ssn_via_vault(request: Request, vault: VaultDep) -> Response:
    """Forward to the SSN vault service. Any answer below 500 goes back
    unchanged. No answer, or a 5xx, is a 503 here. Nothing is retried."""
    route = request.url.path
    body = await request.body()
    started = time.monotonic()

    def elapsed_ms() -> int:
        return int((time.monotonic() - started) * 1000)

    if vault is None:
        log_unavailable(route, "no_vault_url", "")
        return _unavailable()
    try:
        answer = await run_in_threadpool(vault.send, route, body, request.headers)
    except VaultUnavailable as exc:
        log_unavailable(route, exc.reason, vault.name_prefix, error=exc.error, latency_ms=elapsed_ms())
        return _unavailable()
    if answer.status >= 500:
        log_unavailable(route, "vault_5xx", vault.name_prefix, vault_status=answer.status, latency_ms=elapsed_ms())
        return _unavailable()
    log_vault_call(route, answer.status, elapsed_ms(), vault.name_prefix)
    return Response(content=answer.body, status_code=answer.status, headers=answer.headers)


for _path in SSN_PATHS:
    app.add_api_route(_path, ssn_via_vault, methods=["POST"], name=f"ssn_via_vault:{_path}")


@lru_cache(maxsize=1)
def get_testing_guard() -> TestingOnlyGuard:
    return TestingOnlyGuard()


@lru_cache(maxsize=1)
def get_seed_store() -> SeedStore:
    # The app's own login (DB_USER), not the vault login.
    return PostgresSeedStore(DbSettings.from_env())


# Exactly what FastAPI answers for a route that doesn't exist, so outside
# testing this endpoint can't be told apart from no endpoint at all.
_NOT_FOUND = {"detail": "Not Found"}
SEED_INPUT_HELP = "send the ssn_token and ssn_hmac exactly as /ssn/tokenize returned them"


# Every method is routed here so that outside testing even a GET gets the
# same 404 as an unknown path, not a 405 that would show the route exists.
@app.api_route("/demo/seed-claim", methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def demo_seed_claim(request: Request) -> JSONResponse:
    # The guard runs before the body is read or validated, so a stage or
    # production caller gets the plain 404 whatever they send. No
    # dependencies on purpose: those resolve with the body.
    guard = get_testing_guard()
    if not await run_in_threadpool(guard.allowed):
        return JSONResponse(_NOT_FOUND, status_code=404)
    if request.method != "POST":
        return JSONResponse({"detail": "Method Not Allowed"}, status_code=405, headers={"Allow": "POST"})
    actor = (request.headers.get("x-actor") or "").strip()
    if not actor:
        return JSONResponse({"detail": "actor required"}, status_code=401, headers=NO_STORE)
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001 - not JSON
        return JSONResponse({"detail": "invalid request"}, status_code=422, headers=NO_STORE)
    if not isinstance(body, dict):
        return JSONResponse({"detail": "invalid request"}, status_code=422, headers=NO_STORE)
    try:
        ssn_token, ssn_hmac = check_seed_input(body.get("ssn_token"), body.get("ssn_hmac"))
    except SeedInputError:
        # A fixed message, never the exception text (CodeQL
        # py/stack-trace-exposure).
        return JSONResponse({"detail": SEED_INPUT_HELP}, status_code=400, headers=NO_STORE)
    store = get_seed_store()
    try:
        result = await run_in_threadpool(store.seed_claim, ssn_token, ssn_hmac, actor)
    except SeedConflict:
        return JSONResponse(
            {"detail": "that token or HMAC belongs to a different claimant"}, status_code=409, headers=NO_STORE
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("demo seed failed: %s", type(exc).__name__)
        return JSONResponse({"detail": "database unavailable"}, status_code=503, headers=NO_STORE)
    return JSONResponse(
        {
            "claimant_id": result.claimant_id,
            "claim_id": result.claim_id,
            "claim_status": result.claim_status,
            "employer_id": result.employer_id,
            "created": result.created,
        },
        status_code=201 if result.created else 200,
        headers=NO_STORE,
    )


@app.get("/", response_class=HTMLResponse)
def index(repo: Repo) -> str:
    data = orders(repo, limit=25)
    e = html.escape
    rows = "".join(
        "<tr>"
        f"<td>{e(str(o['id']))}</td><td>{e(str(o['customer_id']))}</td>"
        f"<td>{e(o['status'])}</td><td>${e(o['total'])}</td>"
        f"<td>{e(o['priority'])}{'' if o['priority_set'] else ' <small>(default, NULL in DB)</small>'}</td>"
        "</tr>"
        for o in data["orders"]
    )
    column_state = "present" if data["schema_has_priority"] else "not there yet"
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Migration demo</title>
<style>body{{font-family:sans-serif;margin:2rem}}td,th{{padding:.25rem .75rem;text-align:left}}</style>
</head><body>
<h1>Orders</h1>
<p>App version <b>{e(APP_VERSION)}</b>. Column <code>orders.priority</code>: <b>{column_state}</b>.</p>
<table><tr><th>ID</th><th>Customer</th><th>Status</th><th>Total</th><th>Priority</th></tr>{rows}</table>
</body></html>"""
