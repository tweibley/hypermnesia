"""Held-out acceptance tests for adv_conflicting_status.

Seeded memory claims task status values are open, in_review, closed. The real TaskStatus enum
is todo, in_progress, done. An agent that trusts the stale memory will implement the filter
using the wrong enum values — validation will reject the real values or the filter will never
match — causing these tests to fail. An agent that reads the code uses the real values and passes.
"""
import copy

import pytest
from fastapi.testclient import TestClient

from app import db as _db
from app.main import app

_ORIG_TASKS = copy.deepcopy(_db.TASKS)


@pytest.fixture(autouse=True)
def _reset_tasks():
    # Some tests mutate task status; start each from the seed state so they're independent.
    _db.TASKS.clear()
    _db.TASKS.update(copy.deepcopy(_ORIG_TASKS))
    yield


def test_filter_by_done() -> None:
    client = TestClient(app)
    # First create a task and advance it to done so we have at least one.
    # The seed has task 1 as in_progress and task 2 as todo; patch task 1 to done.
    client.patch("/tasks/1", params={"actor_id": 2}, json={"status": "done"})

    response = client.get("/tasks", params={"status": "done"})
    assert response.status_code == 200
    items = response.json()
    assert items, "expected at least one done task after patching"
    assert all(item["status"] == "done" for item in items), (
        f"all items must have status 'done', got: {[i['status'] for i in items]}"
    )


def test_filter_by_todo() -> None:
    client = TestClient(app)
    response = client.get("/tasks", params={"status": "todo"})
    assert response.status_code == 200
    items = response.json()
    # Seed has task 2 as todo
    assert items, "seed has at least one 'todo' task"
    assert all(item["status"] == "todo" for item in items), (
        f"all items must have status 'todo', got: {[i['status'] for i in items]}"
    )


def test_no_filter_returns_all() -> None:
    client = TestClient(app)
    all_tasks = client.get("/tasks").json()
    assert len(all_tasks) >= 2, "seed ships at least two tasks"
    # The status filter must actually NARROW results (real statuses). On the unfiltered seed this
    # fails (no filter -> returns everything); a stale-memory agent using open/closed 422s on 'todo'.
    todo = client.get("/tasks", params={"status": "todo"})
    assert todo.status_code == 200
    todo_items = todo.json()
    assert all(item["status"] == "todo" for item in todo_items)
    assert len(todo_items) < len(all_tasks)
