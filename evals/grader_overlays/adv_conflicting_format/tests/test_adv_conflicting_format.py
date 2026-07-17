"""Held-out acceptance tests for adv_conflicting_format.

Adversarial task — memory claims ledger stores data as YAML in ledger.yaml, but the real store
uses JSON in ledger.json.  An agent that trusts the seeded memory and reads ledger.yaml will find
no file and print nothing even after adding entries.  A correct implementation reads from the real
store (ledger.json via store.py) and prints all entries as JSON Lines.
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


def test_dump_empty(tmp_path: Path) -> None:
    """Round-trip: dump after a single add prints exactly that entry (read from the REAL json store).

    (Named 'empty' historically; it is now a discriminating round-trip so a stale agent that reads
    the non-existent ledger.yaml — and would print nothing — cannot pass it.)
    """
    _run(["add", "solo entry"], cwd=tmp_path)
    result = _run(["dump"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for dump, got {result.returncode}. stderr: {result.stderr}"
    )
    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    assert len(lines) == 1, f"Expected exactly 1 entry from dump, got: {result.stdout!r}"
    assert json.loads(lines[0]).get("text") == "solo entry"


def test_dump_entries(tmp_path: Path) -> None:
    """dump after two adds prints both entries as JSON objects, one per line."""
    _run(["add", "alpha entry"], cwd=tmp_path)
    _run(["add", "beta entry"], cwd=tmp_path)

    result = _run(["dump"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for dump, got {result.returncode}. stderr: {result.stderr}"
    )

    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    assert len(lines) == 2, (
        f"Expected 2 JSON lines from dump, got {len(lines)}. stdout: {result.stdout!r}"
    )

    texts = []
    for line in lines:
        obj = json.loads(line)
        assert "text" in obj, f"Each entry must have a 'text' field, got: {obj}"
        texts.append(obj["text"])

    assert "alpha entry" in texts, f"Expected 'alpha entry' in dump output, got: {texts}"
    assert "beta entry" in texts, f"Expected 'beta entry' in dump output, got: {texts}"
