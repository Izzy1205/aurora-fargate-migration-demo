"""SSN token service.

The database holds the ticket (ssn_token, ssn_hmac on claimant). The vault
holds the coat (ssn_vault, the SSN encrypted with a dedicated KMS key).
Every reveal needs an actor and a reason and writes an audit_event row in
the same transaction as the read.
"""

from .crypto import Encryptor, FakeEncryptor, KmsEncryptor
from .redact import RedactSsnFilter, install_log_redaction
from .service import (
    InvalidSsn,
    RevealNotAllowed,
    SsnTokenService,
    TokenNotFound,
    TokenizeResult,
    hmac_ssn,
    new_token,
    normalize_ssn,
)
from .store import PostgresVaultStore, VaultRow, VaultStore

__all__ = [
    "Encryptor",
    "FakeEncryptor",
    "InvalidSsn",
    "KmsEncryptor",
    "PostgresVaultStore",
    "RedactSsnFilter",
    "RevealNotAllowed",
    "SsnTokenService",
    "TokenNotFound",
    "TokenizeResult",
    "VaultRow",
    "VaultStore",
    "hmac_ssn",
    "install_log_redaction",
    "new_token",
    "normalize_ssn",
]
