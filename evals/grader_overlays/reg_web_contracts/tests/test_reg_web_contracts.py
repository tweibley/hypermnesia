"""Held-out tests for reg_web_contracts.

This is a REGRESSION task. The outcome tests (/ping) will FAIL on the unmodified seed (the route
does not exist yet). The existing-contract assertions (health, users, viewer-403) PASS on the seed
and are included to catch any regression introduced while adding /ping.
"""
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# Outcome: new /ping endpoint (fails on seed — route absent)
# ---------------------------------------------------------------------------


def test_ping_returns_pong() -> None:
    client = TestClient(app)
    response = client.get("/ping")
    assert response.status_code == 200
    assert response.json() == {"pong": True}


# ---------------------------------------------------------------------------
# Regression: existing contracts must still hold after the agent's change
# ---------------------------------------------------------------------------


def test_health_contract() -> None:
    """GET /health must still return exactly {"status": "ok"}."""
    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_users_contract() -> None:
    """GET /users must still return exactly 3 users."""
    client = TestClient(app)
    response = client.get("/users")
    assert response.status_code == 200
    users = response.json()
    assert len(users) == 3, f"expected 3 users, got {len(users)}"


def test_viewer_patch_still_403() -> None:
    """PATCH /tasks/{id} by a viewer (actor_id=3) must still return 403.

    Control sub-assertion: first prove the route exists on a valid task with a permitted actor,
    so a 403 below is "authorization denied", not "no route" or "unknown task".
    """
    client = TestClient(app)
    # Control: admin (actor_id=1) can patch task 1 successfully.
    control = client.patch("/tasks/1", params={"actor_id": 1}, json={"status": "in_progress"})
    assert control.status_code == 200, (
        f"control assertion failed: expected 200 for admin patch, got {control.status_code}"
    )
    # Actual assertion: viewer is still rejected.
    response = client.patch("/tasks/1", params={"actor_id": 3}, json={"status": "done"})
    assert response.status_code == 403
