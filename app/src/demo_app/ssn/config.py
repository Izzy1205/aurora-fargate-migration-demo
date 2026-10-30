"""Where the token service finds its key, pepper and database login.

Nothing here comes from the task definition. Changing the task definition's
environment or secrets makes Terraform replace it, and the deploy pipeline
refuses any plan that deletes or replaces a resource. So the app works it
out at runtime with its own task role:

1. name_prefix (for example migdemo-testing). SSN_NAME_PREFIX wins if set,
   for local runs. Otherwise it comes from the ECS task metadata endpoint,
   which Fargate gives every container as ECS_CONTAINER_METADATA_URI_V4:
   the task family is "<name_prefix>-app", set by modules/ecs.
2. The KMS key, by its fixed alias alias/<name_prefix>-ssn. DescribeKey
   turns that into the key ARN, which is what each vault row records.
3. The HMAC pepper, from Secrets Manager at <name_prefix>/ssn/hmac-pepper.
   An operator sets the value once, out of band. Hex, at least 32 bytes.
4. The database login ssn_vault_login, which has no password. Each
   connection uses a short-lived IAM auth token signed with the task role.
   SSN_DB_PASSWORD, if set, is used instead, for local runs only.

Errors carry only non-sensitive detail: which step failed and an AWS error
code, never a secret value, key material or response body.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Generic, Mapping, TypeVar

from .service import MIN_PEPPER_BYTES

NAME_PREFIX_ENV = "SSN_NAME_PREFIX"
METADATA_ENV = "ECS_CONTAINER_METADATA_URI_V4"
VAULT_DB_USER = "ssn_vault_login"  # matches db-logins.sql and modules/ssn_vault
APP_FAMILY_SUFFIX = "-app"  # modules/ecs: family = "${name_prefix}-app"

# Fargate's task metadata endpoint. Anything else is refused, so a bad env
# value can't point the app at some other host.
_METADATA_HOST = "169.254.170.2"
_PREFIX_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$")
_REGION_RE = re.compile(r"^[a-z]{2}(-[a-z]+)+-[0-9]$")


class SsnConfigError(RuntimeError):
    """The token service can't start. The message is safe to log."""


@dataclass(frozen=True)
class SsnRuntimeConfig:
    name_prefix: str
    region: str
    key_arn: str
    pepper: bytes = field(repr=False)
    db_user: str

    @property
    def key_alias(self) -> str:
        return key_alias(self.name_prefix)


def key_alias(name_prefix: str) -> str:
    return f"alias/{name_prefix}-ssn"


def pepper_secret_name(name_prefix: str) -> str:
    return f"{name_prefix}/ssn/hmac-pepper"


def _check_prefix(prefix: str, source: str) -> str:
    if not _PREFIX_RE.fullmatch(prefix):
        raise SsnConfigError(f"name prefix from {source} is not a valid name")
    return prefix


def fetch_task_metadata(uri: str, timeout: float = 2.0) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "http" or parsed.hostname != _METADATA_HOST:
        raise SsnConfigError("ECS metadata URI is not the Fargate metadata endpoint")
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
        raise SsnConfigError(f"name prefix unknown: neither {NAME_PREFIX_ENV} nor {METADATA_ENV} is set")
    try:
        meta = metadata(uri)
    except SsnConfigError:
        raise
    except Exception as exc:  # noqa: BLE001 - network, JSON, anything
        raise SsnConfigError(f"ECS task metadata read failed ({type(exc).__name__})") from exc
    family = str(meta.get("Family", ""))
    if not family.endswith(APP_FAMILY_SUFFIX):
        raise SsnConfigError("ECS task family does not end in -app")
    return _check_prefix(family[: -len(APP_FAMILY_SUFFIX)], "the ECS task family"), meta


def resolve_region(env: Mapping[str, str], meta: dict[str, Any] | None) -> str:
    # Fargate sets AWS_REGION. The task ARN is the fallback.
    for var in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        value = env.get(var, "").strip()
        if value:
            if not _REGION_RE.fullmatch(value):
                raise SsnConfigError(f"{var} is not a region name")
            return value
    arn = str((meta or {}).get("TaskARN", ""))
    parts = arn.split(":")
    if len(parts) > 3 and _REGION_RE.fullmatch(parts[3]):
        return parts[3]
    raise SsnConfigError("AWS region unknown")


def _aws_error(step: str, exc: Exception) -> SsnConfigError:
    # ClientError messages can quote ARNs and names, so log the code only.
    code = getattr(exc, "response", {}).get("Error", {}).get("Code") if hasattr(exc, "response") else None
    return SsnConfigError(f"{step} failed ({code or type(exc).__name__})")


def resolve_key_arn(kms: Any, alias: str) -> str:
    try:
        meta = kms.describe_key(KeyId=alias)["KeyMetadata"]
    except Exception as exc:  # noqa: BLE001
        raise _aws_error("KMS key lookup", exc) from exc
    if meta.get("KeyState") != "Enabled":
        raise SsnConfigError("KMS key is not enabled")
    return str(meta["Arn"])


def parse_pepper(value: str, source: str) -> bytes:
    try:
        pepper = bytes.fromhex(value.strip())
    except ValueError as exc:
        raise SsnConfigError(f"{source} must be hex") from exc
    if len(pepper) < MIN_PEPPER_BYTES:
        raise SsnConfigError(f"{source} must be at least {MIN_PEPPER_BYTES} bytes")
    return pepper


def read_pepper(secrets: Any, secret_id: str) -> bytes:
    try:
        resp = secrets.get_secret_value(SecretId=secret_id)
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "response", {}).get("Error", {}).get("Code") if hasattr(exc, "response") else None
        if code == "ResourceNotFoundException":
            # Also what Secrets Manager says when the secret exists but no
            # value was ever set, the state Terraform leaves it in.
            raise SsnConfigError("pepper secret missing or has no value yet") from exc
        raise _aws_error("pepper secret read", exc) from exc
    value = resp.get("SecretString")
    if not value:
        raise SsnConfigError("pepper secret has no string value")
    return parse_pepper(value, "pepper secret")


ClientFactory = Callable[[str, str], Any]


def boto3_client(service: str, region: str) -> Any:
    import boto3  # lazy, like KmsEncryptor

    return boto3.session.Session(region_name=region).client(service)


def load_runtime_config(
    env: Mapping[str, str] | None = None,
    client: ClientFactory = boto3_client,
    metadata: Callable[[str], dict[str, Any]] = fetch_task_metadata,
) -> SsnRuntimeConfig:
    env = os.environ if env is None else env
    prefix, meta = resolve_name_prefix(env, metadata)
    region = resolve_region(env, meta)
    key_arn = resolve_key_arn(client("kms", region), key_alias(prefix))
    pepper = read_pepper(client("secretsmanager", region), pepper_secret_name(prefix))
    return SsnRuntimeConfig(
        name_prefix=prefix,
        region=region,
        key_arn=key_arn,
        pepper=pepper,
        db_user=env.get("SSN_DB_USER", "").strip() or VAULT_DB_USER,
    )


def iam_auth_password(rds: Any, host: str, port: int, user: str, region: str) -> Callable[[], str]:
    """A fresh IAM auth token per connection. Tokens last 15 minutes and are
    signed locally with the task role's credentials; no API call."""

    def token() -> str:
        return str(rds.generate_db_auth_token(DBHostname=host, Port=port, DBUsername=user, Region=region))

    return token


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
