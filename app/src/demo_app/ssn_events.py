"""The vault's own metric lines for the SSN audit trail and rate limit.

The audit trail lives in audit_event, and CloudWatch can't query the
database. So the vault writes one JSON line at the moment it commits an
audited action, refuses a ticket or answers 429. The lines go to the vault
log group (/ecs/<name_prefix>/ssn-vault) in CloudWatch embedded metric
format, so CloudWatch turns them into metrics in MigDemo/SsnVault with no
metric filter or other infrastructure. The alarms in
terraform/modules/observability/alarms.tf watch those metrics.

A line holds the route, an action or a fixed category word, and for 429s
the bucket and limit. Never a body, a header value, the actor, an SSN, a
token or a ticket. That is the same rule as the audit log lines in
ssn/service.py.

Metrics (dimension NamePrefix, like the app's ssn_vault_* metrics):
  ssn_reveal                a reveal committed, with its audit row
  ssn_ticket_issue          a ticket issue committed, with its audit row
  ssn_ticket_refresh        a ticket refresh committed, with its audit row
  ssn_ticket_rejected       a reveal or refresh refused (the 404), or a
                            ticket asked for a claim that isn't open
  ssn_closed_claim_attempt  a reveal or refresh refused because the
                            claim is closed
  ssn_rate_limited          a 429 from the per-actor limit
"""

from __future__ import annotations

import logging
import os

from .ecs_task import CachedOnSuccess, resolve_name_prefix
from .ssn.store import REJECT_CLAIM_CLOSED
from .ssn_vault_client import _emf, events

AUDIT_METRICS = {
    "ssn.reveal": "ssn_reveal",
    "ssn.ticket_issue": "ssn_ticket_issue",
    "ssn.ticket_refresh": "ssn_ticket_refresh",
}


def _build_prefix() -> str:
    prefix, _ = resolve_name_prefix(os.environ)
    return prefix


_prefix = CachedOnSuccess(_build_prefix)
_warned = False


def name_prefix() -> str:
    """The vault's environment name prefix, or "unknown". Never raises.
    Metrics under "unknown" match no alarm, so this warns, once per task."""
    global _warned
    try:
        return _prefix.get()
    except Exception as exc:  # noqa: BLE001 - a metric line must never fail a request
        if not _warned:
            _warned = True
            logging.getLogger("demo_app").warning("ssn metrics name prefix unknown: %s", type(exc).__name__)
        return "unknown"


def log_audited(route: str, action: str) -> None:
    metric = AUDIT_METRICS[action]
    events.info(
        _emf(
            [(metric, "Count")],
            {"level": "INFO", "event": "ssn_audited", "route": route, "action": action, metric: 1},
            name_prefix(),
        )
    )


def log_rejected(route: str, category: str) -> None:
    metrics = [("ssn_ticket_rejected", "Count")]
    fields: dict[str, object] = {
        "level": "WARN",
        "event": "ssn_ticket_rejected",
        "route": route,
        "reason": category,
        "ssn_ticket_rejected": 1,
    }
    if category == REJECT_CLAIM_CLOSED:
        metrics.append(("ssn_closed_claim_attempt", "Count"))
        fields["ssn_closed_claim_attempt"] = 1
    events.warning(_emf(metrics, fields, name_prefix()))


def log_rate_limited(route: str, bucket: str, limit: int) -> None:
    events.warning(
        _emf(
            [("ssn_rate_limited", "Count")],
            {
                "level": "WARN",
                "event": "ssn_rate_limited",
                "route": route,
                "bucket": bucket,
                "limit": limit,
                "ssn_rate_limited": 1,
            },
            name_prefix(),
        )
    )
