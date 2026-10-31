"""Where a task is running: its environment name prefix, from the ECS task
metadata or a local override. Shared by the app and the SSN vault service.

Nothing here reads a secret, a key or a database login. The SSN-only part
(key, pepper, vault login) is in ssn/config.py, which only the vault
service imports.

name_prefix (for example migdemo-testing): SSN_NAME_PREFIX wins if set, for
local runs. Otherwise it comes from the ECS task metadata endpoint, which
Fargate gives every container as ECS_CONTAINER_METADATA_URI_V4: the task
family is "<name_prefix>-app" (modules/ecs) or, for the vault-only service,
"<name_prefix>-ssn-vault" (modules/ssn_vault_service).
"""

from __future__ import annotations

import json
import re
import threading
import time
import urllib.parse
import urllib.request
from typing import Any, Callable, Generic, Mapping, TypeVar

NAME_PREFIX_ENV = "SSN_NAME_PREFIX"
METADATA_ENV = "ECS_CONTAINER_METADATA_URI_V4"
APP_FAMILY_SUFFIX = "-app"  # modules/ecs: family = "${name_prefix}-app"
VAULT_FAMILY_SUFFIX = "-ssn-vault"  # modules/ssn_vault_service
FAMILY_SUFFIXES = (APP_FAMILY_SUFFIX, VAULT_FAMILY_SUFFIX)

# Fargate's task metadata endpoint. Anything else is refused, so a bad env
# value can't point the app at some other host.
_METADATA_HOST = "169.254.170.2"
_PREFIX_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$")


class ConfigError(RuntimeError):
    """The task can't work out its configuration. The message is safe to log."""


def _check_prefix(prefix: str, source: str) -> str:
    if not _PREFIX_RE.fullmatch(prefix):
        raise ConfigError(f"name prefix from {source} is not a valid name")
    return prefix


def fetch_task_metadata(uri: str, timeout: float = 2.0) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "http" or parsed.hostname != _METADATA_HOST:
        raise ConfigError("ECS metadata URI is not the Fargate metadata endpoint")
    # Fixed scheme and host checked above, so B310's file:// concern can't apply.
    with urllib.request.urlopen(uri.rstrip("/") + "/task", timeout=timeout) as resp:  # nosec B310
        return json.loads(resp.read().decode("utf-8"))


def resolve_name_prefix(
    env: Mapping[str, str],
    metadata: Callable[[str], dict[str, Any]] = fetch_task_metadata,
) -> tuple[str, dict[str, Any] | None]:
    """Returns the name prefix and the task metadata, if it was read."""
    override = env.get(NAME_PREFIX_ENV, "").strip()
    if override:
        return _check_prefix(override, NAME_PREFIX_ENV), None
    uri = env.get(METADATA_ENV, "").strip()
    if not uri:
        raise ConfigError(f"name prefix unknown: neither {NAME_PREFIX_ENV} nor {METADATA_ENV} is set")
    try:
        meta = metadata(uri)
    except ConfigError:
        raise
    except Exception as exc:  # noqa: BLE001 - network, JSON, anything
        raise ConfigError(f"ECS task metadata read failed ({type(exc).__name__})") from exc
    family = str(meta.get("Family", ""))
    for suffix in FAMILY_SUFFIXES:
        if family.endswith(suffix):
            return _check_prefix(family[: -len(suffix)], "the ECS task family"), meta
    raise ConfigError("ECS task family does not end in -app or -ssn-vault")


T = TypeVar("T")


class CachedOnSuccess(Generic[T]):
    """Builds once and keeps the result. A failure is remembered for
    retry_after seconds, so a misconfigured task doesn't call AWS on every
    request, then the next call tries again."""

    def __init__(self, build: Callable[[], T], retry_after: float = 30.0, clock: Callable[[], float] = time.monotonic):
        self._build = build
        self._retry_after = retry_after
        self._clock = clock
        self._lock = threading.Lock()
        self._value: T | None = None
        self._error: Exception | None = None
        self._failed_at = 0.0

    def get(self) -> T:
        with self._lock:
            if self._value is not None:
                return self._value
            if self._error is not None and self._clock() - self._failed_at < self._retry_after:
                raise self._error
            try:
                self._value = self._build()
            except Exception as exc:
                self._error, self._failed_at = exc, self._clock()
                raise
            self._error = None
            return self._value

    def reset(self) -> None:
        with self._lock:
            self._value, self._error, self._failed_at = None, None, 0.0
