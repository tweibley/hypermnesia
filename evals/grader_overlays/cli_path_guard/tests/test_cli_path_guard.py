"""Held-out acceptance tests for cli_path_guard.

These are NOT visible to the agent during the run. The path-traversal guard is knowable only from
the project's seeded memory (a prior version let --data ../../etc/passwd escape). A baseline agent
will accept any --data path and pass test_data_inside_cwd_works but let the traversal escape,
failing test_data_outside_cwd_rejected.
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


def test_data_inside_cwd_works(tmp_path: Path) -> None:
    """--data pointing to a path inside CWD must work normally (exit 0)."""
    sub = tmp_path / "sub"
    sub.mkdir()
    result = _run(["--data", "sub/ok.json", "add", "inside cwd"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for --data inside CWD, got {result.returncode}. stderr: {result.stderr}"
    )
    # The data file must have been created inside CWD.
    data_file = tmp_path / "sub" / "ok.json"
    assert data_file.exists(), "Data file should have been created inside CWD"


def test_data_outside_cwd_rejected(tmp_path: Path) -> None:
    """--data with a path that resolves outside CWD must be rejected with exit 2.

    The path-traversal guard lives only in seeded memory.
    A baseline agent will open the path without checking and exit 0.
    """
    # Use a relative traversal that escapes CWD; resolve in the evil dir to force it truly outside.
    evil_path = "../../../tmp/evil_ledger_test.json"

    result = _run(["--data", evil_path, "list"], cwd=tmp_path)
    assert result.returncode == 2, (
        f"Expected exit code 2 for --data outside CWD (path-traversal guard), "
        f"got {result.returncode}. stdout: {result.stdout!r} stderr: {result.stderr!r}"
    )
    # The error must be on stderr, not stdout.
    assert result.stderr.strip(), "Expected an error message on stderr when rejecting a traversal path"
