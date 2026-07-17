#!/usr/bin/env python3
"""Re-grade existing trial workspaces in place (no re-running of Claude).

Useful when only the grading step failed (e.g. a broken venv) but the agent's work is valid.
Recomputes solved/completeness/regression/static against each trial's workspace using a working venv.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from evals.graders.deterministic import grade_deterministic, write_grade_log  # noqa: E402
from evals.runner.tasks import load_task_spec  # noqa: E402

SCHEMA = REPO / "evals" / "schemas" / "task.schema.json"


def regrade(result_path: str, venv_bin: str) -> tuple[str, bool, float] | None:
    r = json.load(open(result_path))
    tdir = Path(result_path).parent
    ws = tdir / "workspace"
    if not ws.exists():
        return None
    task = load_task_spec(REPO / "evals" / "tasks" / (r["task_id"] + ".json"), SCHEMA)
    env = dict(os.environ)
    env["PATH"] = venv_bin + os.pathsep + env.get("PATH", "")
    env["PYTHONPATH"] = str(ws)
    det = grade_deterministic(task.graders, task.requirements, ws, env)
    write_grade_log(det, tdir / "grader.log.json")
    r["solved"] = det.outcome_pass
    r["completeness"] = det.completeness
    r["no_regression"] = det.regression_pass
    r["static_clean"] = det.static_pass
    r["scores"].update(
        outcome_pass=det.outcome_pass, regression_pass=det.regression_pass,
        static_pass=det.static_pass, completeness=det.completeness,
    )
    json.dump(r, open(result_path, "w"), indent=2)
    return (r["trial_id"], det.outcome_pass, round(det.completeness, 3))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--glob", required=True, help="Glob for result.json files to re-grade.")
    ap.add_argument("--venv-bin", required=True, help="bin/ dir of a WORKING grader venv.")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    paths = sorted(glob.glob(args.glob))
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        results = [x for x in ex.map(lambda p: regrade(p, args.venv_bin), paths) if x]
    print(f"re-graded {len(results)} trials")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
