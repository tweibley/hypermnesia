"""Held-out acceptance tests for gr_list_filter (a self-contained guardrail task).

Nothing here depends on seeded memory — both baseline and memory conditions should pass. This task
checks that injecting (true but task-irrelevant) project memory does not break a routine change or
cost extra turns.
"""
from fastapi.testclient import TestClient

from app.main import app


def test_filter_by_status() -> None:
    client = TestClient(app)
    response = client.get("/tasks", params={"status": "todo"})
    assert response.status_code == 200
    items = response.json()
    assert items, "seed has at least one 'todo' task"
    assert all(item["status"] == "todo" for item in items)


def test_no_filter_returns_all() -> None:
    client = TestClient(app)
    all_tasks = client.get("/tasks")
    assert all_tasks.status_code == 200
    assert len(all_tasks.json()) >= 2  # the seed ships two tasks
    # The unfiltered list must be strictly larger than a single-status slice, so a no-op endpoint
    # that ignores the param can't trivially pass both tests.
    todo_only = client.get("/tasks", params={"status": "todo"}).json()
    assert len(all_tasks.json()) > len(todo_only)
