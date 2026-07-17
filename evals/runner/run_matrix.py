#!/usr/bin/env python3
"""Run the Hypermnesia eval matrix with the Claude Code CLI.

For each (task, condition, replicate) it builds a fresh, isolated workspace + memory store, sets up
the condition (seed memory / install hooks / wire MCP / paste oracle context), runs Claude headless,
then grades the result with held-out tests and records authoritative metrics.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from evals.conditions.adapters import (  # noqa: E402
    ConditionContext,
    assert_condition_clean,
    dry_hydrate,
    setup_condition,
    teardown_condition,
)
from evals.graders.deterministic import grade_deterministic, write_grade_log  # noqa: E402
from evals.graders.rubric import maybe_grade_with_rubric  # noqa: E402
from evals.runner.metrics import git_diff_stats, parse_stream_metrics  # noqa: E402
from evals.runner.models import CONDITIONS, TaskSpec, TrialArtifacts  # noqa: E402
from evals.runner.tasks import load_task_spec  # noqa: E402
from evals.runner.workspace import (  # noqa: E402
    PROJECT_ID,
    apply_overlay,
    copy_tree,
    ensure_shared_venv,
    init_git_repo,
)

TASK_SCHEMA = REPO_ROOT / "evals" / "schemas" / "task.schema.json"

# Installed once into the shared grader venv; tasks must NOT reinstall per-command.
GRADER_REQUIREMENTS = [
    "fastapi>=0.116.0",
    "pydantic>=2.10.0",
    "httpx>=0.27.0",      # required by fastapi's TestClient
    "pytest>=8.3.0",
    "ruff>=0.6.9",
    "mypy>=1.11.2",
]


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Hypermnesia eval matrix with Claude Code CLI.")
    parser.add_argument("--task", action="append", default=[], help="Path to task spec JSON (repeatable).")
    parser.add_argument("--tasks-dir", default="evals/tasks", help="Load all *.json tasks if --task is omitted.")
    parser.add_argument("--condition", action="append", default=[], choices=CONDITIONS)
    parser.add_argument("--replicate", action="append", type=int, default=[], help="Replicate ids (repeatable).")
    parser.add_argument("--replicates", type=int, default=0, help="Shorthand: run replicates 1..N.")
    parser.add_argument("--runs-root", default="evals/runs")
    parser.add_argument("--hypermnesia-bin", default=os.environ.get("HYPERMNESIA_BIN", "hypermnesia"))
    parser.add_argument("--claude-bin", default=os.environ.get("CLAUDE_BIN", "claude"))
    parser.add_argument("--model", default=os.environ.get("CLAUDE_MODEL", "sonnet"),
                        help="Subject (agent-under-test) model. Default: sonnet.")
    parser.add_argument("--effort", default=os.environ.get("CLAUDE_EFFORT", "medium"),
                        choices=["low", "medium", "high", "xhigh", "max"],
                        help="Subject reasoning effort. Default: medium.")
    parser.add_argument("--judge-model", default="claude-opus-4-8",
                        help="LLM-judge model for the rubric grader. Default: Opus 4.8.")
    parser.add_argument("--enable-rubric", action="store_true",
                        help="Run the Opus-4.8 LLM judge on each diff (costs extra calls).")
    parser.add_argument(
        "--skip-claude",
        action="store_true",
        help="Skip Claude execution; only run setup + graders (harness smoke test).",
    )
    return parser.parse_args()


def resolve_tasks(args: argparse.Namespace) -> list[Path]:
    if args.task:
        return [Path(p).resolve() for p in args.task]
    tasks_dir = (REPO_ROOT / args.tasks_dir).resolve()
    return sorted(tasks_dir.glob("*.json"))


def prepare_workspace(task: TaskSpec, trial_dir: Path) -> Path:
    # The workspace lives OUTSIDE the repo (a temp dir), so an agent running under
    # --permission-mode bypassPermissions cannot reach held-out assets (evals/grader_overlays,
    # evals/tasks) by a relative path. Held-out tests are still applied here only AFTER the run.
    workspace = Path(tempfile.mkdtemp(prefix=f"hteval_{task.id}_{trial_dir.name}_")) / "workspace"
    scenario = (REPO_ROOT / task.seed_scenario).resolve()
    copy_tree(scenario, workspace)
    for overlay in task.overlays:          # agent-visible context only
        apply_overlay((REPO_ROOT / overlay).resolve(), workspace)
    init_git_repo(workspace)
    return workspace


def apply_grader_overlays(task: TaskSpec, workspace: Path) -> None:
    for overlay in task.grader_overlays:   # held-out acceptance tests, dropped in AFTER the run
        apply_overlay((REPO_ROOT / overlay).resolve(), workspace)


def run_claude(
    *,
    claude_bin: str,
    model: str | None,
    effort: str | None,
    task: TaskSpec,
    condition: str,
    prompt: str,
    workspace: Path,
    stream_json_path: Path,
    stdout_path: Path,
    mcp_config_path: Path,
    env: dict[str, str],
) -> int:
    command = [
        claude_bin,
        "--print",
        "--output-format", "stream-json",
        "--verbose",
        "--setting-sources", "project,local",
        "--permission-mode", "bypassPermissions",
        "--max-budget-usd", str(task.max_budget_usd),
    ]
    if model:
        command.extend(["--model", model])
    if effort:
        command.extend(["--effort", effort])
    if condition in {"mcp_only", "mcp_nudged"}:
        command.extend(["--mcp-config", str(mcp_config_path), "--strict-mcp-config"])
    command.append(prompt)

    with stream_json_path.open("w", encoding="utf-8") as stream_fh:
        proc = subprocess.Popen(
            command, cwd=workspace, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env
        )
        assert proc.stdout is not None
        lines: list[str] = []
        # A blocking readline() can't be interrupted by a top-of-loop time check, so a subject that
        # stalls with no output (a hung tool call, a network stall) would hang the whole matrix. A
        # watchdog kills the process at the deadline; that closes stdout, so the read loop unblocks
        # at EOF and the wall-clock timeout is actually enforced.
        timed_out = threading.Event()

        def _on_timeout() -> None:
            timed_out.set()
            proc.kill()

        watchdog = threading.Timer(task.timeout_seconds, _on_timeout)
        watchdog.start()
        try:
            for chunk in iter(proc.stdout.readline, ""):
                lines.append(chunk)
                stream_fh.write(chunk)
        finally:
            watchdog.cancel()
        if timed_out.is_set():
            lines.append(json.dumps({"type": "error", "error": "trial timeout"}) + "\n")
        stdout_path.write_text("".join(lines), encoding="utf-8")
        return proc.wait()


def earn_memories(*, ctx, task: TaskSpec, args, trial_dir: Path, env: dict[str, str]) -> tuple[int, float, int]:
    """earned_hooks: run each warmup prompt as its own coding session, then replay its transcript
    into the isolated store via `backfill` (the real capture→classify loop).

    Returns (warmups_run, warmup_cost_usd, warmup_turns) so the measured trial can report the TRUE
    cost of earning the memory — not just the final task. (Gemini backfill cost is not captured here;
    only the warmup coding sessions are, so this is a lower bound on the earned overhead.)
    """
    warmup_cost = 0.0
    warmup_turns = 0
    for i, warmup_prompt in enumerate(task.warmup):
        warm_dir = trial_dir / f"warmup_{i}"
        warm_ws = warm_dir / "ws"
        scenario = (REPO_ROOT / task.seed_scenario).resolve()
        copy_tree(scenario, warm_ws)
        for overlay in task.overlays:
            apply_overlay((REPO_ROOT / overlay).resolve(), warm_ws)
        init_git_repo(warm_ws)
        # No hooks during warmup — we backfill the transcript explicitly and deterministically.
        warm_stream = warm_dir / "warmup.stream.jsonl"
        run_claude(
            claude_bin=args.claude_bin,
            model=args.model,
            effort=args.effort,
            task=task,
            condition="baseline",
            prompt=warmup_prompt,
            workspace=warm_ws,
            stream_json_path=warm_stream,
            stdout_path=warm_dir / "warmup.stdout.log",
            mcp_config_path=warm_dir / "unused_mcp.json",
            env=env,
        )
        wm = parse_stream_metrics(warm_stream)
        warmup_cost += wm.get("total_cost_usd") or 0.0
        warmup_turns += wm.get("num_turns") or 0
        subprocess.run(
            [args.hypermnesia_bin, "backfill", "--project", str(warm_ws), "--confirm"],
            env=env, capture_output=True, text=True,
        )
    return len(task.warmup), round(warmup_cost, 6), warmup_turns


def build_artifacts(trial_dir: Path) -> TrialArtifacts:
    return TrialArtifacts(
        workspace=trial_dir / "workspace",
        stdout_path=trial_dir / "claude.stdout.log",
        stream_json_path=trial_dir / "claude.stream.jsonl",
        diff_path=trial_dir / "git.diff.patch",
        grader_log_path=trial_dir / "grader.log.json",
        injected_context_path=trial_dir / "injected_context.md",
    )


def run_trial(
    *,
    task: TaskSpec,
    condition: str,
    replicate: int,
    runs_root: Path,
    grader_bin: Path,
    args: argparse.Namespace,
) -> dict:
    trial_id = f"{task.id}__{condition}__rep{replicate}"
    trial_dir = runs_root / trial_id
    if trial_dir.exists():
        shutil.rmtree(trial_dir)
    trial_dir.mkdir(parents=True, exist_ok=True)
    artifacts = build_artifacts(trial_dir)

    started_at = _timestamp()
    start_time = time.time()
    workspace = prepare_workspace(task, trial_dir)
    artifacts.workspace = workspace   # record the real (out-of-repo) workspace path

    mcp_config_path = trial_dir / "mcp_config.json"
    ctx = ConditionContext(
        condition=condition,
        workspace=workspace,
        trial_dir=trial_dir,
        project_id=PROJECT_ID,
        hypermnesia_bin=args.hypermnesia_bin,
        mcp_config_path=mcp_config_path,
        memory_seed=task.memory_seed,
    )
    setup = setup_condition(ctx, task.prompt)
    assert_condition_clean(ctx, setup)

    # earned_hooks earns its memory via warmup sessions + backfill, then we measure what hydrate injects.
    warmup_cost_usd, warmup_turns = 0.0, 0
    if condition == "earned_hooks" and not args.skip_claude:
        setup.seeded_count, warmup_cost_usd, warmup_turns = earn_memories(
            ctx=ctx, task=task, args=args, trial_dir=trial_dir, env=setup.env
        )
        setup.injected_context = dry_hydrate(ctx, setup.env)
        if not setup.injected_context:
            setup.notes.append("WARNING: warmup+backfill produced no injectable memory")

    artifacts.injected_context_path.write_text(setup.injected_context, encoding="utf-8")

    if args.skip_claude:
        artifacts.stream_json_path.write_text(
            json.dumps({"type": "result", "subtype": "success", "num_turns": 0, "is_error": False}) + "\n",
            encoding="utf-8",
        )
        artifacts.stdout_path.write_text("skip-claude enabled\n", encoding="utf-8")
        claude_exit = 0
    else:
        claude_exit = run_claude(
            claude_bin=args.claude_bin,
            model=args.model,
            effort=args.effort,
            task=task,
            condition=condition,
            prompt=setup.effective_prompt,
            workspace=workspace,
            stream_json_path=artifacts.stream_json_path,
            stdout_path=artifacts.stdout_path,
            mcp_config_path=mcp_config_path,
            env=setup.env,
        )

    # Diff the agent's work BEFORE held-out tests land, so it reflects only what the agent changed.
    diff_files, diff_added, diff_deleted, diff_text = git_diff_stats(workspace)
    artifacts.diff_path.write_text(diff_text, encoding="utf-8")

    apply_grader_overlays(task, workspace)

    grader_env = dict(os.environ)
    grader_env["PATH"] = f"{grader_bin}{os.pathsep}{grader_env.get('PATH', '')}"
    grader_env["PYTHONPATH"] = str(workspace)
    deterministic = grade_deterministic(task.graders, task.requirements, workspace, grader_env)
    write_grade_log(deterministic, artifacts.grader_log_path)
    rubric_score = maybe_grade_with_rubric(
        enabled=args.enable_rubric,
        task_prompt=task.prompt,
        diff_path=artifacts.diff_path,
        output_path=trial_dir / "rubric.json",
        judge_model=args.judge_model,
        claude_bin=args.claude_bin,
    )

    metrics = parse_stream_metrics(artifacts.stream_json_path)
    metrics["files_changed"] = diff_files
    metrics["diff_lines_added"] = diff_added
    metrics["diff_lines_deleted"] = diff_deleted
    metrics["claude_exit_code"] = claude_exit
    metrics["injected_context_chars"] = len(setup.injected_context)
    metrics["seeded_memory_count"] = setup.seeded_count
    # True end-to-end cost of earning the memory: warmup coding sessions + the measured run.
    # (For non-earned conditions warmup_cost is 0, so this equals total_cost_usd.)
    metrics["warmup_cost_usd"] = warmup_cost_usd
    metrics["warmup_turns"] = warmup_turns
    measured_cost = metrics["total_cost_usd"] or 0.0
    metrics["total_cost_with_warmup"] = round(measured_cost + warmup_cost_usd, 6)

    # Persist the (out-of-repo) workspace into the trial dir for inspection + regrade, then clean /tmp.
    persisted_ws = trial_dir / "workspace"
    if persisted_ws.exists():
        shutil.rmtree(persisted_ws)
    shutil.copytree(workspace, persisted_ws)
    shutil.rmtree(workspace.parent, ignore_errors=True)
    artifacts.workspace = persisted_ws

    finished_at = _timestamp()
    duration = time.time() - start_time

    result = {
        "trial_id": trial_id,
        "task_id": task.id,
        "family": task.family,
        "suite": task.suite,
        "condition": condition,
        "replicate": replicate,
        "model": args.model or "default",
        "effort": args.effort,
        "judge_model": args.judge_model if args.enable_rubric else None,
        "started_at": started_at,
        "finished_at": finished_at,
        "duration_seconds": duration,
        # Headline outcomes, deliberately decoupled:
        "solved": deterministic.outcome_pass,                  # did it satisfy the acceptance tests?
        "completeness": deterministic.completeness,            # fraction of sub-requirements met
        "no_regression": deterministic.regression_pass,        # didn't break existing behavior
        "static_clean": deterministic.static_pass,             # ruff + mypy clean
        "completed_within_limits": metrics["completed"],       # finished (not timeout/budget kill)
        "scores": {
            "outcome_pass": deterministic.outcome_pass,
            "regression_pass": deterministic.regression_pass,
            "static_pass": deterministic.static_pass,
            "completeness": deterministic.completeness,
            "rubric_score": rubric_score,
        },
        "manipulation_check": {
            "injected_context_chars": len(setup.injected_context),
            "seeded_memory_count": setup.seeded_count,
            "recall_calls": metrics["recall_calls"],
            "memory_fired": (
                len(setup.injected_context) > 0 if condition in {"hooks_only", "oracle", "earned_hooks", "hooks_relevance"}
                else metrics["recall_calls"] > 0 if condition in {"mcp_only", "mcp_nudged"}
                else None
            ),
            "notes": setup.notes,
        },
        "metrics": metrics,
        "paths": {
            "workspace": str(artifacts.workspace),
            "stdout": str(artifacts.stdout_path),
            "stream_json": str(artifacts.stream_json_path),
            "git_diff": str(artifacts.diff_path),
            "grader_log": str(artifacts.grader_log_path),
            "injected_context": str(artifacts.injected_context_path),
        },
    }
    (trial_dir / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    teardown_condition(ctx)
    return result


def main() -> int:
    args = parse_args()
    runs_root = (REPO_ROOT / args.runs_root).resolve()
    runs_root.mkdir(parents=True, exist_ok=True)
    task_paths = resolve_tasks(args)
    if not task_paths:
        print("No task specs found.", file=sys.stderr)
        return 2

    conditions = args.condition or list(CONDITIONS)
    if args.replicate:
        replicates = args.replicate
    elif args.replicates > 0:
        replicates = list(range(1, args.replicates + 1))
    else:
        replicates = [1, 2, 3]

    print("Preparing shared grader venv…")
    grader_bin = ensure_shared_venv(runs_root, GRADER_REQUIREMENTS)

    all_results: list[dict] = []
    errors: list[dict] = []
    matrix_path = runs_root / "matrix_results.json"
    for task_path in task_paths:
        task = load_task_spec(task_path, TASK_SCHEMA)
        for condition in conditions:
            for replicate in replicates:
                print(f"==> {task.id} [{condition}] rep={replicate}")
                # One bad trial (e.g. the agent corrupts the workspace .git, so git_diff_stats' `git
                # add -A` raises) must not abort a multi-hour, real-cost run and discard every trial
                # completed so far. Isolate each trial and keep going.
                try:
                    result = run_trial(
                        task=task,
                        condition=condition,
                        replicate=replicate,
                        runs_root=runs_root,
                        grader_bin=grader_bin,
                        args=args,
                    )
                except Exception as exc:  # noqa: BLE001 — a single trial's failure is non-fatal to the batch
                    print(f"    !! trial errored, skipping: {exc}", file=sys.stderr)
                    errors.append({"task": task.id, "condition": condition, "replicate": replicate, "error": str(exc)})
                    continue
                flag = "OK " if result["solved"] else "XX "
                cost = result["metrics"]["total_cost_usd"]
                turns = result["metrics"]["num_turns"]
                cost_s = f"${cost:.3f}" if cost is not None else "n/a(incomplete)"
                print(
                    f"    {flag} solved={result['solved']} complete={result['completeness']:.2f} "
                    f"turns={turns if turns is not None else 'n/a'} cost={cost_s} "
                    f"mem_fired={result['manipulation_check']['memory_fired']}"
                )
                all_results.append(result)
                # Persist after every trial so a later crash can't throw away completed work.
                matrix_path.write_text(json.dumps(all_results, indent=2), encoding="utf-8")

    return finalize(all_results=all_results, errors=errors, runs_root=runs_root, matrix_path=matrix_path)


def finalize(*, all_results: list[dict], errors: list[dict], runs_root: Path, matrix_path: Path) -> int:
    """Report the batch outcome and pick the exit code.

    Errored trials are non-fatal DURING the run (completed trials are kept), but they make the
    dataset incomplete — so the run as a whole must fail loudly. Exiting 0 here would let CI (or a
    human skimming the log) treat partial data as a clean matrix.
    """
    print(f"\nWrote {len(all_results)} trial results to {matrix_path}")
    if errors:
        errors_path = runs_root / "matrix_errors.json"
        errors_path.write_text(json.dumps(errors, indent=2), encoding="utf-8")
        print(f"{len(errors)} trial(s) errored and were skipped; see {errors_path}", file=sys.stderr)
        print("FAILING: results are incomplete — rerun the errored trials before using this data.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
