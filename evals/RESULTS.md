# Hypermnesia Eval — Results

What the benchmark has measured about whether Hypermnesia's memory helps a Claude Code agent, and
the product improvements that measurement drove. Methodology is in [README.md](README.md).

> **Read these numbers with the sample sizes in mind.** Most cells are 2–3 replicates on a small
> synthetic app; subjects are nondeterministic (Sonnet, medium effort). Treat point estimates as
> directional and the *mechanism* evidence (did the intended thing actually change?) as the stronger
> signal. Every claim below is labeled with its run + n. Trial workspaces are gitignored
> (large/ephemeral), but the consolidated result JSONs behind the headline tables are committed
> under [`results_data/`](results_data/) (paths sanitized) so the arithmetic can be audited without
> re-running; re-run instructions are at the end.

## TL;DR (updated 2026-07-16 — expanded replication, all data committed)

- **Delivery works; application is the frontier.** Across the full 8-task memory-critical family
  (n=24/arm, 3 reps each), hydration lifts solve-rate **0.12 → 0.62**. On the four tasks whose
  seeded memory states the requirement explicitly, the original result replicates exactly:
  **0/12 → 12/12**. The three tasks that still fail *with* memory all show the same signature —
  injection verified, agent applied the convention incompletely (terse seeds, or fixes that require
  auditing existing code). Memory delivery is solved; getting the agent to *fully apply* what it
  was told is the open problem, and the eval now measures it.
- **The harm problem is nearly gone.** Re-running the full 9-task distractor/adversarial family
  under the current engine (belief model + scoped seeds live): baseline **1.00**, hooks **0.94**
  (17/18) — vs 1.00→0.00 harm cells in the pre-belief data below. One residual near-miss failure
  (`adv_nearmiss_auth`, 1/2) remains and is reported, not hidden.
- **The bottleneck is capture, not retrieval.** In the realistic capture→hydrate loop, failures trace
  to the classifier (firing nothing, or dropping the anti-pattern a fix replaces) — not to retrieval
  or injection.

> **Provenance note (added after an adversarial self-audit).** Sections below are labeled either
> **[committed]** — consolidated JSONs under [`results_data/`](results_data/), re-derivable — or
> **[not committed]** — from gitignored working runs; treat those as narrative, not auditable
> evidence. Where a cell shows a CI of `[1.0, 1.0]` (or `[0,0]`), that is a **degenerate bootstrap
> artifact of a unanimous small sample**, not a precision claim.

---

## 0. Expanded replication — where it really lands (2026-07-16) **[committed: `results_data/runs_expanded_2026_07_16/`, `runs_adversarial_2026_07_16/`]**

The strongest prior claims rested on 2 web tasks (n=6/arm). This run widens to the **entire
memory-critical family (8 tasks × baseline/hooks × 3 reps = 48 trials)** and re-tests the **entire
distractor/adversarial family (9 tasks × 2 conditions × 2 reps = 36 trials)** under the shipping
engine (belief model, scoped seeds, conflict supersede, auto-confirm). 84 trials, ~$25, one day,
single Sonnet subject.

**Memory-critical (n=24/arm):**

| task | baseline | hooks_only | note |
|---|---|---|---|
| mc_error_envelope | 0/3 | **3/3** | replicates prior result |
| mc_audit_log | 0/3 | **3/3** | replicates prior result |
| cli_exit_contract | 0/3 | **3/3** | replicates prior result |
| cli_id_gotcha | 0/3 | **3/3** | replicates prior result |
| cli_path_guard | 3/3 | 3/3 | no headroom (baseline already solves) |
| mc_audit_log_terse | 0/3 | 0/3 | terse seed: agent misses the un-spelled-out endpoint |
| mc_repository_layer | 0/3 | 0/3 | agent leaves one direct `db.TASKS` access |
| conflict_good_belief | 0/3 | 0/3 | convention injected, new endpoint still uses bare HTTPException |
| **family** | **3/24 (0.12)** | **15/24 (0.62)** | |

Every hooks failure has the same verified signature: the manipulation check confirms the memory was
injected (826–1,303 chars), completeness lands at 0.75–0.8, and **exactly one acceptance criterion
fails, the same one across all three replicates**. Explicit, imperative memories deliver near-
perfectly; terse memories and conventions that require retrofitting existing code get *partially*
applied. That is a product finding (how memories should be written/expanded), not a delivery
failure — and it is now measured instead of averaged away.

**Distractor/adversarial (n=18/arm), current engine:**

| family | baseline | hooks_only |
|---|---|---|
| all 9 tasks | 18/18 (1.00) | 17/18 (0.94) |

The pre-belief harm cells (§3: near-miss 1.00→0.00) are re-tested and nearly eliminated:
`adv_nearmiss_web` 2/2→2/2, `adv_nearmiss_auth_scoped` 2/2→2/2, `conflict_nearmiss_belief` 2/2→2/2.
The one residual failure is `adv_nearmiss_auth` (2/2→1/2), the unscoped variant — reported as-is.

Methodology notes for this run: live capture hooks were active during trials (product-default);
activity logs show zero mid-session captures in sampled memory-critical trials and one SessionEnd
capture (after the measured work). A harness bug fixed just before this run (`install-hooks` writes
absolute paths; the preflight's literal match failed) would have silently zeroed every seeded-hooks
trial — the run only exists because the preflight now fails loudly.

## 1. Memory helps (seeded matrix — web app) **[committed: `results_data/runs_combined/`]**

5 tasks × 4 conditions × 3 replicates + 6 earned = **66 trials**, Sonnet/medium subject.

**Memory-critical family** (success requires a convention that lives only in memory):

| condition | solve | reads as |
|---|---|---|
| baseline | 0.00 | builds the endpoint, misses the cross-session convention |
| `mcp_only` | 0.00 | **agent never calls `recall`** — passive MCP delivers nothing |
| `earned_hooks` | 0.83 | the real capture→classify→hydrate loop (a bit lossy) |
| `hooks_only` | 1.00 | automatic hydration delivered the knowledge |
| `oracle` | 1.00 | knowledge pasted into the prompt (upper bound) |

**No-harm families** (`guardrail`, `memory_efficiency`, `distractor`): **1.00 across all conditions** —
injecting memory never broke a self-contained task or got misled by *irrelevant* distractor memories.
`hooks_only` solved at *no* turn/cost overhead vs baseline.

## 2. Partial generalization to a second program (CLI) **[committed: `results_data/runs_score_combined/`]**

Consolidated two-program run, baseline vs `hooks_only`, **40 trials** (n=2 per task × condition cell).

| CLI memory-critical task | baseline | hooks_only |
|---|---|---|
| `cli_exit_contract` (exit-code/stream contract) | 0.00 | **1.00** |
| `cli_id_gotcha` (id-reuse gotcha) | 0.00 | **1.00** |
| `cli_path_guard` (path-traversal concern) | 1.00 | 1.00 (no headroom) |

Memory delivers on a stdlib CLI — different convention *kinds* (exit codes, stdout/stderr, path safety)
than the web app's HTTP shapes — just as it does on the web app.

## 3. The failure mode: near-miss over-application **[committed / resolution runs not committed]**

Six adversarial tasks seed *deliberately wrong* memory; the correct behavior is to **ignore it**
(n=2 per task × condition cell).

- **4/6 safe** (`hooks == baseline`): the agent correctly ignored memory that **directly contradicts
  visible code** (wrong status values, wrong helper name, wrong file format, wrong field).
- **2/6 harm** — both the **near-miss** subtype (semantically adjacent, wrong subsystem):
  `adv_nearmiss_auth` 1.00 → **0.00** (applied an auth rule to a public endpoint),
  `adv_nearmiss_web` 0.50 → **0.00** (wrapped CLI output in a web envelope).

**Why it's hard:** near-miss memories are *semantically relevant* by construction, so retrieval-relevance
ranking can't filter them (confirmed: `hooks_relevance` fixed only the semantically-*distant* web case,
0→0.67, not the auth case). Header wording is a tradeoff, not a clean fix. The durable fix is upstream:
capture a convention's **scope** ("mutating endpoints" not "every endpoint"). **The report card's
`distractor_robust` criterion flags this automatically** (a true-positive backslide alarm).

**Resolved (per-memory scope, `92d449b`).** Conventions/concerns now carry optional
`appliesWhen`/`excludesWhen`, captured by the classifier and rendered as an explicit
*"Applies to / Does NOT apply to"* block. On the auth near-miss (baseline vs `hooks_only`, n=3): the
**over-broad** seed still breaks `GET /stats` (`hooks_only` **0/3**), but the **correctly-scoped** seed
(`adv_nearmiss_auth_scoped`) recovers to **3/3** — the injected context carried
`Does NOT apply to: aggregate or health/stats endpoints` and the agent left the public endpoint
unauthenticated. This is the upstream fix header text could not deliver; it shifts the residual risk
from *injection/retrieval* to *capture* (was the scope captured narrowly enough?), which is the lever
the classifier SCOPE RULE + the capture validator now target.

## 4. Real-loop (earned) performance — capture is the bottleneck **[not committed]**

Earned loop (warmup session → classifier → hydrate) on 4 memory-critical tasks, **12 trials**.

- **Baseline earned solve: 50%** (6/12). Misses split into **capture-fires-nothing** (~25%, Gemini
  variance) and **capture-incomplete** (`cli_id_gotcha`: fired 3/3 but solved 0/3 — captured "use a
  counter" but dropped the "never `max+1`" prohibition, so the agent didn't fix the existing bug).
- When capture works *and* is complete, the loop is strong (fired → solved). So value is bottlenecked
  at **capture**, not retrieval/hydration.

## 4b. MCP recall adoption (`mcp_only`) — fixed by an instruction, not tool design **[not committed]**

Under `mcp_only` the agent has the memory MCP server but **never calls `recall`** (0/12). The session-init
event confirms the server is *connected* and `mcp__hypermnesia__recall` is in the tool list — so it's
**pure initiation**, not awareness or registration. What does / doesn't move it (4 memory-critical tasks × 3):

| intervention | recall rate | solve rate |
|---|---|---|
| baseline `mcp_only` | 0/12 | 0/12 |
| strengthen tool *description* ("call this FIRST") | 0/12 | 0/12 |
| new task-oriented tool + JSON cards (`recall_for_task`) | 0/12 | 0/12 |
| MCP `initialize` `instructions` field (native) | 2/12 (17%) | 2/12 |
| **`CLAUDE.md` instruction** ("call `recall` before editing") | **12/12 (100%)** | **12/12 (100%)** |

**The whole `mcp_only` gap was one missing instruction.** Tool naming/description/schema are irrelevant
(the agent never reaches for the tool); a faint hint (MCP `instructions`) helps a little; a *prominent*
instruction the agent actually reads (`CLAUDE.md`) is a complete fix — the MCP *pull* path then delivers
seeded memory as well as the hooks *push* path.

**Shipped:** `hypermnesia install-memory-guide` (writes a marker-delimited recall instruction into
CLAUDE.md; user-global by default or `--project`; idempotent; `--uninstall`/`--dry-run`) plus the MCP
`initialize` `instructions` field (a free best-practice lift). **Eval-confirmed through the installed
path** (the harness invokes the real command): `mcp_only` recall 0/12 + solve 0/12 → `mcp_nudged`
recall **12/12** + solve **12/12**.

## 5. Eval-driven product improvements (all on `main`)

Each committed only after the eval moved the number; one was reverted when data showed it net-negative.

| commit | change | measured effect |
|---|---|---|
| `7cc741a`,`494d1a7` | classifier captures **literal contracts** | literal envelope captured 0/4 → 4/4 |
| `a263c79` | classifier captures the **anti-pattern** a fix replaces | anti-pattern capture 2/4 → 4/4 |
| `c275114` | **proactive-audit** hydration (supersedes `c8a4585`) | earned `cli_id_gotcha` 0/3 → 3/3, no near-miss regression |
| (reverted) `c8a4585` | relevance-only header | net-negative — made the agent too passive |
| (discarded) | capture-scope header tweak | no discriminating delta — not kept |
| `92d449b` | **per-memory scope** (`appliesWhen`/`excludesWhen`) captured + rendered "Does NOT apply to" | auth near-miss `hooks_only` **0/3 → 3/3** (scoped seed); over-broad seed stays 0/3 |
| `206bbfd` | **capture validation gate** (reject degenerate, cap-confidence weak, fallback re-extract) | deterministic + unit-tested; earned-only path, solve-delta below noise floor |
| `82be45e`…`5ebff45` | **evidence-based confidence** (`belief × freshness`) — see §7 | offline ROC-AUC 0.771→1.0, Brier 0.302→0.076; E2E near-miss `hooks_only` 0/3→3/3 |

After the `a263c79` + `c275114` fixes, a re-measure showed earned `cli_id_gotcha` **0/3 → 3/3**
(confirmed) and overall earned solve climbing from 50% toward ~75–90% (the rest is capture-reliability
variance at n=3, **not** a confirmed fix).

## 6. Report-card verdict

The summarizer emits predefined PASS/FAIL criteria. On the 66-trial web matrix: **all PASS**
(memory-critical uplift CI lower bound > 0; guardrail no-harm; distractor-robust; efficiency-gain).
On the two-program adversarial run: `guardrail_no_harm` PASS, **`distractor_robust` FAIL** (correctly
caught the near-miss harm), `memory_critical_uplift` FAIL (a small-n artifact — point estimate +0.67,
CI touches 0 because `cli_path_guard` has no headroom).

## 7. Evidence-based confidence (`belief × freshness`) **[not committed; superseded by §0 harm re-test]**

Confidence was a pure **recency** proxy: decay recomputed it from age and **discarded** the classifier
belief, the capture-quality verdict, and every application/audit outcome. Replaced with
`confidence = belief × freshness`, where belief is epistemic trust moved by two explicit paths (quality at
capture; outcomes — corroboration with an anti-gaming cap, application success, override/audit-drift).

- **Offline discrimination gate** (deterministic, no subject runs, labeled fixture): evidence-based vs
  age-only — **ROC-AUC 0.771 → 1.000**, **Brier 0.302 → 0.076**. (Synthetic fixture = mechanism gate.)
- **End-to-end conflict gate** (Sonnet/medium, n=3, baseline vs `hooks_only`): a *recent-but-wrong* memory
  that age-only injects (`adv_nearmiss_auth` `hooks_only` **0/3**) is **suppressed** by low belief
  (`conflict_nearmiss_belief` **3/3**) → near_miss_error **1.0 → 0.0**; a *good high-belief* memory is kept
  (`conflict_good_belief` base 0/3 → `hooks_only` **3/3**) → no solved regression.
- **Monotonic sanity** (unit): re-capture alone doesn't inflate belief; a successful application raises it;
  override/audit-drift drops it ≥40%.

This is a **second, independent** lever on the near-miss harm (§3): scope suppresses by *rendering* where a
rule applies; belief suppresses *low-quality* memories before they're injected. Live outcome signal is
currently the coarse audit proxy (`MemoryAuditor.recordOutcomes`); richer apply-outcome instrumentation and
decay-on-read are deferred hardening.

## Limitations

- Small synthetic apps; 2–3 replicates per cell. Absolute numbers are directional.
- Subjects are nondeterministic; efficiency and capture-reliability deltas are noise-limited at this n.
- `memory_critical` tasks are designed so baseline can't guess the held-out convention (that's the
  point) — the `oracle` condition bounds how much of the lift is "knowledge" vs "delivery".
- Earned mode brings the Gemini classifier into the loop (real variance).

## Reproducing

```bash
# Full seeded matrix + report card:
python3 evals/runner/run_matrix.py --replicates 3 --model sonnet --effort medium
python3 evals/reports/summarize.py            # prints the PASS/FAIL verdict block

# Two-program / adversarial slice, baseline vs hooks_only:
python3 evals/runner/run_matrix.py \
  --task evals/tasks/adv_nearmiss_auth.json --task evals/tasks/cli_id_gotcha.json \
  --condition baseline --condition hooks_only --replicates 3
```
