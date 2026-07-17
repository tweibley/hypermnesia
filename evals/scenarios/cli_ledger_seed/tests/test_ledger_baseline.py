"""Baseline tests for the ledger CLI seed.

These run on the unmodified seed and must stay green across all tasks.  They invoke the CLI via
subprocess so they exercise the real entry point path (``python -m ledger``).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# The workspace root is two levels up from this file (tests/ -> workspace root).
# PYTHONPATH must point there so `python -m ledger` finds the ledger package.
_WORKSPACE_ROOT = Path(__file__).resolve().parent.parent


def _run(
    args: list[str],
    *,
    cwd: Path,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    # Ensure the seed package is importable regardless of install state.
    # The ledger package lives at WORKSPACE_ROOT/ledger/, not inside cwd (the data dir).
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


def test_add_exits_zero(tmp_path: Path) -> None:
    result = _run(["add", "hello world"], cwd=tmp_path)
    assert result.returncode == 0, result.stderr


def test_add_prints_json_line(tmp_path: Path) -> None:
    result = _run(["add", "first entry"], cwd=tmp_path)
    assert result.returncode == 0
    line = result.stdout.strip()
    obj = json.loads(line)
    assert obj["text"] == "first entry"
    assert isinstance(obj["id"], int)


def test_list_exits_zero(tmp_path: Path) -> None:
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, result.stderr


def test_list_empty_produces_no_output(tmp_path: Path) -> None:
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0
    assert result.stdout.strip() == ""


def test_add_then_list_roundtrip(tmp_path: Path) -> None:
    _run(["add", "alpha"], cwd=tmp_path)
    _run(["add", "beta"], cwd=tmp_path)
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0
    lines = [ln for ln in result.stdout.strip().splitlines() if ln]
    assert len(lines) == 2
    first = json.loads(lines[0])
    second = json.loads(lines[1])
    assert first["text"] == "alpha"
    assert second["text"] == "beta"
    assert first["id"] < second["id"]


def test_ids_are_unique_across_adds(tmp_path: Path) -> None:
    r1 = _run(["add", "one"], cwd=tmp_path)
    r2 = _run(["add", "two"], cwd=tmp_path)
    r3 = _run(["add", "three"], cwd=tmp_path)
    ids = {json.loads(r.stdout.strip())["id"] for r in (r1, r2, r3)}
    assert len(ids) == 3, "each add must produce a unique id"


def test_data_file_persists_across_invocations(tmp_path: Path) -> None:
    _run(["add", "persistent"], cwd=tmp_path)
    result = _run(["list"], cwd=tmp_path)
    lines = [ln for ln in result.stdout.strip().splitlines() if ln]
    texts = [json.loads(ln)["text"] for ln in lines]
    assert "persistent" in texts
