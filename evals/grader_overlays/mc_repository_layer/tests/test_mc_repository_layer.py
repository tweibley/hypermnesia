"""Held-out acceptance tests for mc_repository_layer.

The repository-layer convention (all task data access via app/repo.py; endpoints must never touch
db.TASKS directly) lives ONLY in seeded memory. A baseline agent will likely implement the update
endpoint by accessing db.TASKS directly in app/main.py and pass the behavior tests but fail the
architecture check. An agent with the convention in memory routes through repo functions instead.
"""
from __future__ import annotations

import importlib.util
import inspect

from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# Behavioral tests (derivable from the prompt alone)
# ---------------------------------------------------------------------------


def test_update_title_returns_updated_task() -> None:
    client = TestClient(app)
    created = client.post("/tasks", json={"title": "Original title", "owner_id": 2})
    assert created.status_code == 201
    task_id = created.json()["id"]

    response = client.patch(f"/tasks/{task_id}/title", params={"actor_id": 1}, json={"title": "New title"})
    assert response.status_code == 200
    assert response.json()["title"] == "New title"
    assert response.json()["id"] == task_id


def test_update_title_unknown_task_404() -> None:
    client = TestClient(app)
    # Control: prove the route exists on a real task so a 404 below is "unknown task", not "no route".
    created = client.post("/tasks", json={"title": "Control task", "owner_id": 2})
    real_id = created.json()["id"]
    assert client.patch(f"/tasks/{real_id}/title", params={"actor_id": 1}, json={"title": "Control OK"}).status_code == 200

    response = client.patch("/tasks/999999/title", params={"actor_id": 1}, json={"title": "Ghost"})
    assert response.status_code == 404


def test_update_title_persisted() -> None:
    """After a title update the GET /tasks list reflects the new title."""
    client = TestClient(app)
    created = client.post("/tasks", json={"title": "Before update", "owner_id": 2})
    task_id = created.json()["id"]

    client.patch(f"/tasks/{task_id}/title", params={"actor_id": 1}, json={"title": "After update"})

    tasks = client.get("/tasks").json()
    titles = [t["title"] for t in tasks if t["id"] == task_id]
    assert titles == ["After update"]


# ---------------------------------------------------------------------------
# Architecture check (memory-only knowledge: requires the repo convention)
# ---------------------------------------------------------------------------


def test_main_routes_through_repo_not_db_tasks() -> None:
    """app/main.py must import app.repo and must NOT reference db.TASKS directly.

    A baseline agent writes to db.TASKS inline; an agent that recalled the convention delegates
    to repo functions. We inspect source so the test exercises the architecture, not just behavior.
    """
    # app/repo.py must actually exist as a module (not just the word "repo" in a comment/var name).
    assert importlib.util.find_spec("app.repo") is not None, (
        "expected a repository layer module at app/repo.py"
    )

    main_source = inspect.getsource(importlib.import_module("app.main"))

    # main.py must IMPORT the repo module (anchored, not a bare substring).
    imports_repo = (
        "from app.repo" in main_source
        or "from app import repo" in main_source
        or "import repo" in main_source
    )
    assert imports_repo, "app/main.py must import the repository layer (app.repo), not access db.TASKS"

    # Must NOT access db.TASKS directly inside app/main.py
    assert "db.TASKS" not in main_source, (
        "app/main.py must not access db.TASKS directly; use repo functions instead"
    )
