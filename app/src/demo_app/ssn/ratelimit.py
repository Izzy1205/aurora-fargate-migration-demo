"""Per-actor rate limit for the SSN vault's tokenize, ticket and reveal
routes.

The WAF already limits /ssn/reveal and /ssn/tickets per client IP at the
load balancer. It can't tell two staff behind one office IP apart, and it
can't stop one actor spread over many IPs. This limit keys on the actor
instead, so the two layers cover each other.

How it works:
- A sliding window of 60 seconds per (bucket, actor). Three buckets:
  "reveal" (/ssn/reveal), "tickets" (/ssn/tickets and
  /ssn/tickets/refresh) and "tokenize" (/ssn/tokenize). For tokenize the
  actor is the caller service from X-Caller (see callers.py).
- Every request that gets past the actor and reason checks (for
  tokenize, the caller check) counts, whether it then succeeds or gets a
  400 or 404. A 429 does not count, so an
  actor who backs off gets back in when the window moves on.
- State is in memory, in each vault task. With N vault tasks an actor can
  get up to N times the limit, and a task restart clears it. The vault is
  the only place SSN requests are served, so it is still the narrowest
  point. A shared store (DynamoDB, ElastiCache) would make it exact.
- The actor is only ever a dictionary key here. It is never logged.

Limits come from env vars, read once when the vault first needs them:
SSN_REVEAL_LIMIT_PER_MINUTE (default 5), SSN_TICKET_LIMIT_PER_MINUTE
(default 10) and SSN_TOKENIZE_LIMIT_PER_MINUTE (default 60). A missing or bad value falls back to the default, so no
task definition change is needed to ship this, and a typo can't turn the
limit off. Setting the env var does mean a task definition change, which
the deploy pipeline treats as a replace.
"""

from __future__ import annotations

import logging
import math
import os
import threading
import time
from collections import OrderedDict, deque
from dataclasses import dataclass
from typing import Callable, Mapping

log = logging.getLogger("demo_app.ssn")

WINDOW_SECONDS = 60.0
REVEAL_BUCKET = "reveal"
TICKETS_BUCKET = "tickets"
TOKENIZE_BUCKET = "tokenize"

REVEAL_LIMIT_ENV = "SSN_REVEAL_LIMIT_PER_MINUTE"
TICKET_LIMIT_ENV = "SSN_TICKET_LIMIT_PER_MINUTE"
TOKENIZE_LIMIT_ENV = "SSN_TOKENIZE_LIMIT_PER_MINUTE"
DEFAULT_REVEAL_LIMIT = 5
DEFAULT_TICKET_LIMIT = 10
# Per caller service, not per person. Sign-up tokenizes one SSN per new
# claimant. A bulk wage load would need a higher limit or a batch path.
DEFAULT_TOKENIZE_LIMIT = 60
MIN_LIMIT = 1
MAX_LIMIT = 1000

# Upper bound on actors tracked at once, so made-up X-Actor values can't
# grow memory forever. The WAF per-IP limits keep real traffic far below it.
MAX_KEYS = 10000


@dataclass(frozen=True)
class Decision:
    allowed: bool
    limit: int
    retry_after: int  # whole seconds, 0 when allowed


def read_limit(env: Mapping[str, str], name: str, default: int) -> int:
    """The env var as a whole number from MIN_LIMIT to MAX_LIMIT, else the
    default. Logs the variable name only, never the value."""
    raw = env.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        log.warning("%s is not a whole number, using the default %d", name, default)
        return default
    if not MIN_LIMIT <= value <= MAX_LIMIT:
        log.warning("%s is out of range, using the default %d", name, default)
        return default
    return value


class SlidingWindowLimiter:
    def __init__(
        self,
        limits: Mapping[str, int],
        window: float = WINDOW_SECONDS,
        clock: Callable[[], float] = time.monotonic,
        max_keys: int = MAX_KEYS,
    ) -> None:
        self.limits = dict(limits)
        self.window = window
        self._clock = clock
        self._max_keys = max_keys
        self._lock = threading.Lock()
        self._hits: OrderedDict[tuple[str, str], deque[float]] = OrderedDict()

    def check(self, bucket: str, actor: str) -> Decision:
        """Count one request for (bucket, actor) if it is under the limit."""
        limit = self.limits[bucket]
        key = (bucket, actor)
        now = self._clock()
        cutoff = now - self.window
        with self._lock:
            hits = self._hits.get(key)
            if hits is None:
                hits = deque()
                self._hits[key] = hits
            while hits and hits[0] <= cutoff:
                hits.popleft()
            self._hits.move_to_end(key)
            if len(hits) >= limit:
                retry = max(1, math.ceil(hits[0] + self.window - now))
                return Decision(False, limit, retry)
            hits.append(now)
            self._trim(cutoff)
            return Decision(True, limit, 0)

    def _trim(self, cutoff: float) -> None:
        if len(self._hits) <= self._max_keys:
            return
        for k in [k for k, v in self._hits.items() if not v or v[-1] <= cutoff]:
            del self._hits[k]
        while len(self._hits) > self._max_keys:
            self._hits.popitem(last=False)  # least recently seen actor

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()


def limiter_from_env(env: Mapping[str, str] | None = None) -> SlidingWindowLimiter:
    env = os.environ if env is None else env
    return SlidingWindowLimiter(
        {
            REVEAL_BUCKET: read_limit(env, REVEAL_LIMIT_ENV, DEFAULT_REVEAL_LIMIT),
            TICKETS_BUCKET: read_limit(env, TICKET_LIMIT_ENV, DEFAULT_TICKET_LIMIT),
            TOKENIZE_BUCKET: read_limit(env, TOKENIZE_LIMIT_ENV, DEFAULT_TOKENIZE_LIMIT),
        }
    )
