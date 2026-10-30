"""Re-authentication check for ticket refresh.

PLACEHOLDER. The demo has no identity provider yet: the actor is a
client-set X-Actor header, and ALB OIDC needs HTTPS, which the demo
doesn't have. So this is a pluggable check, and the one shipped here only
proves the shape of the flow. It must not be trusted in a real
deployment.

The real version is an IdP step-up: send the user back to sign in with
OIDC max_age (or prompt=login), then check the auth_time claim in the
verified ID token is recent and the subject matches the actor. Drop in a
verifier that does that and nothing else changes.
"""

from __future__ import annotations

import time
from typing import Callable, Mapping, Protocol

DEFAULT_MAX_AGE_SECONDS = 300
# A small allowance for clocks that run a little ahead.
FUTURE_SKEW_SECONDS = 30


class ReauthVerifier(Protocol):
    def verify(self, actor: str, headers: Mapping[str, str]) -> bool:
        """True only if this actor signed in again recently."""
        ...


class HeaderReauthVerifier:
    """Demo only. Wants X-Reauth-Actor equal to the actor and X-Reauth-At,
    a Unix time in seconds, no older than max_age. Stands in for the
    auth_time and sub claims of a fresh ID token."""

    def __init__(self, max_age_seconds: int = DEFAULT_MAX_AGE_SECONDS, clock: Callable[[], float] = time.time) -> None:
        if max_age_seconds <= 0:
            raise ValueError("max_age_seconds must be positive")
        self._max_age = max_age_seconds
        self._clock = clock

    def verify(self, actor: str, headers: Mapping[str, str]) -> bool:
        actor = (actor or "").strip()
        if not actor or (headers.get("x-reauth-actor") or "").strip() != actor:
            return False
        raw = (headers.get("x-reauth-at") or "").strip()
        if not raw.isdigit():
            return False
        age = self._clock() - int(raw)
        return -FUTURE_SKEW_SECONDS <= age <= self._max_age
