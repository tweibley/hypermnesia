# Hypermnesia Eval Harness

A reproducible benchmark that measures whether Hypermnesia's memory actually helps a coding agent —
not just whether the agent can code. It runs the **Claude Code CLI** on a synthetic Python web app
across controlled conditions and grades the result with held-out tests and authoritative metrics.

**→ Findings and measured results: [RESULTS.md](RESULTS.md).**

## The core idea: hold out the knowledge

Memory only helps if the project has knowledge the agent needs but can't see in the workspace. So the
headline experiment **seeds a known set of memories** and makes success depend on them:

- The **acceptance tests are held out** — copied into the workspace only *after* the agent finishes,
  so the hidden requirement is never leaked to the agent.
- For `memory_critical` tasks, the requirement (e.g. the project's error-envelope shape) lives **only**
  in seeded memory. A baseline agent can implement the derivable parts but cannot guess the convention.
- A **manipulation check** records exactly what memory injected (or whether the agent called `recall`),
  so a null result is interpretable — we can tell "memory didn't help" apart from "memory never fired".

This is the *controlled / seeded* mode (clean attribution). The *earned / longitudinal* mode
(`earned_hooks`) instead runs warmup sessions that generate memories via the real capture→drain
classifier, then measures — more realistic, but noisier. See "Modes" below.

## Conditions

| Condition | Memory delivery | Measures |
|---|---|---|
| `baseline` | none (isolated empty store) | control |
| `hooks_only` | seeded store + hydrate hooks inject at SessionStart | the automatic delivery mechanism |
| `mcp_only` | seeded store + MCP server (`recall`/`ask`/`remember`); agent must choose to recall | agent-initiated retrieval |
| `oracle` | the same memory block pasted directly into the prompt | upper bound: is the knowledge useful at all? |
| `earned_hooks` | **nothing seeded** — warmup sessions generate memories via the real capture→classify (Gemini) loop, then hydrate injects them | the full longitudinal loop, end-to-end |
| `hooks_relevance` | seeded store; SessionStart inject-all disabled, only per-prompt relevance-ranked injection | whether relevance ranking blunts near-miss harm |
| `mcp_nudged` | seeded store + MCP server + the real `install-memory-guide` CLAUDE.md block nudging the agent to `recall` | whether MCP's bottleneck is delivery or adoption |

Reading them together separates *is the knowledge useful* (oracle) → *does retrieval surface it*
(seeded hooks/mcp) → *does the full capture loop earn it* (earned_hooks).

## Task families

| Family | Success depends on memory? | Headline metric |
|---|---|---|
| `memory_critical` | yes — held-out requirement lives only in memory | solve-rate lift |
| `memory_efficiency` | no — solvable either way, but memory points at the right approach | Δturns / Δcost at equal success |
| `guardrail` | no — self-contained; memory is irrelevant | no regression + injection overhead |
| `distractor` | no — store seeded with plausible-but-irrelevant memories | not misled (success unchanged) |

## What's measured

- **Outcomes (deterministic, decoupled):** `solved` (all held-out acceptance tests pass),
  `completeness` (fraction of independently-checkable sub-requirements — partial credit),
  `no_regression`, `static_clean` (ruff + mypy), `completed_within_limits`.
- **Process/efficiency (from the authoritative `result` event):** `num_turns`, `total_cost_usd`,
  real token usage, `duration_ms`, tool-error count, diff size.
- **Manipulation check:** `injected_context_chars`, `seeded_memory_count`, `recall_calls`, `memory_fired`.
- **Subjective quality (optional LLM judge):** an Opus-4.8 rubric scoring instruction-adherence,
  minimality, maintainability (`--enable-rubric`).

## Isolation & reproducibility

- Every condition runs against an **isolated memory store** via `HYPERMNESIA_SUPPORT_DIR=<trial>/ht_home`
  — the user's real `~/Library/Application Support/Hypermnesia` store is never touched.
- The workspace is pinned to a **fixed project id** (`github.com/eval/synthetic-webapp`) via a fake git
  remote, so every replicate resolves to the same memory key and seeding is deterministic.
- Memories are seeded deterministically with `hypermnesia seed-memories` (no classifier in the loop).
- A **shared grader venv** is built once (no per-command `pip install`).
- Subjects run on **Sonnet + medium effort** by default; the LLM judge runs on **Opus 4.8**.
- `--setting-sources project,local` and `--strict-mcp-config` keep user-level config out of the trial.

## Layout

- `schemas/` — JSON schema for tasks and results
- `scenarios/python_webapp_seed/` — the synthetic FastAPI app under test
- `tasks/` — task specs (one JSON per task; memory_seed + requirements inline)
- `overlays/` — agent-visible files copied in before the run
- `grader_overlays/` — held-out acceptance tests copied in after the run
- `conditions/` — condition setup/teardown, seeding, manipulation check
- `runner/` — trial orchestration + metrics
- `graders/` — deterministic graders + Opus-4.8 rubric judge
- `reports/` — per-condition + lift-vs-baseline summary

## Quick start

```bash
python3 -m venv .venv-driver && source .venv-driver/bin/activate
pip install -r evals/requirements.txt          # jsonschema for the driver

# Pilot: the two flagship tasks, all conditions, 2 replicates, with the Opus judge.
python3 evals/runner/run_matrix.py \
  --task evals/tasks/mc_error_envelope.json \
  --condition baseline --condition hooks_only --condition mcp_only --condition oracle \
  --replicates 2 --model sonnet --effort medium \
  --judge-model claude-opus-4-8 --enable-rubric

# Full suite (all tasks), 5 replicates:
python3 evals/runner/run_matrix.py --replicates 5 --model sonnet --effort medium

# Summarize (per-condition rates + lift vs baseline with bootstrap CIs + manipulation check):
python3 evals/reports/summarize.py
```

Requires `claude` and `hypermnesia` on `PATH` (set `HYPERMNESIA_BIN` / `CLAUDE_BIN` otherwise).
Use `--skip-claude` to validate harness mechanics without spending API budget.

## Modes

- **Seeded (`baseline`/`hooks_only`/`mcp_only`/`oracle`):** fixed knowledge, clean causal attribution,
  cheap, deterministic. The headline measurement.
- **Earned / longitudinal (`earned_hooks`):** for each measured task, the agent first completes the
  task's `warmup` prompt(s) in throwaway workspaces; `hypermnesia backfill` replays those transcripts
  through the classifier (Gemini) into the isolated store; then the measured session's hydrate hooks
  inject the *earned* memories. Tests the full capture→hydrate loop. Needs `GEMINI_API_KEY`, costs the
  extra warmup runs, and is nondeterministic (a model decides what to capture) — so run more replicates
  and read it alongside `oracle`/`hooks_only`, which bound what perfect/seeded delivery would achieve.

```bash
# Earned validation on the memory-critical tasks (compare against baseline/hooks_only from the matrix):
python3 evals/runner/run_matrix.py \
  --task evals/tasks/mc_error_envelope.json --task evals/tasks/mc_audit_log.json \
  --condition earned_hooks --replicates 3 --model sonnet --effort medium
```

## Honest caveats

- `memory_critical` tasks are *designed* so baseline can't guess the held-out convention — that's the
  point (it's knowledge from past sessions), but it means the solve-rate lift is partly a property of
  task design. The `oracle` condition bounds how much of that lift is "knowledge" vs "delivery".
- Subjects are nondeterministic; efficiency deltas are subtler than effectiveness deltas and need more
  replicates to clear the noise.
- The synthetic app is small; absolute numbers are illustrative. The harness, not the headline number,
  is the deliverable.
- Grader dependencies are floor-pinned (`>=`), and `static_clean` is literally "ruff + mypy exit 0" —
  new default rules in a future ruff/mypy release can shift that metric across machines and time. Pin
  exact versions in `run_matrix.py`'s `GRADER_REQUIREMENTS` if you need strict comparability.
