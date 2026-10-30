"""SSN token service.

The database holds the claim check (ssn_token, ssn_hmac on claimant). The
vault holds the coat (ssn_vault, the SSN encrypted with a dedicated KMS
key). Seeing the coat takes a reveal ticket (ssn_ticket): one use, tied to
an open claim, 72 hours at most. Issue, reveal and refresh need an actor
and a reason and each write their own audit_event row in the same
transaction.
"""

from .crypto import Encryptor, FakeEncryptor, KmsEncryptor
from .reauth import HeaderReauthVerifier, ReauthVerifier
from .redact import RedactSsnFilter, install_log_redaction
from .service import (
    InvalidSsn,
    NoOpenClaim,
    RevealNotAllowed,
    SsnTokenService,
    TicketNotValid,
    TokenNotFound,
    TokenizeResult,
    hmac_ssn,
    new_ticket,
    new_token,
    normalize_ssn,
)
from .store import PostgresVaultStore, TicketRejected, TicketRow, VaultRow, VaultStore

__all__ = [
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
