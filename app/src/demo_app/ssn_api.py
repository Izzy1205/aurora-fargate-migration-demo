"""The SSN token service's HTTP handlers. Only the vault service
(demo_app.vault) imports this module.

/ssn/tokenize        POST, SSN in, token and HMAC out (see ssn/)
/ssn/tickets         POST, token and open claim in, one-use reveal ticket out
/ssn/reveal          POST, ticket in, SSN out, burns the ticket, audited
/ssn/tickets/refresh POST, ticket in, new ticket out, needs re-auth, audited

Tokenize needs an allowed X-Caller (ssn/callers.py) and is audited.
Tokenize, tickets and reveal have a per-actor rate limit
(ssn/ratelimit.py; for tokenize the actor is the caller) and answer 429
over it. Each audited action, refused ticket or caller and 429 also
writes a metric line (ssn_events.py).

This is where the token service, the KMS encryptor, the pepper and the
ssn_vault_login database connection are built. The app (demo_app.main)
never imports it; its /ssn routes only forward to the vault.
"""

from __future__ import annotations

import logging
import os
from functools import lru_cache
from typing import Annotated, Any

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel, Field

from .db import DbSettings
from .ssn.config import (
    CachedOnSuccess,
    SsnConfigError,
    boto3_client,
    iam_auth_password,
    load_runtime_config,
)
from .ssn.callers import CallerPolicy, policy_from_env
from .ssn.crypto import KmsEncryptor
from .ssn.ratelimit import REVEAL_BUCKET, TICKETS_BUCKET, TOKENIZE_BUCKET, SlidingWindowLimiter, limiter_from_env
from .ssn.reauth import HeaderReauthVerifier, ReauthVerifier
from .ssn.service import (
    ISSUE_ACTION,
    REFRESH_ACTION,
    REVEAL_ACTION,
    TOKENIZE_ACTION,
    InvalidSsn,
    NoOpenClaim,
    RevealNotAllowed,
    SsnTokenService,
    TicketNotValid,
)
from .ssn.store import PostgresVaultStore
from .ssn_events import log_audited, log_caller_rejected, log_rate_limited, log_rejected
from .web import NO_STORE, SSN_UNAVAILABLE, db_unavailable

log = logging.getLogger("demo_app")

ssn_router = APIRouter()


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
        # The first call after Aurora auto-pauses wakes it. A 20 s limit ran
        # out in testing, so 23 s, still inside the app's 30 s read timeout
        # (ssn_vault_client.py). A code default, not a task definition env
        # var, because changing the env replaces the task definition.
        connect_timeout=int(os.environ.get("DB_CONNECT_TIMEOUT", "23")),
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
        raise HTTPException(status_code=503, detail=SSN_UNAVAILABLE) from exc
    except Exception as exc:  # noqa: BLE001 - fail closed on anything
        log.warning("ssn token service not configured: %s", type(exc).__name__)
        raise HTTPException(status_code=503, detail=SSN_UNAVAILABLE) from exc


SsnService = Annotated[SsnTokenService, Depends(get_ssn_service)]


@lru_cache(maxsize=1)
def get_reauth_verifier() -> ReauthVerifier:
    # PLACEHOLDER until a real IdP step-up (OIDC max_age / auth_time). See
    # ssn/reauth.py.
    return HeaderReauthVerifier()


Reauth = Annotated[ReauthVerifier, Depends(get_reauth_verifier)]


@lru_cache(maxsize=1)
def get_rate_limiter() -> SlidingWindowLimiter:
    # One per vault process. Limits come from env vars with safe defaults,
    # so shipping this needs no task definition change.
    return limiter_from_env()


Limiter = Annotated[SlidingWindowLimiter, Depends(get_rate_limiter)]


@lru_cache(maxsize=1)
def get_tokenize_callers() -> CallerPolicy:
    # The allowlist is a code default, with an env var override, so
    # shipping this needs no task definition change. See ssn/callers.py.
    return policy_from_env()


Callers = Annotated[CallerPolicy, Depends(get_tokenize_callers)]


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


TICKET_GONE = "ticket not found or no longer valid"
TOO_MANY = "too many requests"


def _require_actor_and_reason(x_actor: str | None, reason: str | None) -> None:
    # TODO: X-Actor is a demo stand-in. A real deployment takes the actor
    # from the verified identity (ALB OIDC / Cognito claims), checks a
    # "may reveal SSN" role, and never trusts a client-set header.
    if not (x_actor or "").strip():
        raise HTTPException(status_code=401, detail="actor required", headers=NO_STORE)
    if not (reason or "").strip():
        raise HTTPException(status_code=400, detail="reason required", headers=NO_STORE)


def _check_rate(limiter: SlidingWindowLimiter, bucket: str, route: str, actor: str) -> None:
    # After the actor check, so the key is a real actor. Counts the request
    # whether it then succeeds or not; a 429 itself doesn't count.
    d = limiter.check(bucket, actor.strip())
    if not d.allowed:
        log_rate_limited(route, bucket, d.limit)
        raise HTTPException(
            status_code=429,
            detail=TOO_MANY,
            headers={**NO_STORE, "Retry-After": str(d.retry_after)},
        )


def _ticket_body(t: Any) -> dict[str, Any]:
    return {"ticket": t.ticket, "claim_id": t.claim_id, "expires_at": t.expires_at.isoformat()}


def _ssn_failed(what: str, exc: Exception) -> HTTPException:
    # No audit row, no SSN, no ticket change.
    log.warning("ssn %s failed: %s", what, type(exc).__name__)
    return HTTPException(status_code=503, detail=SSN_UNAVAILABLE, headers=NO_STORE)


CALLER_NOT_ALLOWED = "caller not allowed"


@ssn_router.post("/ssn/tokenize")
def ssn_tokenize(
    body: TokenizeRequest,
    svc: SsnService,
    limiter: Limiter,
    callers: Callers,
    x_caller: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    # Tokenize never returns the SSN, but 201 versus 200 says whether the
    # vault knows it. So only allowed callers, a per-caller limit and an
    # audit row. X-Caller is client-set, like X-Actor (see ssn/callers.py).
    decision = callers.check(x_caller)
    if decision.caller is None:
        # Same answer for a missing and an unknown caller. The metric line
        # has the category only, never the header value.
        log_caller_rejected("/ssn/tokenize", decision.reason)
        raise HTTPException(status_code=403, detail=CALLER_NOT_ALLOWED, headers=NO_STORE)
    _check_rate(limiter, TOKENIZE_BUCKET, "/ssn/tokenize", decision.caller)
    try:
        result = svc.tokenize(body.ssn, caller=decision.caller)
    except InvalidSsn as exc:
        raise HTTPException(status_code=400, detail="invalid SSN format", headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001 - includes a failed audit write: no token without a row
        raise db_unavailable(exc) from exc
    log_audited("/ssn/tokenize", TOKENIZE_ACTION)
    return JSONResponse(
        {"ssn_token": result.ssn_token, "ssn_hmac": result.ssn_hmac.hex()},
        status_code=201 if result.created else 200,
        headers=NO_STORE,
    )


@ssn_router.post("/ssn/tickets")
def ssn_issue_ticket(
    body: IssueTicketRequest,
    svc: SsnService,
    limiter: Limiter,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    _require_actor_and_reason(x_actor, body.reason)
    _check_rate(limiter, TICKETS_BUCKET, "/ssn/tickets", x_actor or "")
    try:
        t = svc.issue_ticket(body.ssn_token, body.claim_id, actor=x_actor or "", reason=body.reason or "")
    except NoOpenClaim as exc:
        log_rejected("/ssn/tickets", "no_open_claim")
        raise HTTPException(status_code=404, detail="no open claim for this token", headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001
        raise _ssn_failed("ticket issue", exc) from exc
    log_audited("/ssn/tickets", ISSUE_ACTION)
    return JSONResponse(_ticket_body(t), status_code=201, headers=NO_STORE)


@ssn_router.post("/ssn/reveal")
def ssn_reveal(
    body: RevealRequest,
    svc: SsnService,
    limiter: Limiter,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    _require_actor_and_reason(x_actor, body.reason)
    _check_rate(limiter, REVEAL_BUCKET, "/ssn/reveal", x_actor or "")
    try:
        ssn, row, t = svc.reveal(body.ticket, actor=x_actor or "", reason=body.reason or "")
    except TicketNotValid as exc:
        # Unknown, expired, used, revoked and closed claim all look the same.
        log_rejected("/ssn/reveal", exc.category)
        raise HTTPException(status_code=404, detail=TICKET_GONE, headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001 - no audit row, no SSN
        raise _ssn_failed("reveal", exc) from exc
    log_audited("/ssn/reveal", REVEAL_ACTION)
    return JSONResponse({"ssn_token": row.ssn_token, "claim_id": t.claim_id, "ssn": ssn}, headers=NO_STORE)


@ssn_router.post("/ssn/tickets/refresh")
def ssn_refresh_ticket(
    body: RefreshRequest,
    request: Request,
    svc: SsnService,
    reauth: Reauth,
    limiter: Limiter,
    x_actor: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    _require_actor_and_reason(x_actor, body.reason)
    _check_rate(limiter, TICKETS_BUCKET, "/ssn/tickets/refresh", x_actor or "")
    if not reauth.verify(x_actor or "", request.headers):
        raise HTTPException(status_code=401, detail="re-authentication required", headers=NO_STORE)
    try:
        t = svc.refresh(body.ticket, actor=x_actor or "", reason=body.reason or "")
    except TicketNotValid as exc:
        log_rejected("/ssn/tickets/refresh", exc.category)
        raise HTTPException(status_code=404, detail=TICKET_GONE, headers=NO_STORE) from exc
    except RevealNotAllowed as exc:
        raise HTTPException(status_code=400, detail=str(exc), headers=NO_STORE) from exc
    except Exception as exc:  # noqa: BLE001
        raise _ssn_failed("ticket refresh", exc) from exc
    log_audited("/ssn/tickets/refresh", REFRESH_ACTION)
    return JSONResponse(_ticket_body(t), status_code=201, headers=NO_STORE)


def add_ssn_routes(target: FastAPI) -> None:
    """Register the /ssn handlers on target. Each route is built on target,
    so dependency overrides set on target apply."""
    for r in ssn_router.routes:
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
