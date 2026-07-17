"""Held-out acceptance tests for cli_count_guardrail.

Self-contained guardrail task — no memory required, no hidden requirement. Measures that a simple
derivable feature can be added without regression. Baseline should pass this.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

_WORKSPACE_ROOT = Path(__file__).resolve().parent.parent


def _run(
    args: list[str],
    *,
    cwd: Path,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PYTHONPATH"] = str(_WORKSPACE_ROOT)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [sys.executable, "-m", "ledger", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        env=env,
    )


def test_count_empty(tmp_path: Path) -> None:
    """count on an empty store exits 0 and prints {\"count\": 0} as a JSON object."""
    result = _run(["count"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for count on empty store, got {result.returncode}. stderr: {result.stderr}"
    )
    line = result.stdout.strip()
    assert line, "Expected a JSON line on stdout"
    obj = json.loads(line)
    assert "count" in obj, f"Expected 'count' key in output, got: {obj}"
    assert obj["count"] == 0, f"Expected count=0 on empty store, got: {obj['count']}"


def test_count_after_adds(tmp_path: Path) -> None:
    """count reflects the number of entries after several adds."""
    _run(["add", "first"], cwd=tmp_path)
    _run(["add", "second"], cwd=tmp_path)
    _run(["add", "third"], cwd=tmp_path)

    result = _run(["count"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for count, got {result.returncode}. stderr: {result.stderr}"
    )
    line = result.stdout.strip()
    obj = json.loads(line)
    assert obj["count"] == 3, f"Expected count=3 after 3 adds, got: {obj['count']}"
