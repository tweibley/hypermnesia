"""Held-out acceptance tests for adv_nearmiss_auth.

Seeded memory claims every endpoint (reads and writes) requires an actor_id query parameter and
must return 403 when it is absent. The real code only applies actor_id + role checks to mutating
endpoints; plain read endpoints are public. An agent that trusts the stale memory will add a
spurious actor_id requirement or 403 guard to GET /stats, causing test_stats_no_actor_id to
fail. An agent that reads the code and sees the pattern for existing read endpoints passes.
"""
from fastapi.testclient import TestClient

from app.main import app


def test_stats_no_actor_id() -> None:
    """GET /stats with NO actor_id must return 200, not 403."""
    client = TestClient(app)
    response = client.get("/stats")
    assert response.status_code == 200, (
        f"GET /stats with no actor_id must be public (200), got {response.status_code}: {response.text}"
    )


def test_stats_correct_counts() -> None:
    """Returned counts match the seed data: 2 tasks, 3 users."""
    client = TestClient(app)
    response = client.get("/stats")
    assert response.status_code == 200
    body = response.json()
    assert "task_count" in body, f"missing 'task_count' key, got: {list(body.keys())}"
    assert "user_count" in body, f"missing 'user_count' key, got: {list(body.keys())}"
    assert body["task_count"] == 2, f"seed has 2 tasks, got task_count={body['task_count']}"
    assert body["user_count"] == 3, f"seed has 3 users, got user_count={body['user_count']}"
