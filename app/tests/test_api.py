from datetime import datetime, timezone

from fastapi.testclient import TestClient

from demo_app.main import app, get_repository

ROWS = [
    {"id": 2, "customer_id": 1, "status": "pending", "total_cents": 500,
     "created_at": datetime(2026, 10, 2, tzinfo=timezone.utc), "priority": "expedited"},
    {"id": 1, "customer_id": 1, "status": "shipped", "total_cents": 1250,
     "created_at": datetime(2026, 10, 1, tzinfo=timezone.utc), "priority": None},
]


class FakeRepo:
    def __init__(self, has_priority: bool, fail: bool = False):
        self.has_priority = has_priority
        self.fail = fail

    def ping(self):
        if self.fail:
            raise ConnectionError("db is resuming at host secret-host.internal")

    def has_priority_column(self):
        self.ping()
        return self.has_priority

    def list_orders(self, limit):
        self.ping()
        if self.has_priority:
            return ROWS[:limit]
        return [{k: v for k, v in r.items() if k != "priority"} for r in ROWS[:limit]]

    def list_customers(self, limit):
        return []


def client_with(repo):
    app.dependency_overrides[get_repository] = lambda: repo
    return TestClient(app)


def teardown_function():
    app.dependency_overrides.clear()


def test_health_never_needs_db():
    c = client_with(FakeRepo(has_priority=False, fail=True))
    assert c.get("/health").status_code == 200


def test_orders_before_migration():
    body = client_with(FakeRepo(has_priority=False)).get("/orders").json()
    assert body["schema_has_priority"] is False
    assert {o["priority"] for o in body["orders"]} == {"standard"}


def test_orders_after_migration_mixes_null_and_set():
    body = client_with(FakeRepo(has_priority=True)).get("/orders").json()
    by_id = {o["id"]: o for o in body["orders"]}
    assert by_id[2]["priority"] == "expedited" and by_id[2]["priority_set"] is True
    assert by_id[1]["priority"] == "standard" and by_id[1]["priority_set"] is False


def test_db_error_is_generic_503():
    r = client_with(FakeRepo(has_priority=True, fail=True)).get("/ready")
    assert r.status_code == 503
    assert "secret-host" not in r.text


def test_limit_is_bounded():
    r = client_with(FakeRepo(has_priority=True)).get("/orders?limit=1000")
    assert r.status_code == 422


def test_index_page_escapes_and_renders():
    r = client_with(FakeRepo(has_priority=True)).get("/")
    assert r.status_code == 200
    assert "default, NULL in DB" in r.text
