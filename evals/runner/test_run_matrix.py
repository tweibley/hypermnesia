"""Regression tests for the matrix runner's exit-code contract.

An errored (skipped) trial means the dataset is incomplete, so the run must exit nonzero —
otherwise CI and log-skimmers treat partial data as a clean matrix.

Run with: python -m pytest evals/runner/test_run_matrix.py   (or execute directly)
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from evals.runner.run_matrix import finalize  # noqa: E402


def test_finalize_returns_zero_when_no_errors() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        runs_root = Path(tmp)
        matrix_path = runs_root / "matrix_results.json"
        code = finalize(all_results=[{"trial_id": "t"}], errors=[], runs_root=runs_root, matrix_path=matrix_path)
        assert code == 0
        assert not (runs_root / "matrix_errors.json").exists()


def test_finalize_returns_nonzero_and_writes_errors_file_when_trials_errored() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        runs_root = Path(tmp)
        matrix_path = runs_root / "matrix_results.json"
        errors = [{"task": "t1", "condition": "baseline", "replicate": 1, "error": "boom"}]
        code = finalize(all_results=[], errors=errors, runs_root=runs_root, matrix_path=matrix_path)
        assert code == 1
        written = json.loads((runs_root / "matrix_errors.json").read_text(encoding="utf-8"))
        assert written == errors


if __name__ == "__main__":
    test_finalize_returns_zero_when_no_errors()
    test_finalize_returns_nonzero_and_writes_errors_file_when_trials_errored()
    print("ok")
