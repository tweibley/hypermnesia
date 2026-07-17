"""Held-out acceptance tests for cli_id_gotcha.

These are NOT visible to the agent during the run. The persisted monotonic id counter requirement
lives only in seeded memory. The seed uses a naive max(ids)+1 scheme that reuses ids after delete.

A baseline agent can implement a working `rm` subcommand but will use the naive scheme, causing
test_no_id_reuse_after_delete to fail (C's id collides with A's or B's id).
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


def _add(text: str, cwd: Path) -> int:
    result = _run(["add", text], cwd=cwd)
    assert result.returncode == 0, f"add failed: {result.stderr}"
    return json.loads(result.stdout.strip())["id"]


def test_rm_valid_exits_zero(tmp_path: Path) -> None:
    """rm with a valid id exits 0."""
    entry_id = _add("to be removed", tmp_path)
    result = _run(["rm", str(entry_id)], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for rm with valid id, got {result.returncode}. stderr: {result.stderr}"
    )


def test_rm_missing_exits_two(tmp_path: Path) -> None:
    """rm with an unknown id exits 2 with a message on stderr.

    Control: first add an entry, verify it appears in list, rm it successfully, verify it's gone.
    This proves the rm subcommand exists before testing the missing-id path, so a missing rm
    subcommand can't spuriously satisfy the assertion via argparse's exit-2-on-unknown-subcommand.
    """
    # Control: add an entry.
    entry_id = _add("control entry", tmp_path)

    # Control: verify it lists.
    list_result = _run(["list"], cwd=tmp_path)
    assert list_result.returncode == 0, f"list failed: {list_result.stderr}"
    listed_ids = [json.loads(ln)["id"] for ln in list_result.stdout.strip().splitlines() if ln]
    assert entry_id in listed_ids, f"Control: added entry {entry_id} not found in list output"

    # Control: rm the entry (valid).
    rm_valid = _run(["rm", str(entry_id)], cwd=tmp_path)
    assert rm_valid.returncode == 0, (
        f"Control failed: 'rm <valid id>' did not exit 0 "
        f"(got {rm_valid.returncode}); the rm subcommand may not exist. "
        f"stderr: {rm_valid.stderr!r}"
    )

    # Control: verify it's gone.
    list_after = _run(["list"], cwd=tmp_path)
    assert list_after.returncode == 0, f"list after rm failed: {list_after.stderr}"
    remaining_ids = [json.loads(ln)["id"] for ln in list_after.stdout.strip().splitlines() if ln]
    assert entry_id not in remaining_ids, f"Control: entry {entry_id} still present after rm"

    # Held-out assertion: rm with an unknown id must exit 2 with a message on stderr.
    result = _run(["rm", "99999"], cwd=tmp_path)
    assert result.returncode == 2, (
        f"Expected exit 2 for rm unknown id, got {result.returncode}. stderr: {result.stderr!r}"
    )
    assert result.stderr.strip(), "Expected an error message on stderr"


def test_no_id_reuse_after_delete(tmp_path: Path) -> None:
    """add A, add B, rm B (the highest id), add C -> C's id must differ from B's id.

    This test FAILS under the naive max(ids)+1 scheme (which is what the seed ships):
    - A gets id 1, B gets id 2.
    - After rm B, max(ids) = 1, so C also gets id 2 — reuse of B's id!

    It PASSES only when add uses the persisted meta.next_id counter, as the memory specifies:
    - A=1, B=2, counter becomes 3.
    - After rm B, counter is still 3, so C gets id 3 — no reuse.
    """
    id_a = _add("entry A", tmp_path)
    id_b = _add("entry B", tmp_path)

    # Remove B — the entry with the highest id. Under the naive scheme, the next add will
    # recalculate max(ids)+1 = id_a+1 = id_b, reusing B's id.
    rm_result = _run(["rm", str(id_b)], cwd=tmp_path)
    assert rm_result.returncode == 0, f"rm B failed: {rm_result.stderr}"

    id_c = _add("entry C", tmp_path)

    assert id_c != id_b, (
        f"C's id ({id_c}) must not reuse B's deleted id ({id_b}). "
        "This means add is using naive max(ids)+1 instead of the persisted meta.next_id counter. "
        f"(A={id_a}, B={id_b}, C={id_c})"
    )
    assert id_c != id_a, (
        f"C's id ({id_c}) must not collide with A's id ({id_a}) either."
    )
