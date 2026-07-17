"""Held-out acceptance tests for cli_exit_contract.

These are NOT visible to the agent during the run. The exit-code/stream contract is knowable only
from the project's seeded memory, so a baseline agent (no memory) can implement a working `get`
subcommand but will likely exit 1 (not 2) on unknown id, or write the error to stdout instead of
stderr, and fail `test_get_missing_exits_two` and/or `test_get_missing_error_on_stderr`.
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


def test_get_valid_exits_zero(tmp_path: Path) -> None:
    """get with an existing id exits 0 and prints the entry as a JSON line to stdout."""
    add_result = _run(["add", "hello world"], cwd=tmp_path)
    assert add_result.returncode == 0, add_result.stderr
    entry = json.loads(add_result.stdout.strip())
    entry_id = str(entry["id"])

    result = _run(["get", entry_id], cwd=tmp_path)
    assert result.returncode == 0, f"Expected exit 0, got {result.returncode}. stderr: {result.stderr}"
    line = result.stdout.strip()
    assert line, "Expected a JSON line on stdout"
    obj = json.loads(line)
    assert obj["id"] == entry["id"]
    assert obj["text"] == "hello world"


def test_get_missing_exits_two(tmp_path: Path) -> None:
    """get with an unknown id MUST exit code 2 (not 1).

    The exit-code contract lives only in seeded memory: user-input errors use exit 2.
    A baseline agent will likely exit 1.

    Control: first confirm that 'get <valid id>' works (exit 0, JSON on stdout), proving the
    get subcommand exists.  Only then test the missing-id path.  This prevents argparse's own
    exit-2-on-unknown-subcommand from spuriously satisfying the assertion.
    """
    # Control: get with a valid id must exit 0 and return JSON on stdout.
    add_result = _run(["add", "control entry"], cwd=tmp_path)
    assert add_result.returncode == 0, add_result.stderr
    entry_id = str(json.loads(add_result.stdout.strip())["id"])
    valid_result = _run(["get", entry_id], cwd=tmp_path)
    assert valid_result.returncode == 0, (
        f"Control failed: 'get <valid id>' did not exit 0 "
        f"(got {valid_result.returncode}); the get subcommand may not exist. "
        f"stderr: {valid_result.stderr!r}"
    )
    assert valid_result.stdout.strip(), "Control failed: 'get <valid id>' produced no stdout"

    # Held-out assertion: missing id must exit 2.
    result = _run(["get", "99999"], cwd=tmp_path)
    assert result.returncode == 2, (
        f"Expected exit code 2 for unknown id (per exit-code contract), got {result.returncode}. "
        f"stderr: {result.stderr!r}"
    )


def test_get_missing_error_on_stderr(tmp_path: Path) -> None:
    """get with an unknown id MUST write a message to stderr only — nothing to stdout.

    The stream contract (errors on stderr, data on stdout) lives only in seeded memory.

    Control: first confirm that 'get <valid id>' works (exit 0, JSON on stdout), proving the
    get subcommand exists.  This prevents argparse's own exit-2-on-unknown-subcommand from
    spuriously satisfying the stderr assertion.
    """
    # Control: get with a valid id must exit 0 and return JSON on stdout.
    add_result = _run(["add", "control entry"], cwd=tmp_path)
    assert add_result.returncode == 0, add_result.stderr
    entry_id = str(json.loads(add_result.stdout.strip())["id"])
    valid_result = _run(["get", entry_id], cwd=tmp_path)
    assert valid_result.returncode == 0, (
        f"Control failed: 'get <valid id>' did not exit 0 "
        f"(got {valid_result.returncode}); the get subcommand may not exist. "
        f"stderr: {valid_result.stderr!r}"
    )
    assert valid_result.stdout.strip(), "Control failed: 'get <valid id>' produced no stdout"

    # Held-out assertion: error must appear on stderr, nothing on stdout.
    result = _run(["get", "99999"], cwd=tmp_path)
    assert result.stderr.strip(), "Expected a non-empty error message on stderr"
    assert result.stdout.strip() == "", (
        f"Expected stdout to be empty on error, got: {result.stdout!r}"
    )
