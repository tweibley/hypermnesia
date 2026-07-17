"""Held-out acceptance tests for ef_reuse_pagination.

This is an EFFICIENCY task: both baseline and memory conditions should pass the behavioral tests. The
seeded memory points at the existing app/pagination.py helper, so the memory-equipped agent should
reach a correct solution in fewer turns / a smaller diff. `test_reuses_shared_helper` is a secondary
completeness signal (did it actually reuse the helper?), not part of the pass/fail outcome.
"""
import importlib
import inspect

from fastapi.testclient import TestClient

from app.main import app


def test_limit_bounds_results() -> None:
    client = TestClient(app)
    # Seed ships 2 tasks; create a few more so limit is observable.
    for _ in range(3):
        client.post("/tasks", json={"title": "Extra task", "owner_id": 2})
    response = client.get("/tasks", params={"limit": 2, "offset": 0})
    assert response.status_code == 200
    assert len(response.json()) == 2


def test_offset_skips() -> None:
    client = TestClient(app)
    full = client.get("/tasks").json()
    big = len(full) + 10  # a limit large enough to never bind, derived from actual count
    skipped = client.get("/tasks", params={"limit": big, "offset": 1}).json()
    assert [t["id"] for t in skipped] == [t["id"] for t in full[1:]]


def test_defaults_return_all() -> None:
    client = TestClient(app)
    full = client.get("/tasks").json()
    assert len(full) >= 2  # at least the two seed tasks
    # The default must equal an explicit default window, so a no-op endpoint that ignores params fails.
    explicit = client.get("/tasks", params={"limit": 50, "offset": 0}).json()
    assert [t["id"] for t in full] == [t["id"] for t in explicit]


def test_reuses_shared_helper() -> None:
    # Secondary signal: did the agent reuse app/pagination.py rather than re-implement slicing?
    # Import the module via importlib so the local `app` (the FastAPI instance) doesn't shadow it.
    source = inspect.getsource(importlib.import_module("app.main"))
    assert "paginate" in source, "expected GET /tasks to reuse app.pagination.paginate"
