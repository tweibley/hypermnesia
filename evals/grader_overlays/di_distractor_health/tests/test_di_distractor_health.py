"""Held-out acceptance test for di_distractor_health.

The seeded memory is full of true-but-irrelevant project conventions (error envelopes, audit logs,
pagination, list envelopes, status lifecycles) — none apply to a plain health endpoint. This checks
that injecting that noise does not mislead the agent (e.g. wrapping the response in a list envelope
or adding auth) or cost extra turns. Both baseline and memory conditions should pass.
"""
from fastapi.testclient import TestClient

from app.main import app


def test_health_detail_shape() -> None:
    client = TestClient(app)
    response = client.get("/health/detail")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["tasks"] == 2   # the seed ships exactly two tasks
    assert body["users"] == 3   # admin, member, viewer
