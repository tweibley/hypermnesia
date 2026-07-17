"""Held-out acceptance tests for mc_error_envelope.

These are NOT visible to the agent during the run. The error-envelope shape is knowable only from
the project's seeded memory, so a baseline agent (no memory) can implement a working DELETE endpoint
but will use FastAPI's default {"detail": ...} error shape and fail `test_error_uses_envelope`.
"""
from fastapi.testclient import TestClient

from app.main import app


def _new_task(client: TestClient, owner_id: int = 2) -> int:
    created = client.post("/tasks", json={"title": "Delete me", "owner_id": owner_id})
    assert created.status_code == 201
    return created.json()["id"]


def test_admin_can_delete() -> None:
    client = TestClient(app)
    task_id = _new_task(client)
    response = client.delete(f"/tasks/{task_id}", params={"actor_id": 1})
    assert response.status_code == 200
    assert response.json()["id"] == task_id


def test_non_admin_rejected() -> None:
    client = TestClient(app)
    task_id = _new_task(client)
    response = client.delete(f"/tasks/{task_id}", params={"actor_id": 2})
    assert response.status_code == 403


def test_missing_task_not_found() -> None:
    client = TestClient(app)
    response = client.delete("/tasks/999999", params={"actor_id": 1})
    assert response.status_code == 404


def test_error_uses_envelope() -> None:
    client = TestClient(app)
    response = client.delete("/tasks/999999", params={"actor_id": 1})
    assert response.status_code == 404
    body = response.json()
    assert "detail" not in body, "must not use FastAPI's default {'detail': ...} error shape"
    assert isinstance(body.get("error"), dict), "error body must be the {'error': {...}} envelope"
    assert isinstance(body["error"].get("code"), str)
    assert isinstance(body["error"].get("message"), str)
