"""HTTP API for the demo.

/health  liveness, never touches the database (used by the ALB)
/ready   readiness, checks the database
/orders  JSON, includes priority whether or not the V3 column exists
/customers JSON
/        small HTML page for the live demo
/ssn/tokenize  POST, SSN in, token and HMAC out (see ssn/)
/ssn/reveal    POST, token in, SSN out, needs actor and reason, audited
"""

from __future__ import annotations

import html
import logging
import os
from functools import lru_cache
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

from .db import DbSettings, Repository
from .presenters import present_customer, present_order
from .ssn import (
    InvalidSsn,
    KmsEncryptor,
    PostgresVaultStore,
    RevealNotAllowed,
    SsnTokenService,
    TokenNotFound,
    install_log_redaction,
)
from .ssn.config import (
    CachedOnSuccess,
    SsnConfigError,
    boto3_client,
    iam_auth_password,
    load_runtime_config,
)

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
install_log_redaction()
log = logging.getLogger("demo_app")

APP_VERSION = os.environ.get("APP_VERSION", "dev")

app = FastAPI(title="Migration demo", version=APP_VERSION, docs_url=None, redoc_url=None)


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


@app.exception_handler(RequestValidationError)
async def _validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    # FastAPI's default 422 echoes the bad input back. On /ssn that input
    # can be an SSN, so return a bare message instead.
    if request.url.path.startswith("/ssn/"):
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


class RevealRequest(BaseModel):
    token: str
    reason: str | None = None


NO_STORE = {"Cache-Control": "no-store", "Pragma": "no-cache"}


@app.post("/ssn/tokenize")
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


@app.post("/ssn/reveal")
def ssn_reveal(
    body: RevealRequest,
    svc: SsnService,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    # TODO: X-Actor is a demo stand-in. A real deployment takes the actor
    # from the verified identity (ALB OIDC / Cognito claims), checks a
    # "may reveal SSN" role, and never trusts a client-set header.
    if not (x_actor or "").strip():
        raise HTTPException(status_code=401, detail="actor required", headers=NO_STORE)
    if not (body.reason or "").strip():
        raise HTTPException(status_code=400, detail="reason required", headers=NO_STORE)
    try:
        ssn = svc.reveal(body.token, actor=x_actor or "", reason=body.reason or "")
    except TokenNotFound as exc:
        raise HTTPException(status_code=404, detail="token not found", headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001 - no audit row, no SSN
        log.warning("ssn reveal failed: %s", type(exc).__name__)
        raise HTTPException(status_code=503, detail="ssn service unavailable", headers=NO_STORE) from exc
    return JSONResponse({"ssn_token": body.token, "ssn": ssn}, headers=NO_STORE)


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
