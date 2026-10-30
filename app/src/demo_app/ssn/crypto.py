"""Encrypting the SSN.

KmsEncryptor calls KMS Encrypt and Decrypt directly. An SSN is nine bytes,
far under KMS's 4 KB limit, so there's no data key to manage: the ciphertext
blob KMS returns is the envelope, and it names the key that made it.

Every call binds the encryption context {purpose: ssn, token: <token>}.
The task role's IAM policy only allows these calls with purpose=ssn, and a
blob moved onto another row fails to decrypt because the token differs.
"""

from __future__ import annotations

from typing import Any, Protocol


class Encryptor(Protocol):
    key_id: str

    def encrypt(self, plaintext: bytes, context: dict[str, str]) -> bytes: ...

    def decrypt(self, ciphertext: bytes, context: dict[str, str]) -> bytes: ...


class KmsEncryptor:
    def __init__(self, key_id: str, client: Any | None = None) -> None:
        if not key_id:
            raise ValueError("KMS key id is required")
        self.key_id = key_id
        if client is None:
            import boto3  # imported here so tests and the rest of the app don't need it

            client = boto3.client("kms")
        self._kms = client

    def encrypt(self, plaintext: bytes, context: dict[str, str]) -> bytes:
        resp = self._kms.encrypt(KeyId=self.key_id, Plaintext=plaintext, EncryptionContext=context)
        return resp["CiphertextBlob"]

    def decrypt(self, ciphertext: bytes, context: dict[str, str]) -> bytes:
        # KeyId pins the key, so a blob made with some other key is refused.
        resp = self._kms.decrypt(KeyId=self.key_id, CiphertextBlob=ciphertext, EncryptionContext=context)
        return resp["Plaintext"]


class FakeEncryptor:
    """For tests only. XORs with a fixed pad and checks the context, so a
    test can prove the stored bytes are not the SSN and that the context is
    enforced. Not encryption."""

    key_id = "fake-key"

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str]]] = []

    @staticmethod
    def _xor(data: bytes) -> bytes:
        pad = b"not-a-real-key!!"
        return bytes(b ^ pad[i % len(pad)] for i, b in enumerate(data))

    def encrypt(self, plaintext: bytes, context: dict[str, str]) -> bytes:
        self.calls.append(("encrypt", dict(context)))
        tag = repr(sorted(context.items())).encode()
        return self._xor(tag + b"|" + plaintext)

    def decrypt(self, ciphertext: bytes, context: dict[str, str]) -> bytes:
        self.calls.append(("decrypt", dict(context)))
        tag, _, plaintext = self._xor(ciphertext).partition(b"|")
        if tag != repr(sorted(context.items())).encode():
            raise ValueError("encryption context mismatch")
        return plaintext
