"""The app's client for the private SSN vault service, with fallback.

The app answers /ssn/tokenize, /ssn/tickets, /ssn/tickets/refresh and
/ssn/reveal by forwarding the request to the vault service
(modules/ssn_vault_service, demo_app.vault). The vault runs the same /ssn
handlers as the app, against the same database.

When the vault can't be used, the app answers with its own in-process SSN
code instead. That is the fallback. It happens only when:

- the vault URL can't be worked out (no name prefix),
- DNS fails, the connection is refused or times out,
- the vault doesn't answer in time or the connection drops mid-answer,
- the vault answers 5xx.

Any vault answer below 500 (200, 201, 400, 401, 404, 409, 422, 429...) is
passed back to the caller unchanged and never retried locally. A used
ticket stays a 404.

Single-use tickets stay single use. Both paths burn a ticket with the same
UPDATE ... WHERE used_at IS NULL in the same database, so if the vault
burned a ticket and then failed to answer, the local path gets a 404 for
it, not a second reveal. Refresh revokes the old ticket the same way.

Vault URL. http://ssn-vault.<name_prefix>.internal:8080, from the Cloud Map
names in modules/ssn_vault_service. name_prefix comes from the same place
the token service already gets it (ssn/config.py: SSN_NAME_PREFIX for local
runs, else the ECS task family). Nothing new goes in the task definition:
changing its environment would replace it, and the deploy pipeline refuses
plans that replace anything.

Logging. One JSON line per vault call. It holds the route, the status, the
latency, a fixed reason word and an exception class name, never a body or a
header value, so no SSN, token, ticket, actor or pepper. The lines are in
CloudWatch embedded metric format, so CloudWatch also turns them into the
metrics ssn_vault_call, ssn_vault_latency_ms and ssn_vault_fallback
(namespace MigDemo/SsnVault) without any infrastructure change.
"""

from __future__ import annotations

import http.client
import json
import logging
import os
import socket
import sys
import time
from dataclasses import dataclass
from typing import Any, Mapping

from .ssn.config import CachedOnSuccess, resolve_name_prefix
from .ssn.redact import RedactSsnFilter

# Must match modules/ssn_vault_service: aws_service_discovery_service name,
# the private DNS namespace "${name_prefix}.internal" and var.port.
VAULT_SERVICE_NAME = "ssn-vault"
VAULT_DNS_SUFFIX = ".internal"
VAULT_PORT = 8080

# Fail fast on connect. The read allows for the vault's own first call to
# wake Aurora: the DB connect timeout is 20 s (DB_CONNECT_TIMEOUT in main),
# plus a little for KMS.
CONNECT_TIMEOUT = 2.0
READ_TIMEOUT = 25.0

SSN_PATHS = ("/ssn/tokenize", "/ssn/tickets", "/ssn/tickets/refresh", "/ssn/reveal")
# The only request headers the vault gets. Everything the handlers read.
FORWARD_HEADERS = ("content-type", "x-actor", "x-reauth-actor", "x-reauth-at")
# The only response headers passed back.
RETURN_HEADERS = ("content-type", "cache-control", "pragma")
MAX_RESPONSE_BYTES = 64 * 1024

METRIC_NAMESPACE = "MigDemo/SsnVault"
EVENT_LOGGER = "demo_app.ssn_vault.events"


class VaultUnavailable(Exception):
    """The vault could not answer. reason is a fixed word, safe to log."""

    def __init__(self, reason: str, error: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.error = error


@dataclass(frozen=True)
class VaultResponse:
    status: int
    headers: dict[str, str]
    body: bytes


def vault_host(name_prefix: str) -> str:
    return f"{VAULT_SERVICE_NAME}.{name_prefix}{VAULT_DNS_SUFFIX}"


class VaultClient:
    def __init__(
        self,
        host: str,
        port: int = VAULT_PORT,
        name_prefix: str = "",
        connect_timeout: float = CONNECT_TIMEOUT,
        read_timeout: float = READ_TIMEOUT,
    ) -> None:
        self.host = host
        self.port = port
        self.name_prefix = name_prefix
        self.connect_timeout = connect_timeout
        self.read_timeout = read_timeout

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def send(self, path: str, body: bytes, headers: Mapping[str, str]) -> VaultResponse:
        """POST to the vault. Raises VaultUnavailable if there is no answer."""
        if path not in SSN_PATHS:
            raise ValueError("not an SSN vault path")
        fwd = {h: headers[h] for h in FORWARD_HEADERS if headers.get(h) is not None}
        conn = http.client.HTTPConnection(self.host, self.port, timeout=self.connect_timeout)
        try:
            try:
                conn.connect()
            except socket.gaierror as exc:
                raise VaultUnavailable("dns", type(exc).__name__) from None
            except TimeoutError as exc:
                raise VaultUnavailable("connect_timeout", type(exc).__name__) from None
            except OSError as exc:
                raise VaultUnavailable("connect_error", type(exc).__name__) from None
            if conn.sock is not None:
                conn.sock.settimeout(self.read_timeout)
            try:
                conn.request("POST", path, body=body, headers=fwd)
                resp = conn.getresponse()
                data = resp.read(MAX_RESPONSE_BYTES + 1)
            except TimeoutError as exc:
                raise VaultUnavailable("read_timeout", type(exc).__name__) from None
            except (http.client.HTTPException, OSError) as exc:
                raise VaultUnavailable("bad_response", type(exc).__name__) from None
            if len(data) > MAX_RESPONSE_BYTES:
                raise VaultUnavailable("bad_response", "ResponseTooLarge")
            kept = {h: v for h in RETURN_HEADERS if (v := resp.getheader(h)) is not None}
            return VaultResponse(resp.status, kept, data)
        finally:
            conn.close()


def _build_client() -> VaultClient:
    prefix, _ = resolve_name_prefix(os.environ)
    return VaultClient(vault_host(prefix), name_prefix=prefix)


_client = CachedOnSuccess(_build_client)


def get_vault_client() -> VaultClient | None:
    """None if the vault URL can't be worked out; the caller falls back."""
    try:
        return _client.get()
    except Exception as exc:  # noqa: BLE001 - never fail the request over this
        logging.getLogger("demo_app").warning("ssn vault url unknown: %s", type(exc).__name__)
        return None


# --- events


class _StdoutHandler(logging.StreamHandler):  # type: ignore[type-arg]
    """Writes to whatever sys.stdout is at the time, one JSON doc per line."""

    def __init__(self) -> None:
        super().__init__(sys.stdout)

    def emit(self, record: logging.LogRecord) -> None:
        self.setStream(sys.stdout)
        super().emit(record)


events = logging.getLogger(EVENT_LOGGER)
if not events.handlers:
    _h = _StdoutHandler()
    _h.setFormatter(logging.Formatter("%(message)s"))
    _h.addFilter(RedactSsnFilter())
    events.addHandler(_h)
    events.setLevel(logging.INFO)
    # Plain JSON lines only: the root format would break the metric format.
    events.propagate = False


def _emf(metrics: list[tuple[str, str]], fields: dict[str, Any], name_prefix: str) -> str:
    doc: dict[str, Any] = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": METRIC_NAMESPACE,
                    "Dimensions": [["NamePrefix"]],
                    "Metrics": [{"Name": n, "Unit": u} for n, u in metrics],
                }
            ],
        },
        "NamePrefix": name_prefix or "unknown",
    }
    doc.update(fields)
    return json.dumps(doc, separators=(",", ":"), sort_keys=True)


def log_vault_call(route: str, status: int, latency_ms: int, name_prefix: str) -> None:
    events.info(
        _emf(
            [("ssn_vault_call", "Count"), ("ssn_vault_latency_ms", "Milliseconds")],
            {
                "level": "INFO",
                "event": "ssn_vault_call",
                "route": route,
                "status": status,
                "latency_ms": latency_ms,
                "ssn_vault_call": 1,
                "ssn_vault_latency_ms": latency_ms,
            },
            name_prefix,
        )
    )


def log_fallback(
    route: str, reason: str, name_prefix: str, vault_status: int | None = None, error: str = "", latency_ms: int = 0
) -> None:
    events.warning(
        _emf(
            [("ssn_vault_fallback", "Count")],
            {
                "level": "WARN",
                "event": "ssn_vault_fallback",
                "route": route,
                "reason": reason,
                "vault_status": vault_status,
                "error": error,
                "latency_ms": latency_ms,
                "ssn_vault_fallback": 1,
            },
            name_prefix,
        )
    )


def log_served(route: str, status: int, latency_ms: int) -> None:
    """The vault's own line, one per /ssn request it answers. No metric."""
    events.info(
        json.dumps(
            {"level": "INFO", "event": "ssn_vault_served", "route": route, "status": status, "latency_ms": latency_ms},
            separators=(",", ":"),
            sort_keys=True,
        )
    )
