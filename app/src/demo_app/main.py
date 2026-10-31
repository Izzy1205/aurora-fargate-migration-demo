"""HTTP API for the demo.

/health  liveness, never touches the database (used by the ALB)
/ready   readiness, checks the database
/orders  JSON, includes priority whether or not the V3 column exists
/customers JSON
/        small HTML page for the live demo
/ssn/tokenize        POST, SSN in, token and HMAC out (see ssn/)
/ssn/tickets         POST, token and open claim in, one-use reveal ticket out
/ssn/reveal          POST, ticket in, SSN out, burns the ticket, audited
/ssn/tickets/refresh POST, ticket in, new ticket out, needs re-auth, audited
                     The four /ssn routes go to the private SSN vault service
                     and fall back to the in-process handlers below if it
                     can't answer (see ssn_vault_client.py).
/demo/seed-claim     POST, testing only: fake claimant and open claim for a
                     token (see demo_seed.py). 404 in every other environment.
"""

from __future__ import annotations

import html
import logging
import os
import time
from functools import lru_cache
from typing import Annotated, Any

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.responses import HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, Field

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
from .ssn import (
    HeaderReauthVerifier,
    InvalidSsn,
    KmsEncryptor,
    NoOpenClaim,
    PostgresVaultStore,
    ReauthVerifier,
    RevealNotAllowed,
    SsnTokenService,
    TicketNotValid,
    install_log_redaction,
)
from .ssn.config import (
    CachedOnSuccess,
    SsnConfigError,
    boto3_client,
    iam_auth_password,
    load_runtime_config,
)
from .ssn_vault_client import (
    SSN_PATHS,
    VaultClient,
    VaultUnavailable,
    get_vault_client,
    log_fallback,
    log_vault_call,
)

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
install_log_redaction()
log = logging.getLogger("demo_app")

APP_VERSION = os.environ.get("APP_VERSION", "dev")

app = FastAPI(title="Migration demo", version=APP_VERSION, docs_url=None, redoc_url=None)

# The in-process SSN handlers. The app serves them only as the fallback
# (see local_ssn_app below); the vault service serves them directly.
ssn_local = APIRouter()


@lru_cache(maxsize=1)
def get_repository() -> Repository:
    return Repository(DbSettings.from_env())


Repo = Annotated[Repository, Depends(get_repository)]
Limit = Annotated[int, Query(ge=1, le=100)]


def _db_unavailable(exc: Exception) -> HTTPException:
    # Log the detail, return a generic message. No hostnames or errors leak.
    log.warning("database call failed: %s", type(exc).__name__)
    return HTTPException(status_code=503, detail="database unavailable")


def _build_ssn_service() -> SsnTokenService:
    # Everything comes from AWS at runtime with the task role, nothing from
    # the task definition (see ssn/config.py for why). The DB host, port and
    # name are the app's own; only the login differs.
    cfg = load_runtime_config()
    host = os.environ["DB_HOST"]
    port = int(os.environ.get("DB_PORT", "5432"))
    local_password = os.environ.get("SSN_DB_PASSWORD", "")
    settings = DbSettings(
        host=host,
        port=port,
        dbname=os.environ["DB_NAME"],
        user=cfg.db_user,
        password=local_password,
        sslmode=os.environ.get("DB_SSLMODE", "require"),
        connect_timeout=int(os.environ.get("DB_CONNECT_TIMEOUT", "20")),
    )
    provider = None if local_password else iam_auth_password(
        boto3_client("rds", cfg.region), host, port, cfg.db_user, cfg.region
    )
    log.info("ssn token service configured for %s", cfg.key_alias)
    return SsnTokenService(
        PostgresVaultStore(settings, password_provider=provider),
        KmsEncryptor(cfg.key_arn, client=boto3_client("kms", cfg.region)),
        cfg.pepper,
    )


_ssn_service = CachedOnSuccess(_build_ssn_service)


def get_ssn_service() -> SsnTokenService:
    try:
        return _ssn_service.get()
    except SsnConfigError as exc:
        # The message names the failed step only. No values, no ARNs.
        log.warning("ssn token service not configured: %s", exc)
        raise HTTPException(status_code=503, detail="ssn service unavailable") from exc
    except Exception as exc:  # noqa: BLE001 - fail closed on anything
        log.warning("ssn token service not configured: %s", type(exc).__name__)
        raise HTTPException(status_code=503, detail="ssn service unavailable") from exc


SsnService = Annotated[SsnTokenService, Depends(get_ssn_service)]


@lru_cache(maxsize=1)
def get_reauth_verifier() -> ReauthVerifier:
    # PLACEHOLDER until a real IdP step-up (OIDC max_age / auth_time). See
    # ssn/reauth.py.
    return HeaderReauthVerifier()


Reauth = Annotated[ReauthVerifier, Depends(get_reauth_verifier)]


@app.exception_handler(RequestValidationError)
async def _validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    # FastAPI's default 422 echoes the bad input back. On /ssn that input
    # can be an SSN, so return a bare message instead.
    if request.url.path.startswith(("/ssn/", "/demo/")):
        return JSONResponse(status_code=422, content={"detail": "invalid request"})
    return await request_validation_exception_handler(request, exc)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "version": APP_VERSION}


@app.get("/ready")
def ready(repo: Repo) -> dict[str, str]:
    try:
        repo.ping()
    except Exception as exc:  # noqa: BLE001 - any failure means not ready
        raise _db_unavailable(exc) from exc
    return {"status": "ready"}


@app.get("/orders")
def orders(repo: Repo, limit: Limit = 20) -> dict[str, Any]:
    try:
        has_priority = repo.has_priority_column()
        rows = repo.list_orders(limit)
    except Exception as exc:  # noqa: BLE001
        raise _db_unavailable(exc) from exc
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
        raise _db_unavailable(exc) from exc
    return {"customers": [present_customer(r) for r in rows]}


class TokenizeRequest(BaseModel):
    ssn: str


class IssueTicketRequest(BaseModel):
    ssn_token: str
    claim_id: int = Field(gt=0, le=2**63 - 1)  # claim.id is a bigint
    reason: str | None = None


class RevealRequest(BaseModel):
    # A reveal ticket (rtk_...). The permanent ssn_token no longer works here.
    ticket: str
    reason: str | None = None


class RefreshRequest(BaseModel):
    ticket: str
    reason: str | None = None


NO_STORE = {"Cache-Control": "no-store", "Pragma": "no-cache"}
TICKET_GONE = "ticket not found or no longer valid"


def _require_actor_and_reason(x_actor: str | None, reason: str | None) -> None:
    # TODO: X-Actor is a demo stand-in. A real deployment takes the actor
    # from the verified identity (ALB OIDC / Cognito claims), checks a
    # "may reveal SSN" role, and never trusts a client-set header.
    if not (x_actor or "").strip():
        raise HTTPException(status_code=401, detail="actor required", headers=NO_STORE)
    if not (reason or "").strip():
        raise HTTPException(status_code=400, detail="reason required", headers=NO_STORE)


def _ticket_body(t: Any) -> dict[str, Any]:
    return {"ticket": t.ticket, "claim_id": t.claim_id, "expires_at": t.expires_at.isoformat()}


def _ssn_failed(what: str, exc: Exception) -> HTTPException:
    # No audit row, no SSN, no ticket change.
    log.warning("ssn %s failed: %s", what, type(exc).__name__)
    return HTTPException(status_code=503, detail="ssn service unavailable", headers=NO_STORE)


@ssn_local.post("/ssn/tokenize")
def ssn_tokenize(body: TokenizeRequest, svc: SsnService) -> JSONResponse:
    # TODO: restrict to the sign-up and wage-loader callers (service auth),
    # and rate limit. Tokenize never returns the SSN, but it is an oracle.
    try:
        result = svc.tokenize(body.ssn)
    except InvalidSsn as exc:
        raise HTTPException(status_code=400, detail="invalid SSN format") from exc
    except Exception as exc:  # noqa: BLE001
        raise _db_unavailable(exc) from exc
    return JSONResponse(
        {"ssn_token": result.ssn_token, "ssn_hmac": result.ssn_hmac.hex()},
        status_code=201 if result.created else 200,
        headers=NO_STORE,
    )


@ssn_local.post("/ssn/tickets")
def ssn_issue_ticket(
    body: IssueTicketRequest,
    svc: SsnService,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    _require_actor_and_reason(x_actor, body.reason)
    try:
        t = svc.issue_ticket(body.ssn_token, body.claim_id, actor=x_actor or "", reason=body.reason or "")
    except NoOpenClaim as exc:
        raise HTTPException(status_code=404, detail="no open claim for this token", headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001
        raise _ssn_failed("ticket issue", exc) from exc
    return JSONResponse(_ticket_body(t), status_code=201, headers=NO_STORE)


@ssn_local.post("/ssn/reveal")
def ssn_reveal(
    body: RevealRequest,
    svc: SsnService,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    _require_actor_and_reason(x_actor, body.reason)
    try:
        ssn, row, t = svc.reveal(body.ticket, actor=x_actor or "", reason=body.reason or "")
    except TicketNotValid as exc:
        # Unknown, expired, used, revoked and closed claim all look the same.
        raise HTTPException(status_code=404, detail=TICKET_GONE, headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001 - no audit row, no SSN
        raise _ssn_failed("reveal", exc) from exc
    return JSONResponse({"ssn_token": row.ssn_token, "claim_id": t.claim_id, "ssn": ssn}, headers=NO_STORE)


@ssn_local.post("/ssn/tickets/refresh")
def ssn_refresh_ticket(
    body: RefreshRequest,
    request: Request,
    svc: SsnService,
    reauth: Reauth,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    _require_actor_and_reason(x_actor, body.reason)
    if not reauth.verify(x_actor or "", request.headers):
        raise HTTPException(status_code=401, detail="re-authentication required", headers=NO_STORE)
    try:
        t = svc.refresh(body.ticket, actor=x_actor or "", reason=body.reason or "")
    except TicketNotValid as exc:
        raise HTTPException(status_code=404, detail=TICKET_GONE, headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001
        raise _ssn_failed("ticket refresh", exc) from exc
    return JSONResponse(_ticket_body(t), status_code=201, headers=NO_STORE)


def add_ssn_routes(target: FastAPI) -> None:
    """Register the in-process /ssn handlers on target. Each route is built
    on target, so dependency overrides set on target apply."""
    for r in ssn_local.routes:
        if not isinstance(r, APIRoute):
            continue
        target.add_api_route(
            r.path,
            r.endpoint,
            methods=sorted(r.methods),
            name=r.name,
            status_code=r.status_code,
            response_model=r.response_model,
            response_class=r.response_class,
        )


# The fallback: the same handlers, run in this process. It shares the app's
# dependency overrides, so tests that swap the SSN service on the app swap
# it here too.
local_ssn_app = FastAPI(title="SSN fallback", docs_url=None, redoc_url=None, openapi_url=None)
local_ssn_app.add_exception_handler(RequestValidationError, _validation_error)
local_ssn_app.dependency_overrides = app.dependency_overrides
add_ssn_routes(local_ssn_app)


async def _call_local(request: Request, body: bytes) -> Response:
    """Run the request through local_ssn_app in process: same validation,
    dependencies, re-auth check and error handling as before the vault."""
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": request.scope.get("http_version", "1.1"),
        "method": request.method,
        "scheme": request.url.scheme,
        "path": request.url.path,
        "raw_path": request.url.path.encode("ascii"),
        "root_path": "",
        "query_string": request.scope.get("query_string", b""),
        "headers": list(request.scope.get("headers", [])),
        "client": request.scope.get("client"),
        "server": request.scope.get("server"),
        "state": {},
    }
    delivered = False

    async def receive() -> dict[str, Any]:
        nonlocal delivered
        if not delivered:
            delivered = True
            return {"type": "http.request", "body": body, "more_body": False}
        return {"type": "http.disconnect"}

    start: dict[str, Any] = {}
    chunks: list[bytes] = []

    async def send(message: dict[str, Any]) -> None:
        if message["type"] == "http.response.start":
            start.update(message)
        elif message["type"] == "http.response.body":
            chunks.append(message.get("body", b""))

    try:
        await local_ssn_app(scope, receive, send)
    except Exception as exc:  # noqa: BLE001 - the 500 may already be in start
        log.warning("ssn local fallback failed: %s", type(exc).__name__)
        if not start:
            return JSONResponse({"detail": "ssn service unavailable"}, status_code=503, headers=NO_STORE)
    response = Response(content=b"".join(chunks), status_code=int(start["status"]))
    response.raw_headers = list(start.get("headers", []))
    return response


VaultDep = Annotated[VaultClient | None, Depends(get_vault_client)]


async def ssn_via_vault(request: Request, vault: VaultDep) -> Response:
    """Forward to the SSN vault service. Any answer below 500 goes back
    unchanged. No answer, or a 5xx, means the in-process handlers answer."""
    route = request.url.path
    body = await request.body()
    started = time.monotonic()

    def elapsed_ms() -> int:
        return int((time.monotonic() - started) * 1000)

    if vault is None:
        log_fallback(route, "no_vault_url", "")
        return await _call_local(request, body)
    try:
        answer = await run_in_threadpool(vault.send, route, body, request.headers)
    except VaultUnavailable as exc:
        log_fallback(route, exc.reason, vault.name_prefix, error=exc.error, latency_ms=elapsed_ms())
        return await _call_local(request, body)
    if answer.status >= 500:
        log_fallback(route, "vault_5xx", vault.name_prefix, vault_status=answer.status, latency_ms=elapsed_ms())
        return await _call_local(request, body)
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
