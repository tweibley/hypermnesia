"""Held-out acceptance tests for reg_cli_invariants.

This is a REGRESSION (guardrail) task — no memory required, empty memory_seed.

Two parts:
  1. New feature: `ping` subcommand prints {"pong": true} as a JSON line.
  2. Existing-behavior regression guards: add 3 entries, list shows all 3, ids are strictly
     increasing and unique across the sequence.

The existing-behavior checks (part 2) PASS on the unmodified seed.  A drop in part 2 after adding
`ping` signals a real regression in the store or CLI routing.

Control check hygiene (part 1): the test_ping_missing_subcommand_control test first confirms that
`ping` exists (by asserting exit 0) before any assertion that would also be satisfied by argparse's
exit-2-on-unknown-subcommand fallback.  This prevents spurious passes.
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


# ---------------------------------------------------------------------------
# Part 1 — new ping subcommand
# ---------------------------------------------------------------------------


def test_ping_exits_zero(tmp_path: Path) -> None:
    """ping exits 0."""
    result = _run(["ping"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for ping, got {result.returncode}. stderr: {result.stderr!r}"
    )


def test_ping_prints_pong_json(tmp_path: Path) -> None:
    """ping prints {\"pong\": true} as a JSON line to stdout.

    Control: first confirm exit 0 (the ping subcommand exists), then check the output content.
    This prevents argparse's own exit-2-on-unknown-subcommand from interfering with any future
    assertion that depends on stdout content.
    """
    # Control: ping must exit 0 (subcommand exists).
    control = _run(["ping"], cwd=tmp_path)
    assert control.returncode == 0, (
        f"Control failed: ping did not exit 0 (got {control.returncode}); "
        f"the ping subcommand may not exist. stderr: {control.stderr!r}"
    )

    # Held-out assertion: output is a valid JSON line with pong=true.
    line = control.stdout.strip()
    assert line, "Expected a JSON line on stdout from ping"
    obj = json.loads(line)
    assert obj.get("pong") is True, (
        f"Expected {{\"pong\": true}} from ping, got: {obj!r}"
    )


def test_ping_nothing_on_stderr(tmp_path: Path) -> None:
    """ping must not write anything to stderr on success."""
    result = _run(["ping"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Control: ping did not exit 0 (got {result.returncode}). stderr: {result.stderr!r}"
    )
    assert result.stderr.strip() == "", (
        f"Expected empty stderr from ping, got: {result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# Part 2 — existing invariants regression guard (PASSES on unmodified seed)
# ---------------------------------------------------------------------------


def test_add_three_list_shows_three(tmp_path: Path) -> None:
    """add 3 entries, list must return exactly 3 entries.

    This asserts existing behavior and PASSES on the seed.  A regression (e.g. an add
    that accidentally overwrites the data file) would make this fail.
    """
    _run(["add", "alpha"], cwd=tmp_path)
    _run(["add", "beta"], cwd=tmp_path)
    _run(["add", "gamma"], cwd=tmp_path)

    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, f"list failed: {result.stderr}"
    lines = [ln for ln in result.stdout.strip().splitlines() if ln]
    assert len(lines) == 3, (
        f"Expected 3 entries after 3 adds, got {len(lines)}: {result.stdout!r}"
    )


def test_ids_strictly_increasing(tmp_path: Path) -> None:
    """After 3 adds, the ids returned by list are strictly increasing.

    list orders by id ascending; add must allocate monotonically increasing ids.
    This PASSES on the seed.
    """
    _run(["add", "first"], cwd=tmp_path)
    _run(["add", "second"], cwd=tmp_path)
    _run(["add", "third"], cwd=tmp_path)

    result = _run(["list"], cwd=tmp_path)
    assert result.returncode == 0, f"list failed: {result.stderr}"
    lines = [ln for ln in result.stdout.strip().splitlines() if ln]
    ids = [json.loads(ln)["id"] for ln in lines]
    assert ids == sorted(ids), f"Expected ids in ascending order, got {ids}"
    # Strictly increasing (no gaps required, but no duplicates allowed).
    assert len(ids) == len(set(ids)), f"Duplicate ids found: {ids}"
    for i in range(len(ids) - 1):
        assert ids[i] < ids[i + 1], (
            f"ids not strictly increasing at position {i}: {ids}"
        )


def test_ids_unique_across_three_adds(tmp_path: Path) -> None:
    """Each of the 3 adds produces a distinct id.

    This PASSES on the seed and would fail if id allocation were broken by the ping change.
    """
    r1 = _run(["add", "one"], cwd=tmp_path)
    r2 = _run(["add", "two"], cwd=tmp_path)
    r3 = _run(["add", "three"], cwd=tmp_path)

    for r in (r1, r2, r3):
        assert r.returncode == 0, f"add failed: {r.stderr}"

    ids = {json.loads(r.stdout.strip())["id"] for r in (r1, r2, r3)}
    assert len(ids) == 3, (
        f"Expected 3 unique ids from 3 adds, got {len(ids)}: {ids}"
    )
