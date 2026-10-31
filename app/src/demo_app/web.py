"""HTTP pieces shared by the app (main.py) and the SSN vault (vault.py).

Nothing here touches the SSN token service, KMS, the pepper or the vault
database login.
"""

from __future__ import annotations

import logging
import os

from fastapi import HTTPException, Request
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .ssn.redact import install_log_redaction

APP_VERSION = os.environ.get("APP_VERSION", "dev")
NO_STORE = {"Cache-Control": "no-store", "Pragma": "no-cache"}
SSN_UNAVAILABLE = "ssn service unavailable"

log = logging.getLogger("demo_app")


def setup_logging() -> None:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    install_log_redaction()


def db_unavailable(exc: Exception) -> HTTPException:
    # Log the detail, return a generic message. No hostnames or errors leak.
    log.warning("database call failed: %s", type(exc).__name__)
    return HTTPException(status_code=503, detail="database unavailable")


async def validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    # FastAPI's default 422 echoes the bad input back. On /ssn that input
    # can be an SSN, so return a bare message instead.
    if request.url.path.startswith(("/ssn/", "/demo/")):
        return JSONResponse(status_code=422, content={"detail": "invalid request"})
    return await request_validation_exception_handler(request, exc)
