#!/usr/bin/env python3
"""Summarize Hypermnesia eval trials — rigorous "report card" edition.

Answers three questions:
  1. Effectiveness — does memory raise the solve rate / completeness vs baseline?
  2. Efficiency   — does it cut turns / cost / tool errors at equal success?
  3. Validity     — did the memory mechanism actually fire? (manipulation check)

Lift vs baseline is computed as a macro-average of per-task deltas (so an easy task with many
replicates can't dominate), with a two-level bootstrap CI that resamples both tasks and replicates.

NEW sections (v2):
  4. mechanism_gated_uplift  — solve-rate delta computed over ALL trials and over ONLY trials
                               where memory_fired=True; also reports delivery_failure_rate.
  5. application_metrics     — applied_memory_rate, spurious_application_rate, citation_use_rate.
  6. per_family_ci           — bootstrap 95% CI on solve rate for each (family × condition) cell.
  7. verdict                 — PASS/FAIL report card against pre-defined success criteria.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Verdict thresholds — tune here without touching logic
# ---------------------------------------------------------------------------
MEMORY_CRITICAL_UPLIFT_CI_LB_THRESHOLD = 0.0   # CI lower bound must be > this
GUARDRAIL_NO_HARM_EPSILON = 0.05                # CI lower bound of delta must be > -this (no regression)
DISTRACTOR_ROBUST_SLACK = 0.05                  # hooks_only failure rate <= baseline + this
# For efficiency: both solve_delta >= 0 AND (turns_delta <= 0 OR cost_delta <= 0)
EFFICIENCY_SOLVE_THRESHOLD = 0.0               # solve delta must be >= this
EFFICIENCY_TURNS_THRESHOLD = 0.0               # median turns delta must be <= this
EFFICIENCY_COST_THRESHOLD = 0.0                # median cost delta must be <= this

# Stopwords to exclude from citation-token matching
_STOPWORDS = frozenset(
    "this that with from have been will they their what when where which"
    " there then than them into also only just more some like over"
    " each such both about after before could would should must need"
    " used make made call calls does done gets gets make return".split()
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize Hypermnesia eval trial results.")
    parser.add_argument("--runs-root", default="evals/runs")
    parser.add_argument("--baseline", default="baseline")
    parser.add_argument("--tasks-dir", default="evals/tasks")
    return parser.parse_args()


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def median(values: list[float]) -> float:
    return statistics.median(values) if values else 0.0


def metric_value(trial: dict[str, Any], metric: str) -> float | None:
    """The numeric value of `metric` for a trial, or None when it was not recorded — a
    timed-out/crashed trial has no turns/cost/tokens (see metrics.py). Callers that aggregate
    numeric metrics MUST skip None (use `_present`/`_metric_list`); blindly `float()`-ing it crashes."""
    raw = trial[metric] if metric in trial else (trial.get("metrics") or {}).get(metric)
    return None if raw is None else float(raw)


def _present(rows: list[dict], extractor: Callable[[dict], float | None]) -> list[dict]:
    """Rows whose extractor value is present (not None) — i.e. trials that recorded this metric."""
    return [r for r in rows if extractor(r) is not None]


def _metric_list(rows: list[dict], metric: str) -> list[float]:
    """Non-None values of `metric` across `rows` (drops incomplete trials)."""
    return [v for v in (metric_value(r, metric) for r in rows) if v is not None]


def per_condition_summary(rows: list[dict]) -> dict[str, Any]:
    solved = [1.0 if r["solved"] else 0.0 for r in rows]
    fired = [1.0 if r["manipulation_check"]["memory_fired"] else 0.0
             for r in rows if r["manipulation_check"]["memory_fired"] is not None]
    # Efficiency (turns/cost/duration) is only meaningful for runs that actually FINISHED — a
    # timed-out/crashed trial has no real cost and would bias the medians downward. Success and
    # completeness, by contrast, count every trial (a timeout is a legitimate failure).
    done = [r for r in rows if r.get("completed_within_limits")]
    return {
        "n_trials": len(rows),
        "n_completed": len(done),
        "solve_rate": round(mean(solved), 4),
        "mean_completeness": round(mean([r["completeness"] for r in rows]), 4),
        "regression_safe_rate": round(mean([1.0 if r["no_regression"] else 0.0 for r in rows]), 4),
        "static_clean_rate": round(mean([1.0 if r["static_clean"] else 0.0 for r in rows]), 4),
        "completed_rate": round(mean([1.0 if r["completed_within_limits"] else 0.0 for r in rows]), 4),
        "median_turns": round(median(_metric_list(done, "num_turns")), 2),
        "median_cost_usd": round(median(_metric_list(done, "total_cost_usd")), 4),
        "median_cost_with_warmup_usd": round(median(_metric_list(done, "total_cost_with_warmup")), 4),
        "median_tool_errors": round(median(_metric_list(done, "tool_error_count")), 2),
        "median_diff_added": round(median(_metric_list(done, "diff_lines_added")), 2),
        "memory_fired_rate": round(mean(fired), 4) if fired else None,
        # MCP recall adoption (meaningful for mcp_only): did the agent recall at all / before its first edit?
        "recall_rate": round(mean([1.0 if r["metrics"].get("recalled") else 0.0 for r in rows]), 4),
        "recall_before_first_edit_rate": round(
            mean([1.0 if r["metrics"].get("recall_before_first_edit") else 0.0 for r in rows]), 4
        ),
    }


def macro_delta(
    by_task: dict[str, dict[str, list[dict]]],
    condition: str,
    baseline: str,
    extractor: Callable[[dict], float | None],
) -> float:
    """Mean over tasks of (mean_condition - mean_baseline) for that task. Rows where the extractor
    is None (e.g. turns/cost for an incomplete trial) are skipped, so numeric-metric deltas are
    computed over completed trials only; a task with no completed data on either side is skipped."""
    deltas = []
    for task_id, by_cond in by_task.items():
        if condition not in by_cond or baseline not in by_cond:
            continue
        c_rows = _present(by_cond[condition], extractor)
        b_rows = _present(by_cond[baseline], extractor)
        if not c_rows or not b_rows:
            continue
        c = mean([v for r in c_rows if (v := extractor(r)) is not None])
        b = mean([v for r in b_rows if (v := extractor(r)) is not None])
        deltas.append(c - b)
    return mean(deltas)


def bootstrap_delta_ci(
    by_task: dict[str, dict[str, list[dict]]],
    condition: str,
    baseline: str,
    extractor: Callable[[dict], float | None],
    *,
    samples: int = 1000,
) -> tuple[float, float]:
    # Pre-filter to rows that recorded this metric (None = incomplete trial), and drop tasks with no
    # completed data on either side — so resampling never hits float(None).
    filtered: dict[str, tuple[list[dict], list[dict]]] = {}
    for t, bc in by_task.items():
        if condition not in bc or baseline not in bc:
            continue
        c_rows = _present(bc[condition], extractor)
        b_rows = _present(bc[baseline], extractor)
        if c_rows and b_rows:
            filtered[t] = (c_rows, b_rows)
    task_ids = list(filtered)
    if not task_ids:
        return (0.0, 0.0)
    rng = random.Random(42)
    estimates = []
    for _ in range(samples):
        picked_tasks = [rng.choice(task_ids) for _ in task_ids]
        deltas = []
        for t in picked_tasks:
            cond_rows, base_rows = filtered[t]
            c = mean([v for _ in cond_rows if (v := extractor(rng.choice(cond_rows))) is not None])
            b = mean([v for _ in base_rows if (v := extractor(rng.choice(base_rows))) is not None])
            deltas.append(c - b)
        estimates.append(mean(deltas))
    estimates.sort()
    lo = estimates[int(0.025 * len(estimates))]
    hi = estimates[int(0.975 * len(estimates))]
    return (round(lo, 4), round(hi, 4))


def lift_table(
    by_task: dict[str, dict[str, list[dict]]],
    conditions: list[str],
    baseline: str,
) -> dict[str, Any]:
    # Efficiency metrics (turns/cost/tool-errors) must EXCLUDE trials that didn't complete within
    # limits — a budget- or turn-limit-killed trial still emits a result event with an inflated,
    # capped turn/cost count, and counting it would contaminate the "does memory cut turns/cost"
    # delta (the per-condition medians already exclude it). Returning None makes macro_delta /
    # bootstrap skip it, matching metrics.py's design.
    def efficiency(r: dict, key: str) -> float | None:
        return metric_value(r, key) if r.get("completed_within_limits") else None

    metrics: dict[str, Callable[[dict], float | None]] = {
        "solve_rate": lambda r: 1.0 if r["solved"] else 0.0,
        "completeness": lambda r: float(r["completeness"]),
        "num_turns": lambda r: efficiency(r, "num_turns"),
        "total_cost_usd": lambda r: efficiency(r, "total_cost_usd"),
        "tool_error_count": lambda r: efficiency(r, "tool_error_count"),
    }
    out: dict[str, Any] = {}
    for condition in conditions:
        if condition == baseline:
            continue
        out[f"{condition}_vs_{baseline}"] = {
            name: {
                "delta": round(macro_delta(by_task, condition, baseline, fn), 4),
                "ci95": bootstrap_delta_ci(by_task, condition, baseline, fn),
            }
            for name, fn in metrics.items()
        }
    return out


# ---------------------------------------------------------------------------
# NEW: mechanism-gated uplift
# ---------------------------------------------------------------------------

def _memory_fired(trial: dict) -> bool:
    """Return True if the memory mechanism demonstrably delivered content."""
    mc = trial["manipulation_check"]
    cond = trial["condition"]
    if cond == "mcp_only":
        return (mc.get("recall_calls") or 0) > 0
    fired = mc.get("memory_fired")
    return bool(fired)


def mechanism_gated_uplift(
    by_task: dict[str, dict[str, list[dict]]],
    conditions: list[str],
    baseline: str,
) -> dict[str, Any]:
    """For each condition vs baseline:
    - uplift_all_trials: macro-delta on solve_rate over every trial
    - uplift_fired_only: same but restricted to trials where memory_fired=True
    - delivery_failure_rate: fraction of condition's trials where memory did NOT fire
    """
    solve = lambda r: 1.0 if r["solved"] else 0.0

    out: dict[str, Any] = {}
    for condition in conditions:
        if condition == baseline:
            continue

        # Collect all condition trials (flat, for delivery_failure_rate)
        all_cond_trials: list[dict] = []
        for by_cond in by_task.values():
            all_cond_trials.extend(by_cond.get(condition, []))

        # delivery_failure_rate: baseline has None → treat as N/A
        cond_is_baseline = condition == baseline
        fired_flags = [_memory_fired(r) for r in all_cond_trials]
        n_not_fired = sum(1 for f in fired_flags if not f)
        delivery_failure_rate = (
            round(n_not_fired / len(fired_flags), 4)
            if fired_flags and not cond_is_baseline
            else None
        )

        # uplift_all_trials: standard macro-delta
        uplift_all = round(macro_delta(by_task, condition, baseline, solve), 4)
        ci_all = bootstrap_delta_ci(by_task, condition, baseline, solve)

        # uplift_fired_only: filter each task's condition rows to fired-only
        fired_by_task: dict[str, dict[str, list[dict]]] = {}
        for task_id, by_cond in by_task.items():
            if condition not in by_cond or baseline not in by_cond:
                continue
            fired_rows = [r for r in by_cond[condition] if _memory_fired(r)]
            if not fired_rows:
                continue
            fired_by_task[task_id] = {
                condition: fired_rows,
                baseline: by_cond[baseline],
            }

        if fired_by_task:
            uplift_fired = round(macro_delta(fired_by_task, condition, baseline, solve), 4)
            ci_fired = bootstrap_delta_ci(fired_by_task, condition, baseline, solve)
        else:
            uplift_fired = None
            ci_fired = None

        out[condition] = {
            "delivery_failure_rate": delivery_failure_rate,
            "uplift_all_trials": {"delta": uplift_all, "ci95": ci_all},
            "uplift_fired_only": (
                {"delta": uplift_fired, "ci95": ci_fired}
                if uplift_fired is not None
                else None
            ),
        }

    return out


# ---------------------------------------------------------------------------
# NEW: application metrics
# ---------------------------------------------------------------------------

def _extract_seed_tokens(task_memory_seeds: list[Any]) -> list[str]:
    """Extract distinctive lowercase tokens (len>=4, not stopwords) from memory seed summaries."""
    tokens: set[str] = set()
    for seed in task_memory_seeds:
        text = seed.get("summary", "") if isinstance(seed, dict) else str(seed)
        for tok in re.findall(r"[a-z]{4,}", text.lower()):
            if tok not in _STOPWORDS:
                tokens.add(tok)
    return list(tokens)


def _stream_text(trial: dict) -> str:
    """Read the stream_json file and return its full text (empty string on failure)."""
    path_str = trial.get("paths", {}).get("stream_json", "")
    if not path_str:
        return ""
    try:
        return Path(path_str).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def application_metrics(
    by_family: dict[str, dict[str, list[dict]]],
    by_condition: dict[str, list[dict]],
    conditions: list[str],
    baseline: str,
    task_seeds: dict[str, list[Any]],
) -> dict[str, Any]:
    """Compute applied_memory_rate, spurious_application_rate, citation_use_rate."""

    # --- applied_memory_rate ---
    # On memory_critical tasks where memory fired: mean completeness per condition.
    applied_memory_rate: dict[str, Any] = {}
    mc_by_cond = by_family.get("memory_critical", {})
    for cond in conditions:
        rows = mc_by_cond.get(cond, [])
        fired_rows = [r for r in rows if _memory_fired(r)]
        if fired_rows:
            applied_memory_rate[cond] = round(mean([r["completeness"] for r in fired_rows]), 4)
        else:
            applied_memory_rate[cond] = None

    # --- spurious_application_rate ---
    # On guardrail+distractor families: fraction of trials that FAILED (solved=False)
    # per condition, compared to baseline's failure rate on the same families.
    harm_families = {"guardrail", "distractor"}
    harm_trials_by_cond: dict[str, list[dict]] = defaultdict(list)
    for fam in harm_families:
        for cond, rows in by_family.get(fam, {}).items():
            harm_trials_by_cond[cond].extend(rows)

    spurious_application_rate: dict[str, Any] = {}
    for cond in conditions:
        rows = harm_trials_by_cond.get(cond, [])
        if rows:
            failure_rate = round(mean([0.0 if r["solved"] else 1.0 for r in rows]), 4)
            spurious_application_rate[cond] = failure_rate
        else:
            spurious_application_rate[cond] = None

    # --- citation_use_rate ---
    # Per condition: fraction of trials whose stream_json references >=2 distinct seeded tokens.
    citation_use_rate: dict[str, Any] = {}
    for cond in conditions:
        rows = by_condition.get(cond, [])
        if not rows:
            citation_use_rate[cond] = None
            continue
        cited_count = 0
        for r in rows:
            seeds = task_seeds.get(r["task_id"], [])
            tokens = _extract_seed_tokens(seeds)
            if not tokens:
                # No seeds → no citation possible; skip but don't penalise
                continue
            text = _stream_text(r).lower()
            if not text:
                continue
            distinct_hits = sum(1 for tok in set(tokens) if tok in text)
            if distinct_hits >= 2:
                cited_count += 1
        # denominator: trials that have seeds and accessible stream_json
        denom = sum(
            1 for r in rows
            if task_seeds.get(r["task_id"]) and _stream_text(r)
        )
        citation_use_rate[cond] = round(cited_count / denom, 4) if denom else None

    return {
        "applied_memory_rate": applied_memory_rate,
        "spurious_application_rate": spurious_application_rate,
        "citation_use_rate": citation_use_rate,
    }


# ---------------------------------------------------------------------------
# NEW: per-family bootstrap CIs on solve rate
# ---------------------------------------------------------------------------

def per_family_ci(
    by_family: dict[str, dict[str, list[dict]]],
    conditions: list[str],
    *,
    samples: int = 1000,
) -> dict[str, Any]:
    """Bootstrap 95% CI on solve rate for each (family × condition) cell."""
    rng = random.Random(42)
    out: dict[str, Any] = {}
    for fam, by_cond in by_family.items():
        out[fam] = {}
        for cond in conditions:
            rows = by_cond.get(cond, [])
            if not rows:
                out[fam][cond] = None
                continue
            solve_vals = [1.0 if r["solved"] else 0.0 for r in rows]
            point = round(mean(solve_vals), 4)
            # Bootstrap the mean solve rate
            estimates = sorted(
                mean([rng.choice(solve_vals) for _ in solve_vals])
                for _ in range(samples)
            )
            lo = round(estimates[int(0.025 * len(estimates))], 4)
            hi = round(estimates[int(0.975 * len(estimates))], 4)
            out[fam][cond] = {"solve_rate": point, "ci95": [lo, hi], "n": len(rows)}
    return out


# ---------------------------------------------------------------------------
# NEW: verdict / report card
# ---------------------------------------------------------------------------

def _ci_lower(ci: tuple | list | None) -> float | None:
    if ci is None:
        return None
    return ci[0]


def _ci_upper(ci: tuple | list | None) -> float | None:
    if ci is None:
        return None
    return ci[1]


def _family_filtered_by_task(
    by_task: dict[str, dict[str, list[dict]]],
    family: str,
) -> dict[str, dict[str, list[dict]]]:
    """Return a by_task dict restricted to tasks belonging to the given family."""
    filtered: dict[str, dict[str, list[dict]]] = {}
    for task_id, by_cond in by_task.items():
        # Check family from any available trial
        task_family = None
        for rows in by_cond.values():
            if rows:
                task_family = rows[0].get("family")
                break
        if task_family == family:
            filtered[task_id] = by_cond
    return filtered


def build_verdict(
    by_task: dict[str, dict[str, list[dict]]],
    by_family: dict[str, dict[str, list[dict]]],
    conditions: list[str],
    baseline: str,
    mgu: dict[str, Any],
    family_ci: dict[str, Any],
) -> dict[str, Any]:
    """Evaluate each pre-defined criterion and return a verdict object."""
    solve = lambda r: 1.0 if r["solved"] else 0.0

    verdict: dict[str, Any] = {}

    # ---- 1. memory_critical_uplift_positive --------------------------------
    # hooks_only mechanism-gated (fired_only) solve-uplift CI lower bound > 0
    # Compute over ONLY memory_critical tasks, restricted to trials where memory fired.
    mc_fam = "memory_critical"
    cond = "hooks_only"
    mc_by_task = _family_filtered_by_task(by_task, mc_fam)
    if mc_by_task and cond in conditions:
        # Build fired_only subset
        fired_by_task_mc: dict[str, dict[str, list[dict]]] = {}
        for task_id, by_cond in mc_by_task.items():
            if cond not in by_cond or baseline not in by_cond:
                continue
            fired_rows = [r for r in by_cond[cond] if _memory_fired(r)]
            if not fired_rows:
                continue
            fired_by_task_mc[task_id] = {cond: fired_rows, baseline: by_cond[baseline]}
        if fired_by_task_mc:
            delta_mc = round(macro_delta(fired_by_task_mc, cond, baseline, solve), 4)
            ci_mc = bootstrap_delta_ci(fired_by_task_mc, cond, baseline, solve)
            lb = _ci_lower(ci_mc)
            passed = (lb is not None) and lb > MEMORY_CRITICAL_UPLIFT_CI_LB_THRESHOLD
            verdict["memory_critical_uplift_positive"] = {
                "result": "PASS" if passed else "FAIL",
                "measured_delta": delta_mc,
                "ci95": list(ci_mc),
                "ci95_lower_bound": lb,
                "threshold": f"CI lower bound > {MEMORY_CRITICAL_UPLIFT_CI_LB_THRESHOLD}",
                "note": "computed on memory_critical family, fired trials only",
            }
        else:
            verdict["memory_critical_uplift_positive"] = {"result": "n/a", "reason": "no fired-only data in memory_critical"}
    else:
        verdict["memory_critical_uplift_positive"] = {"result": "n/a", "reason": f"memory_critical family or {cond} absent"}

    # ---- 2. guardrail_no_harm ----------------------------------------------
    # hooks_only solve-rate delta vs baseline on guardrail has CI upper bound < epsilon above 0
    # i.e., the upper bound of the *negative* delta must be < epsilon
    # More precisely: CI upper bound < epsilon  (so the harm, if any, is negligible)
    guardrail_fam_by_task: dict[str, dict[str, list[dict]]] = {}
    for task_id, by_cond in by_task.items():
        # Only keep tasks that have at least one guardrail trial
        # We check family via the trials themselves
        any_guardrail = any(
            r.get("family") == "guardrail"
            for rows in by_cond.values()
            for r in rows
        )
        if any_guardrail and cond in by_cond and baseline in by_cond:
            guardrail_fam_by_task[task_id] = by_cond

    if guardrail_fam_by_task and cond in conditions:
        delta_g = round(macro_delta(guardrail_fam_by_task, cond, baseline, solve), 4)
        ci_g = bootstrap_delta_ci(guardrail_fam_by_task, cond, baseline, solve)
        lb = _ci_lower(ci_g)
        # "No harm" means memory did not significantly HURT guardrail tasks: the lower bound of the
        # (condition - baseline) delta must stay above -epsilon. A positive delta (memory improved a
        # self-contained task) is NOT harm and passes — the previous upper-bound check wrongly FAILed
        # on improvement.
        passed_g = (lb is not None) and lb > -GUARDRAIL_NO_HARM_EPSILON
        verdict["guardrail_no_harm"] = {
            "result": "PASS" if passed_g else "FAIL",
            "measured_delta": delta_g,
            "ci95_lower_bound": lb,
            "threshold": f"CI lower bound of delta > -{GUARDRAIL_NO_HARM_EPSILON} (no significant regression)",
            "interpretation": "negative delta means memory HURT guardrail solve rate; we fail only on a significant regression, not on improvement",
        }
    else:
        verdict["guardrail_no_harm"] = {"result": "n/a", "reason": "guardrail family or hooks_only absent"}

    # ---- 3. distractor_robust ----------------------------------------------
    # hooks_only failure rate on distractor <= baseline failure rate + slack
    dist_hooks = by_family.get("distractor", {}).get("hooks_only", [])
    dist_base = by_family.get("distractor", {}).get(baseline, [])
    if dist_hooks and dist_base:
        fail_hooks = round(mean([0.0 if r["solved"] else 1.0 for r in dist_hooks]), 4)
        fail_base = round(mean([0.0 if r["solved"] else 1.0 for r in dist_base]), 4)
        threshold_val = round(fail_base + DISTRACTOR_ROBUST_SLACK, 4)
        passed_d = fail_hooks <= threshold_val
        verdict["distractor_robust"] = {
            "result": "PASS" if passed_d else "FAIL",
            "hooks_only_failure_rate": fail_hooks,
            "baseline_failure_rate": fail_base,
            "threshold": f"hooks_only <= baseline + {DISTRACTOR_ROBUST_SLACK} = {threshold_val}",
        }
    else:
        verdict["distractor_robust"] = {"result": "n/a", "reason": "distractor family absent"}

    # ---- 4. efficiency_gain ------------------------------------------------
    # On memory_efficiency family: hooks_only median turns delta <= 0 (or cost delta <=0)
    # AND solve delta >= 0
    eff_by_task: dict[str, dict[str, list[dict]]] = {}
    for task_id, by_cond in by_task.items():
        any_eff = any(
            r.get("family") == "memory_efficiency"
            for rows in by_cond.values()
            for r in rows
        )
        if any_eff and cond in by_cond and baseline in by_cond:
            eff_by_task[task_id] = by_cond

    if eff_by_task and cond in conditions:
        solve_delta_eff = round(macro_delta(eff_by_task, cond, baseline, solve), 4)
        turns_delta_eff = round(macro_delta(eff_by_task, cond, baseline, lambda r: metric_value(r, "num_turns")), 4)
        cost_delta_eff = round(macro_delta(eff_by_task, cond, baseline, lambda r: metric_value(r, "total_cost_usd")), 4)
        solve_ok = solve_delta_eff >= EFFICIENCY_SOLVE_THRESHOLD
        efficiency_ok = (turns_delta_eff <= EFFICIENCY_TURNS_THRESHOLD) or (cost_delta_eff <= EFFICIENCY_COST_THRESHOLD)
        passed_e = solve_ok and efficiency_ok
        verdict["efficiency_gain"] = {
            "result": "PASS" if passed_e else "FAIL",
            "solve_delta": solve_delta_eff,
            "turns_delta": turns_delta_eff,
            "cost_delta_usd": cost_delta_eff,
            "threshold": (
                f"solve_delta >= {EFFICIENCY_SOLVE_THRESHOLD} AND "
                f"(turns_delta <= {EFFICIENCY_TURNS_THRESHOLD} OR cost_delta <= {EFFICIENCY_COST_THRESHOLD})"
            ),
        }
    else:
        verdict["efficiency_gain"] = {"result": "n/a", "reason": "memory_efficiency family or hooks_only absent"}

    return verdict


# ---------------------------------------------------------------------------
# Causal-attribution metrics — track these per product change, not just solve rate
# ---------------------------------------------------------------------------

def causal_metrics(
    by_condition: dict[str, list[dict]],
    task_tags: dict[str, list[str]],
) -> dict[str, Any]:
    """Five named metrics that attribute outcomes to specific mechanisms, each sliced to the
    population it's about — so a product change can be credited (or blamed) precisely:

    - memory_fired_rate: was memory delivered at all? (injected for hooks/oracle/earned; recalled
      for mcp). Per condition.
    - memory_applied_correctly_rate: among memory_critical trials where memory FIRED, the solve rate
      — i.e. once delivered, did the agent apply it? (isolates application from delivery). Per condition.
    - near_miss_error_rate: on near-miss tasks (tag `near_miss`), the failure rate = memory-induced
      over-application harm. baseline ~0 is the floor; higher under a memory condition = harm. Per condition.
    - earned_capture_success_rate: among earned_hooks trials, the memory_fired rate — did the real
      capture->classify loop produce injectable memory? (global, earned only).
    - mcp_recall_call_rate: among mcp_* conditions, the fraction of trials with >=1 recall call.
    """
    def fired(r: dict) -> bool | None:
        return r["manipulation_check"]["memory_fired"]

    fired_rate: dict[str, float] = {}
    applied_rate: dict[str, float] = {}
    near_miss_rate: dict[str, float] = {}
    mcp_rate: dict[str, float] = {}
    for cond, rows in by_condition.items():
        fv = [1.0 if fired(r) else 0.0 for r in rows if fired(r) is not None]
        if fv:
            fired_rate[cond] = round(mean(fv), 4)
        mc_fired = [r for r in rows if r.get("family") == "memory_critical" and fired(r)]
        if mc_fired:
            applied_rate[cond] = round(mean([1.0 if r["solved"] else 0.0 for r in mc_fired]), 4)
        nm = [r for r in rows if "near_miss" in task_tags.get(r["task_id"], [])]
        if nm:
            near_miss_rate[cond] = round(mean([0.0 if r["solved"] else 1.0 for r in nm]), 4)
        if cond.startswith("mcp"):
            mcp_rate[cond] = round(mean([1.0 if r["metrics"].get("recalled") else 0.0 for r in rows]), 4)

    earned = by_condition.get("earned_hooks", [])
    earned_capture = (
        round(mean([1.0 if fired(r) else 0.0 for r in earned if fired(r) is not None]), 4)
        if earned else None
    )

    return {
        "memory_fired_rate": fired_rate,
        "memory_applied_correctly_rate": applied_rate,
        "near_miss_error_rate": near_miss_rate,
        "earned_capture_success_rate": earned_capture,
        "mcp_recall_call_rate": mcp_rate,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    args = parse_args()
    runs_root = Path(args.runs_root).resolve()
    matrix_path = runs_root / "matrix_results.json"
    if not matrix_path.exists():
        print(f"Missing {matrix_path}")
        return 2

    trials = json.loads(matrix_path.read_text(encoding="utf-8"))
    conditions = sorted({t["condition"] for t in trials})

    by_condition: dict[str, list[dict]] = defaultdict(list)
    by_task: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    by_family: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for t in trials:
        by_condition[t["condition"]].append(t)
        by_task[t["task_id"]][t["condition"]].append(t)
        by_family[t.get("family", "unknown")][t["condition"]].append(t)

    # Load task specs for memory_seed content (citation heuristic)
    tasks_dir = Path(args.tasks_dir)
    if not tasks_dir.is_absolute():
        # Try relative to the repo root (two levels up from this file), then cwd
        repo_root = Path(__file__).resolve().parents[2]
        candidate = repo_root / tasks_dir
        if candidate.exists():
            tasks_dir = candidate
        elif tasks_dir.exists():
            tasks_dir = tasks_dir.resolve()
    task_seeds: dict[str, list[Any]] = {}
    task_tags: dict[str, list[str]] = {}
    if tasks_dir.exists():
        for task_file in tasks_dir.glob("*.json"):
            try:
                spec = json.loads(task_file.read_text(encoding="utf-8"))
                tid = spec.get("id") or task_file.stem
                task_seeds[tid] = spec.get("memory_seed", [])
                task_tags[tid] = spec.get("tags", [])
            except (json.JSONDecodeError, OSError):
                pass

    # Compute all sections
    mgu = mechanism_gated_uplift(by_task, conditions, args.baseline)
    app_metrics = application_metrics(by_family, by_condition, conditions, args.baseline, task_seeds)
    fam_ci = per_family_ci(by_family, conditions)
    verd = build_verdict(by_task, by_family, conditions, args.baseline, mgu, fam_ci)
    causal = causal_metrics(by_condition, task_tags)

    payload = {
        "n_trials": len(trials),
        "conditions": conditions,
        "causal_metrics": causal,
        "by_condition": {c: per_condition_summary(rows) for c, rows in by_condition.items()},
        "by_family": {
            fam: {c: per_condition_summary(rows) for c, rows in bc.items()}
            for fam, bc in by_family.items()
        },
        "lift_vs_baseline": lift_table(by_task, conditions, args.baseline),
        "mechanism_gated_uplift": mgu,
        "application_metrics": app_metrics,
        "per_family_ci": fam_ci,
        "verdict": verd,
    }

    report_path = runs_root / "summary.json"
    report_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps(payload, indent=2))
    print(f"\nWrote summary report to {report_path}")

    # Pretty-print the causal metrics + verdict blocks to stderr for quick human inspection
    import sys
    print("\n" + "=" * 60, file=sys.stderr)
    print("CAUSAL METRICS (track per product change)", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    for name, val in causal.items():
        print(f"  {name}: {val}", file=sys.stderr)
    print("\n" + "=" * 60, file=sys.stderr)
    print("VERDICT BLOCK", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    for criterion, result in verd.items():
        status = result.get("result", "?")
        print(f"  [{status:4s}] {criterion}", file=sys.stderr)
        for k, v in result.items():
            if k != "result":
                print(f"          {k}: {v}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
