"""SSN token service.

The database holds the claim check (ssn_token, ssn_hmac on claimant). The
vault holds the coat (ssn_vault, the SSN encrypted with a dedicated KMS
key). Seeing the coat takes a reveal ticket (ssn_ticket): one use, tied to
an open claim, 72 hours at most. Issue, reveal and refresh need an actor
and a reason and each write their own audit_event row in the same
transaction.
"""

import importlib
from typing import Any

# Names are loaded on first use, not when the package is imported. The app
# imports only ssn.redact; importing that must not pull in the token
# service, the KMS encryptor or the vault store, which only the vault
# service uses.
_WHERE = {
    "Encryptor": "crypto",
    "FakeEncryptor": "crypto",
    "KmsEncryptor": "crypto",
    "HeaderReauthVerifier": "reauth",
    "ReauthVerifier": "reauth",
    "RedactSsnFilter": "redact",
    "install_log_redaction": "redact",
    "InvalidSsn": "service",
    "NoOpenClaim": "service",
    "RevealNotAllowed": "service",
    "SsnTokenService": "service",
    "TicketNotValid": "service",
    "TokenNotFound": "service",
    "TokenizeResult": "service",
    "hmac_ssn": "service",
    "new_ticket": "service",
    "new_token": "service",
    "normalize_ssn": "service",
    "PostgresVaultStore": "store",
    "TicketRejected": "store",
    "TicketRow": "store",
    "VaultRow": "store",
    "VaultStore": "store",
}


def __getattr__(name: str) -> Any:
    module = _WHERE.get(name)
    if module is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    return getattr(importlib.import_module(f"{__name__}.{module}"), name)


__all__ = [  # noqa: F822 - loaded by __getattr__
    "Encryptor",
    "FakeEncryptor",
    "HeaderReauthVerifier",
    "InvalidSsn",
    "KmsEncryptor",
    "NoOpenClaim",
    "PostgresVaultStore",
    "ReauthVerifier",
    "RedactSsnFilter",
    "RevealNotAllowed",
    "SsnTokenService",
    "TicketNotValid",
    "TicketRejected",
    "TicketRow",
    "TokenNotFound",
    "TokenizeResult",
    "VaultRow",
    "VaultStore",
    "hmac_ssn",
    "install_log_redaction",
    "new_ticket",
    "new_token",
    "normalize_ssn",
]
