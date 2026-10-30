"""Log guard. Anything that looks like an SSN is masked before a log line
is written. This is a backstop: the service never logs an SSN on purpose."""

from __future__ import annotations

import logging
import re

_SSN_RE = re.compile(r"(?<!\d)\d{3}[- ]?\d{2}[- ]?\d{4}(?!\d)")
MASK = "[REDACTED-SSN]"


def redact(text: str) -> str:
    return _SSN_RE.sub(MASK, text)


class RedactSsnFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - a bad format string shouldn't drop the guard
            message = str(record.msg)
        record.msg = redact(message)
        record.args = None
        if record.exc_text:
            record.exc_text = redact(record.exc_text)
        return True


def install_log_redaction(logger: logging.Logger | None = None) -> None:
    """Add the filter to every handler on the logger (root by default)."""
    target = logger or logging.getLogger()
    for handler in target.handlers:
        if not any(isinstance(f, RedactSsnFilter) for f in handler.filters):
            handler.addFilter(RedactSsnFilter())
