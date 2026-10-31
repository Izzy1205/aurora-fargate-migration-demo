"""Vault-only entry point: the SSN token service on its own.

Run with `uvicorn demo_app.vault:app`. modules/ssn_vault_service sets that
as the container command, on the same image as the app.

It serves:

/health  liveness, never touches the database or AWS
/ssn/*   the four SSN routes (tokenize, tickets, reveal, tickets/refresh)
         from ssn_api.py

Nothing else. No /, /orders, /customers, /ready or /demo/*.

This module never imports demo_app.main, and the app never imports
ssn_api, so the vault can't forward to itself and the app has no SSN code.
Each route is built on this app, so dependency overrides set on this app
apply here.

One JSON line per /ssn request: route, status and latency only.
"""

from __future__ import annotations

import time
from typing import Awaitable, Callable

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError

from .ssn_api import add_ssn_routes
from .ssn_vault_client import SSN_PATHS, log_served
from .web import APP_VERSION, setup_logging, validation_error

setup_logging()

SSN_PREFIX = "/ssn/"

app = FastAPI(title="SSN token service", version=APP_VERSION, docs_url=None, redoc_url=None, openapi_url=None)

# Same bare 422 as the app, so a bad request never echoes an SSN back.
app.add_exception_handler(RequestValidationError, validation_error)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "version": APP_VERSION, "mode": "ssn-vault"}


add_ssn_routes(app)


@app.middleware("http")
async def _log_ssn_requests(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
    path = request.url.path
    if not path.startswith(SSN_PREFIX):
        return await call_next(request)
    started = time.monotonic()
    response = await call_next(request)
    route = path if path in SSN_PATHS else "other"
    log_served(route, response.status_code, int((time.monotonic() - started) * 1000))
    return response
