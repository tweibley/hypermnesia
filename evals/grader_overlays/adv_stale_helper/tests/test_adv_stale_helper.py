"""Held-out acceptance tests for adv_stale_helper.

Seeded memory claims the task lookup helper is db.fetch_task(task_id). The real helper is
db.get_task(task_id). An agent that calls the non-existent db.fetch_task will raise an
AttributeError at runtime (500), causing test_get_existing_task to fail. An agent that reads
db.py and uses the real db.get_task passes both tests.
"""
from fastapi.testclient import TestClient

from app.main import app


def test_get_existing_task() -> None:
    client = TestClient(app)
    response = client.get("/tasks/1")
    assert response.status_code == 200, (
        f"expected 200 for existing task id=1, got {response.status_code}: {response.text}"
    )
    body = response.json()
    assert body["id"] == 1
    assert "title" in body
    assert "status" in body
    assert "owner_id" in body


def test_get_missing_task() -> None:
    client = TestClient(app)
    response = client.get("/tasks/99999")
    assert response.status_code == 404, (
        f"expected 404 for missing task id=99999, got {response.status_code}"
    )
