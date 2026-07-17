from fastapi.testclient import TestClient

from app.main import app


def test_member_can_edit_owned_task() -> None:
    client = TestClient(app)
    response = client.patch("/tasks/1", params={"actor_id": 2}, json={"status": "done"})
    assert response.status_code == 200
    payload = response.json()
    assert payload["id"] == 1
    assert payload["status"] == "done"


def test_viewer_cannot_edit() -> None:
    client = TestClient(app)
    response = client.patch("/tasks/1", params={"actor_id": 3}, json={"status": "done"})
    assert response.status_code == 403
