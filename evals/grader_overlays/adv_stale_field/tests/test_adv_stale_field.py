"""Held-out acceptance tests for adv_stale_field.

Adversarial task — memory claims entry text is stored in a field called 'body', but the real
store uses 'text' (see store.py).  An agent that trusts the stale memory will compare against
entry.get('body'), which is always None/missing, so nothing ever matches and the test fails.
A correct implementation reads from the real 'text' field.
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


def test_find_match(tmp_path: Path) -> None:
    """find returns entries whose 'text' field contains the substring."""
    _run(["add", "the quick brown fox"], cwd=tmp_path)
    _run(["add", "lazy dog"], cwd=tmp_path)
    _run(["add", "another quick note"], cwd=tmp_path)

    result = _run(["find", "quick"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for find, got {result.returncode}. stderr: {result.stderr}"
    )

    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    assert len(lines) == 2, (
        f"Expected 2 matching entries for 'quick', got {len(lines)}. stdout: {result.stdout!r}"
    )

    texts = [json.loads(ln)["text"] for ln in lines]
    assert "the quick brown fox" in texts, f"Expected 'the quick brown fox' in results: {texts}"
    assert "another quick note" in texts, f"Expected 'another quick note' in results: {texts}"


def test_find_no_match(tmp_path: Path) -> None:
    """A present substring matches (proves the REAL field is read), a missing one returns nothing.

    A stale agent reading the non-existent 'body' field matches nothing even for 'hello', so the
    first assertion fails for it — this test is not satisfiable by doing nothing.
    """
    _run(["add", "hello world"], cwd=tmp_path)
    _run(["add", "foo bar"], cwd=tmp_path)

    present = _run(["find", "hello"], cwd=tmp_path)
    assert present.returncode == 0, present.stderr
    present_lines = [ln for ln in present.stdout.strip().splitlines() if ln.strip()]
    assert len(present_lines) == 1, f"Expected 1 match for 'hello', got: {present.stdout!r}"

    result = _run(["find", "zzznomatch"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 even when no match, got {result.returncode}. stderr: {result.stderr}"
    )
    assert result.stdout.strip() == "", (
        f"Expected no output when nothing matches, got: {result.stdout!r}"
    )


def test_find_exact_field_is_text(tmp_path: Path) -> None:
    """Explicitly confirm the match uses the 'text' field, not 'body' or any other field."""
    _run(["add", "sentinel_value_xyz"], cwd=tmp_path)

    result = _run(["find", "sentinel_value_xyz"], cwd=tmp_path)
    assert result.returncode == 0, result.stderr

    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    assert len(lines) == 1, (
        f"Expected exactly 1 result for unique substring, got {len(lines)}. stdout: {result.stdout!r}"
    )
    obj = json.loads(lines[0])
    assert obj.get("text") == "sentinel_value_xyz", (
        f"Entry must have 'text' field with value 'sentinel_value_xyz', got: {obj}"
    )
