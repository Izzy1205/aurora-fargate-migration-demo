"""Pure functions that turn database rows into API output.

Kept free of any database code so the null handling can be unit tested
without Postgres.
"""

from __future__ import annotations

from typing import Any, Mapping

DEFAULT_PRIORITY = "standard"
KNOWN_PRIORITIES = frozenset({"standard", "expedited", "overnight"})

# Columns the app knows about. "priority" arrived in V3 and may not exist yet.
BASE_ORDER_COLUMNS = ("id", "customer_id", "status", "total_cents", "created_at")
OPTIONAL_ORDER_COLUMNS = ("priority",)


def order_columns_to_select(existing_columns: set[str]) -> list[str]:
    """Columns to select from orders, given what the table has right now.

    Optional columns are only selected when present, so the same build runs
    before and after the V3 migration.
    """
    return list(BASE_ORDER_COLUMNS) + [c for c in OPTIONAL_ORDER_COLUMNS if c in existing_columns]


def display_priority(raw: Any) -> str:
    """Map a stored priority to what users see. NULL, missing or unknown means standard."""
    if isinstance(raw, str) and raw.strip().lower() in KNOWN_PRIORITIES:
        return raw.strip().lower()
    return DEFAULT_PRIORITY


def present_order(row: Mapping[str, Any]) -> dict[str, Any]:
    """Shape one orders row for the API.

    `priority_set` tells the caller whether the value came from the database
    or from the default, so the demo can show rows that predate V3.
    """
    raw_priority = row.get("priority")
    created = row.get("created_at")
    return {
        "id": row["id"],
        "customer_id": row["customer_id"],
        "status": row["status"],
        "total": f"{row['total_cents'] / 100:.2f}",
        "created_at": created.isoformat() if hasattr(created, "isoformat") else created,
        "priority": display_priority(raw_priority),
        "priority_set": raw_priority is not None,
    }


def present_customer(row: Mapping[str, Any]) -> dict[str, Any]:
    """Shape one customers row for the API."""
    created = row.get("created_at")
    return {
        "id": row["id"],
        "full_name": row["full_name"],
        "email": row["email"],
        "created_at": created.isoformat() if hasattr(created, "isoformat") else created,
    }
