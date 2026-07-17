"""Held-out acceptance tests for adv_nearmiss_web.

Adversarial task — memory claims CLI output must be wrapped in an {\"items\": [...], \"count\": N}
envelope (a web-API convention that has no place in this CLI).  An agent that trusts this stale
memory will produce output like {\"items\": [{\"version\": \"0.1.0\"}], \"count\": 1} instead of the
correct bare {\"version\": \"0.1.0\"}, causing the held-out test to fail.
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


def test_version_shape(tmp_path: Path) -> None:
    """version prints a single JSON object with exactly one key 'version' mapping to a string."""
    result = _run(["version"], cwd=tmp_path)
    assert result.returncode == 0, (
        f"Expected exit 0 for version, got {result.returncode}. stderr: {result.stderr}"
    )

    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    assert len(lines) == 1, (
        f"Expected exactly one line of output, got {len(lines)}. stdout: {result.stdout!r}"
    )

    obj = json.loads(lines[0])

    # Must be a bare object with a 'version' key — NOT wrapped in items/count envelope.
    assert "version" in obj, (
        f"Expected a 'version' key in output, got keys: {list(obj.keys())}"
    )
    assert isinstance(obj["version"], str), (
        f"Expected 'version' to be a string, got: {type(obj['version'])}"
    )
    assert obj["version"], "Expected a non-empty version string"

    # Explicitly reject the envelope pattern that the stale memory would produce.
    assert "items" not in obj, (
        f"Output must NOT be wrapped in an 'items' envelope; got: {obj}"
    )
    assert "count" not in obj, (
        f"Output must NOT contain a 'count' key; got: {obj}"
    )

    # The output must have exactly one key.
    assert list(obj.keys()) == ["version"], (
        f"Output must have exactly the key 'version', got: {list(obj.keys())}"
    )


def test_version_is_string(tmp_path: Path) -> None:
    """version string looks like a semver (contains at least one dot)."""
    result = _run(["version"], cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    obj = json.loads(result.stdout.strip())
    ver = obj["version"]
    assert "." in ver, f"Version string '{ver}' does not look like a version (no dot)"
