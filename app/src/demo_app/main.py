"""HTTP API for the demo.

/health  liveness, never touches the database (used by the ALB)
/ready   readiness, checks the database
/orders  JSON, includes priority whether or not the V3 column exists
/customers JSON
/        small HTML page for the live demo
"""

from __future__ import annotations

import html
import logging
import os
from functools import lru_cache
from typing import Annotated, Any

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse

from .db import DbSettings, Repository
from .presenters import present_customer, present_order

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("demo_app")

APP_VERSION = os.environ.get("APP_VERSION", "dev")

app = FastAPI(title="Migration demo", version=APP_VERSION, docs_url=None, redoc_url=None)

@lru_cache(maxsize=1)
def get_repository() -> Repository:
    return Repository(DbSettings.from_env())

Repo = Annotated[Repository, Depends(get_repository)]
Limit = Annotated[int, Query(ge=1, le=100)]

def _db_unavailable(exc: Exception) -> HTTPException:
    # Generic message so no hostnames or errors leak.
    log.warning("database call failed: %s", type(exc).__name__)
    return HTTPException(status_code=503, detail="database unavailable")

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
