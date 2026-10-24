from datetime import datetime, timezone

import pytest

from demo_app.presenters import display_priority, order_columns_to_select, present_order

BASE_ROW = {
    "id": 7,
    "customer_id": 3,
    "status": "shipped",
    "total_cents": 1999,
    "created_at": datetime(2026, 10, 1, tzinfo=timezone.utc),
}


def test_row_from_before_v3_has_no_priority_key():
    out = present_order(BASE_ROW)
    assert out["priority"] == "standard"
    assert out["priority_set"] is False
    assert out["total"] == "19.99"


def test_null_priority_after_v3_shows_default():
    out = present_order({**BASE_ROW, "priority": None})
    assert out["priority"] == "standard"
    assert out["priority_set"] is False


def test_set_priority_is_shown():
    out = present_order({**BASE_ROW, "priority": "overnight"})
    assert out["priority"] == "overnight"
    assert out["priority_set"] is True


@pytest.mark.parametrize("raw", [None, "", "  ", "warp-speed", 42])
def test_unknown_values_fall_back_to_standard(raw):
    assert display_priority(raw) == "standard"


def test_select_list_skips_missing_column():
    cols = order_columns_to_select({"id", "customer_id", "status", "total_cents", "created_at"})
    assert "priority" not in cols


def test_select_list_includes_column_once_it_exists():
    cols = order_columns_to_select({"id", "customer_id", "status", "total_cents", "created_at", "priority"})
    assert cols[-1] == "priority"
