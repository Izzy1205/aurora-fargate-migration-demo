"""Vault-only entry point: the SSN token service on its own.

Run with `uvicorn demo_app.vault:app`. modules/ssn_vault_service sets that
as the container command, on the same image as the app.

It serves:

/health  liveness, never touches the database or AWS
/ssn/*   the same four routes as the app (tokenize, tickets, reveal,
         tickets/refresh), with the same handlers and dependencies

Nothing else. No /, /orders, /customers, /ready or /demo/*.

The /ssn routes are re-registered from demo_app.main's handlers, so the
app itself is not changed and both always run the same code. Each route is
built on this app, so dependency overrides set on this app apply here.
"""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute

from . import main

SSN_PREFIX = "/ssn/"

app = FastAPI(title="SSN token service", version=main.APP_VERSION, docs_url=None, redoc_url=None, openapi_url=None)

# Same bare 422 as the app, so a bad request never echoes an SSN back.
app.add_exception_handler(RequestValidationError, main._validation_error)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "version": main.APP_VERSION, "mode": "ssn-vault"}


def ssn_routes() -> list[APIRoute]:
    return [r for r in main.app.routes if isinstance(r, APIRoute) and r.path.startswith(SSN_PREFIX)]


for _r in ssn_routes():
    app.add_api_route(
        _r.path,
        _r.endpoint,
        methods=sorted(_r.methods),
        name=_r.name,
        status_code=_r.status_code,
        response_model=_r.response_model,
        response_class=_r.response_class,
    )
