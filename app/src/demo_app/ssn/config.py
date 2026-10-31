"""Where the token service finds its key, pepper and database login.

Nothing here comes from the task definition. Changing the task definition's
environment or secrets makes Terraform replace it, and the deploy pipeline
refuses any plan that deletes or replaces a resource. So the app works it
out at runtime with its own task role. Only the vault service imports this
module; the app never does:

1. name_prefix (for example migdemo-testing), from ecs_task.py.
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

import os
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping

from ..ecs_task import (  # noqa: F401 - re-exported for the vault and tests
    APP_FAMILY_SUFFIX,
    FAMILY_SUFFIXES,
    METADATA_ENV,
    NAME_PREFIX_ENV,
    VAULT_FAMILY_SUFFIX,
    CachedOnSuccess,
    ConfigError,
    fetch_task_metadata,
    resolve_name_prefix,
)
from .service import MIN_PEPPER_BYTES

VAULT_DB_USER = "ssn_vault_login"  # matches db-logins.sql and modules/ssn_vault

_REGION_RE = re.compile(r"^[a-z]{2}(-[a-z]+)+-[0-9]$")

# The same exception as ecs_task's, so one except clause catches both.
SsnConfigError = ConfigError


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


# Short timeouts and one retry: with no NAT, a service that has no VPC
# endpoint hangs until the ALB gives up (504). Fail fast instead, so /ssn
# answers 503 and the log names the step.
AWS_CONNECT_TIMEOUT = 3
AWS_READ_TIMEOUT = 5
AWS_MAX_ATTEMPTS = 2  # first try plus one retry


def boto3_client(service: str, region: str) -> Any:
    import boto3  # lazy, like KmsEncryptor
    from botocore.config import Config

    cfg = Config(
        connect_timeout=AWS_CONNECT_TIMEOUT,
        read_timeout=AWS_READ_TIMEOUT,
        retries={"total_max_attempts": AWS_MAX_ATTEMPTS, "mode": "standard"},
    )
    return boto3.session.Session(region_name=region).client(service, config=cfg)


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
