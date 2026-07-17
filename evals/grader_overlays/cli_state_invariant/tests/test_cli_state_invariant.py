"""Held-out acceptance tests for cli_state_invariant.

These are NOT visible to the agent during the run.  The recovery rule lives ONLY in seeded memory:

    "If the json data file is missing or unparseable (corrupt / partial), commands must treat the
    store as EMPTY and exit 0, never crash."

A code-reading baseline agent has no reason to add this defensive path because the seed's store.py
raises json.JSONDecodeError on garbage input, propagating an unhandled exception and a non-zero
exit code.  Only a memory-informed agent will add the try/except guard.

Control check hygiene: each test that asserts a non-zero exit (none here — all should be 0)
FIRST proves the subcommand works on a clean store.  For the corrupt-file path all assertions
are exit-0, so no spurious-pass risk from argparse's exit-2-on-unknown-subcommand.
"""

from __future__ import annotations

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


def _write_data_file(cwd: Path, content: str) -> None:
    """Write arbitrary bytes into the default data file (ledger.json)."""
    (cwd / "ledger.json").write_text(content, encoding="utf-8")


# ---------------------------------------------------------------------------
# Corrupt / garbage data file
# ---------------------------------------------------------------------------


def test_list_on_garbage_file_exits_zero(tmp_path: Path) -> None:
    """list on a garbage (non-JSON) data file must exit 0.

    The seed crashes here: json.JSONDecodeError propagates unhandled -> non-zero exit.
    The memory-seeded recovery rule requires a try/except that falls back to an empty store.
    """
    _write_data_file(tmp_path, "this is not json at all!!!\x00\xff")
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 when data file is garbage, got {result.returncode}. "
        f"stderr: {result.stderr!r}"
    )


def test_list_on_garbage_file_produces_empty_output(tmp_path: Path) -> None:
    """list on a garbage data file must produce no output (treat store as empty).

    This pairs with the exit-0 assertion: both must hold for the recovery rule to be correct.
    """
    _write_data_file(tmp_path, "{corrupt: yes, missing_quote: }")
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 when data file is corrupt JSON, got {result.returncode}. "
        f"stderr: {result.stderr!r}"
    )
    assert result.stdout.strip() == "", (
        f"Expected empty stdout when data file is corrupt, got: {result.stdout!r}"
    )


def test_list_on_partial_json_exits_zero(tmp_path: Path) -> None:
    """list on a truncated/partial JSON file must exit 0 (treat as empty store).

    A partial write (e.g. interrupted flush) leaves a partial JSON object that is
    valid ASCII but not complete JSON.  The recovery rule must cover this case too.
    """
    _write_data_file(tmp_path, '{"version": 1, "entries": [{"id": 1, "text": "oops"')
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for partial JSON data file, got {result.returncode}. "
        f"stderr: {result.stderr!r}"
    )
    assert result.stdout.strip() == "", (
        f"Expected empty stdout for partial JSON, got: {result.stdout!r}"
    )


def test_list_on_empty_file_exits_zero(tmp_path: Path) -> None:
    """list on a zero-byte data file must exit 0 (treat as empty store).

    An empty file is not valid JSON either; the recovery rule applies.
    """
    _write_data_file(tmp_path, "")
    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for empty data file, got {result.returncode}. "
        f"stderr: {result.stderr!r}"
    )
    assert result.stdout.strip() == "", (
        f"Expected empty stdout for empty data file, got: {result.stdout!r}"
    )


# ---------------------------------------------------------------------------
# Sanity: a clean store still works (guards against trivially always-empty impl)
# ---------------------------------------------------------------------------


def test_add_then_list_still_works_after_fix(tmp_path: Path) -> None:
    """After writing a valid entry, list must return it — the fix must not break the happy path.

    Control assertion: proves the subcommand is functional, not just empty-returning.
    """
    import json

    add_result = _run(["add", "sanity check"], cwd=tmp_path)
    assert add_result.returncode == 0, f"add failed: {add_result.stderr}"
    entry = json.loads(add_result.stdout.strip())
    assert entry["text"] == "sanity check"

    list_result = _run(["list"], cwd=tmp_path)
    assert list_result.returncode == 0, f"list failed: {list_result.stderr}"
    lines = [ln for ln in list_result.stdout.strip().splitlines() if ln]
    assert len(lines) == 1, f"Expected 1 entry, got {len(lines)}: {list_result.stdout!r}"
    listed = json.loads(lines[0])
    assert listed["text"] == "sanity check"
