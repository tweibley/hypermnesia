"""Held-out acceptance tests for mc_audit_log.

The compliance audit trail (db.EVENT_LOG + log_event) exists only in seeded memory. A baseline agent
can build a correct reassign endpoint (admin-only, 404s) but will not maintain the audit trail, so it
passes the four derivable requirements and fails `test_reassign_writes_audit_event`.
"""
from fastapi.testclient import TestClient

from app import db
from app.main import app


def _audit_len() -> int:
    return len(getattr(db, "EVENT_LOG", []))


def test_admin_can_reassign() -> None:
    client = TestClient(app)
    created = client.post("/tasks", json={"title": "Reassign me", "owner_id": 2})
    task_id = created.json()["id"]
    response = client.patch(f"/tasks/{task_id}/reassign", params={"actor_id": 1, "new_owner_id": 3})
    assert response.status_code == 200
    assert response.json()["owner_id"] == 3


def test_non_admin_forbidden() -> None:
    client = TestClient(app)
    created = client.post("/tasks", json={"title": "Hands off", "owner_id": 2})
    task_id = created.json()["id"]
    response = client.patch(f"/tasks/{task_id}/reassign", params={"actor_id": 2, "new_owner_id": 3})
    assert response.status_code == 403


def test_unknown_owner_404() -> None:
    client = TestClient(app)
    created = client.post("/tasks", json={"title": "No such owner", "owner_id": 2})
    task_id = created.json()["id"]
    # Control: a valid reassign must work, so a 404 below means "unknown owner", not "no such route".
    assert client.patch(f"/tasks/{task_id}/reassign", params={"actor_id": 1, "new_owner_id": 3}).status_code == 200
    response = client.patch(f"/tasks/{task_id}/reassign", params={"actor_id": 1, "new_owner_id": 99999})
    assert response.status_code == 404


def test_unknown_task_404() -> None:
    client = TestClient(app)
    # Control: prove the route exists on a real task, so the 404 below is "unknown task", not "no route".
    created = client.post("/tasks", json={"title": "Real task", "owner_id": 2})
    real_id = created.json()["id"]
    assert client.patch(f"/tasks/{real_id}/reassign", params={"actor_id": 1, "new_owner_id": 3}).status_code == 200
    response = client.patch("/tasks/999999/reassign", params={"actor_id": 1, "new_owner_id": 3})
    assert response.status_code == 404


def test_reassign_writes_audit_event() -> None:
    client = TestClient(app)
    created = client.post("/tasks", json={"title": "Audited", "owner_id": 2})
    task_id = created.json()["id"]
    before = _audit_len()
    response = client.patch(f"/tasks/{task_id}/reassign", params={"actor_id": 1, "new_owner_id": 3})
    assert response.status_code == 200
    events = getattr(db, "EVENT_LOG", [])
    assert len(events) > before, "reassignment must append a compliance audit event to db.EVENT_LOG"
    # The event must be meaningful for this reassignment, not an arbitrary append.
    latest = events[-1]
    assert latest["task_id"] == task_id
    assert latest["actor_id"] == 1
    assert "reassign" in str(latest["action"]).lower()
