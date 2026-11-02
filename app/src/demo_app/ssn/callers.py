"""Who may call /ssn/tokenize.

Tokenize answers 201 for a new SSN and 200 for one the vault already has,
so any caller can use it to learn whether an SSN is known. Only the
services that load SSNs should reach it: claimant sign-up and the wage
loader. The caller names itself in the X-Caller header, and the vault
checks the name against an allowlist. A missing or unknown caller gets a
403 with the same detail either way.

The allowlist:
- SSN_TOKENIZE_CALLERS, a comma separated list of names, replaces the
  default. A name is lower case letters, digits and dashes, at most 63
  characters. Bad names are dropped. If nothing valid is left, the
  default is used, so a typo can't open the route or close it for good.
- The default is claimant-signup and wage-loader. Nothing sets the env
  var today. Setting it is a task definition change, which the deploy
  pipeline treats as a replace, so change the default in code instead.
- "demo" is also allowed, but only in a "-testing" environment, worked
  out the same way as /demo/seed-claim (demo_seed.TestingOnlyGuard). It is
  what the README walk-through sends. Stage and production never allow it.

X-Caller is a header the client sets, like X-Actor. It names the caller
for the audit row and the rate limit, and keeps casual callers out, but
anyone who knows a name can send it. A real deployment proves the caller
(mutual TLS, a signed service token or SigV4) instead. The caller name is
never logged; it goes in the audit row only.
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from typing import Callable, Mapping

log = logging.getLogger("demo_app.ssn")

CALLER_HEADER = "X-Caller"
CALLERS_ENV = "SSN_TOKENIZE_CALLERS"
DEFAULT_CALLERS = frozenset({"claimant-signup", "wage-loader"})
DEMO_CALLER = "demo"
_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")

# Why a caller was refused. Logged and counted as a category only.
REJECT_NO_CALLER = "no_caller"
REJECT_UNKNOWN_CALLER = "unknown_caller"


def read_callers(env: Mapping[str, str], name: str = CALLERS_ENV) -> frozenset[str]:
    """The env var as a set of caller names, else the default. Logs the
    variable name only, never a value."""
    raw = env.get(name, "").strip()
    if not raw:
        return DEFAULT_CALLERS
    parts = [p.strip() for p in raw.split(",") if p.strip()]
    good = frozenset(p for p in parts if _NAME_RE.fullmatch(p) and p != DEMO_CALLER)
    if len(good) != len(parts):
        log.warning("%s has names that are not allowed, they are ignored", name)
    if not good:
        log.warning("%s has no usable names, using the default", name)
        return DEFAULT_CALLERS
    return good


@dataclass(frozen=True)
class CallerDecision:
    caller: str | None  # the name to record, when allowed
    reason: str = ""  # REJECT_* when refused


@dataclass
class CallerPolicy:
    services: frozenset[str]
    demo_allowed: Callable[[], bool] = field(default=lambda: False)

    def check(self, header: str | None) -> CallerDecision:
        name = (header or "").strip()
        if not name:
            return CallerDecision(None, REJECT_NO_CALLER)
        if name in self.services:
            return CallerDecision(name)
        if name == DEMO_CALLER and self.demo_allowed():
            return CallerDecision(name)
        return CallerDecision(None, REJECT_UNKNOWN_CALLER)


def policy_from_env(env: Mapping[str, str] | None = None) -> CallerPolicy:
    from ..demo_seed import TestingOnlyGuard  # lazy: only the vault needs it

    env = os.environ if env is None else env
    return CallerPolicy(read_callers(env), TestingOnlyGuard(env).allowed)
