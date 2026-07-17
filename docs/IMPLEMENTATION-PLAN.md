# Hypermnesia — Implementation Plan

> **hypermnesia** *(n.)* — the condition of possessing an extremely detailed autobiographical
> memory. Here: giving Claude Code a durable, decaying memory of every project it touches.

A general, **local-first** re-implementation of a "Project Memory" system from an earlier private
app of the author's, driven by **Claude Code hooks** instead of a hosted assistant runtime.
Swift/SwiftUI, macOS-first.

This document is the forward plan, distilled from a study of the original private system's
design (not included in this repository).

---

## Locked decisions

| Fork | Decision |
|------|----------|
| **Architecture** | **Local-first, no server.** Everything on-device. Optional sync can be added later. |
| **Classifier** | **Pluggable adapter; default Gemini 3.5 Flash** via `GEMINI_API_KEY` (native JSON mode; faster + higher quality than a small headless model — and the original's Gemini-Flash family). Falls back to `claude -p` headless when no key. (`--bare`/`--json-schema` avoided — see `claude-p-headless-gotchas`.) On-device adapter later. |
| **App form** | **macOS menu-bar agent + main window.** iOS deferred. |
| **Scope** | **The whole system** — capture + decay + dedup + hydration + graph + browser/search/NL query. |

---

## What changes vs. the original

| Concern | Original | Hypermnesia |
|---------|----------------------|---------------|
| Capture trigger | App observed the hosted runtime conversation; `MemoryManager` debounced messages | **Claude Code hooks** (`Stop`/`SessionEnd`) hand off `transcript_path` + `cwd` |
| Classification | Server `/v1/memory/classify` (server held the model key, enforced quota) | **Local classifier adapter** (Gemini 3.5 Flash by default; `claude -p` fallback) |
| Storage | Cloudflare Durable Object per project (server SQLite) | **Local SQLite** (`~/Library/Application Support/Hypermnesia/memory.db`) with FTS5 |
| Decay | Server daily alarm + on-open `/stale` recalc | **In-app/daemon timer + on-launch recalc** (pure local computation) |
| Dedup | Server-side Jaccard | **Local** (same algorithm, ported) |
| Auth | App Attest assertions | **None** (local-only) |
| Hydration | Injected into runtime session prompts | **Hook `additionalContext`** at `SessionStart`/`UserPromptSubmit` |
| Project id | `owner/repo` (from GitHub source) | git remote URL, else normalized repo path |

---

## System architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Claude Code (the user's coding sessions)                                  │
│                                                                            │
│   SessionStart ──► hooks/hydrate  ──┐         ┌──► Stop / SessionEnd       │
│   UserPromptSubmit ─► hooks/hydrate │         │     hooks/capture          │
└──────────────────────────────────┬──┴─────────┴────────────┬──────────────┘
        additionalContext (memories)│                         │ enqueue {transcript_path, cwd, sha}
                                     ▼                         ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  hypermnesia CLI  (Swift executable; the hooks call this — fast, no GUI) │
│    hydrate · capture · classify · install-hooks · drain · doctor      │
└───────────────────────────────────────┬──────────────────────────────────┘
                                         │  uses
                                         ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  HypermnesiaKit  (platform-agnostic Swift package — the engine)          │
│                                                                            │
│   Models        MemoryNode · 7 typed payloads · MemoryEdge · DecayLevel    │
│   Store         SQLite (GRDB) — nodes, edges, sync_log, FTS5; project-scope │
│   Capture       transcript JSONL → conversation → Classifier → drafts       │
│   Classifier    protocol → ClaudeHeadless (default) · API · OnDevice        │
│   Decay         confidence = age-bucket × override-penalty; freshness levels│
│   Dedup         Jaccard + stopwords + git-SHA boost; 2 layers               │
│   Edges         infer typed relationships (implements/supersedes/affects…)  │
│   Hydration     select + format confirmed memories → additionalContext      │
│   GraphLayout   ForceDirectedLayout actor + layout modes                     │
└───────────────────────────────────────┬──────────────────────────────────┘
                                         │  observes the same store
                                         ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Hypermnesia.app  (SwiftUI, macOS menu-bar + window)                      │
│    Menu bar: capture toasts · drafts inbox · quick stats                    │
│    Window:  Graph · Browser · Health · Detail/Edit · NL Query               │
│    Drains the capture queue while running; LaunchAgent is the fallback.      │
└──────────────────────────────────────────────────────────────────────────┘
```

### Why a CLI *and* an app
The CLI makes the system **general**: hooks must return in milliseconds, so they only enqueue
work and (for hydrate) do a fast local read. Classification — which is slow — runs out-of-band:
drained by the menu-bar app when it's open, or by running `hypermnesia drain` when it isn't
(a `launchd` LaunchAgent remains a possible future addition). The app is the rich surface; the CLI guarantees capture works headlessly.

### Hook safety
- `capture` only appends `{session_id, transcript_path, cwd, git_sha, git_branch, ts}` to a queue
  table and exits 0 — never blocks a turn.
- The classifier runs `claude -p --bare …` so the capture hooks don't fire on the classifier's own
  session (no infinite loop). `--bare` skips hooks/MCP/skills.
- `hydrate` reads only the local store (no LLM) and prints `hookSpecificOutput.additionalContext`.

---

## Data model (ported faithfully from the original design)

7 memory types: `decision · convention · intent · fact · concern · backlog · codeRef`, each with a
typed payload. `MemoryNode` carries status (draft/confirmed), confidence, timestamps
(created/updated/lastValidated/deleted), version, lineage (supersedes/supersededBy), source
(conversationId/sourceQuote), git provenance (commitSha/branch), and decay counters
(timesApplied/timesOverridden). Typed edges: `implements, implemented_by, supersedes, creates,
affects, affects_intent, learned_from, mentioned_in, related_to`.

### Canonical constants (carried over verbatim)
- **Decay**: FRESH `<30d`→1.00, AGING `<90d`→0.74, STALE `<180d`→0.49, DORMANT `≥180d`→0.24;
  override-rate threshold 0.30 → ×0.50 penalty. Levels derived from confidence
  (≥0.75 fresh, ≥0.50 aging, ≥0.25 stale, ≥0.01 dormant, else obsolete).
- **Dedup**: Jaccard threshold 0.60, git-SHA boost +0.20, min word length 3, stopwords filtered.
- **Graph**: repulsion 15000, attraction 0.004, gravity 0.001, friction 0.85, ideal distance 180,
  cooling 0.95, max velocity 30.

---

## Historical backfill — "process previous sessions"

Claude Code already left a trail: every past session is a transcript JSONL under
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, each line stamped with `cwd`, `gitBranch`,
and an ISO `timestamp`. Hypermnesia can **replay that history** into memories so it starts out
already knowing your projects — and, crucially, with *correct decay*.

**Replay, not import.** Sessions are processed **per project, oldest → newest**, through the exact
same classify → dedup → store path as live capture. The differences:

- **Backdated timestamps.** A memory's `createdAt` / `lastValidatedAt` are set to the *session's*
  time, not now. Decay then computes confidence from `now − lastValidatedAt`, so a fact last seen
  200 days ago lands as DORMANT and one from last week as FRESH — automatically, no special-casing.
- **Reinforcement.** When a later session restates an existing memory (Layer-1 dedup match), we
  don't duplicate it — we bump its `lastValidatedAt` to the later session's time and increment
  `timesApplied`. Conventions you keep following stay fresh; one-off facts age out. This reproduces
  the validation/override state as if the system had been running the whole time.
- **Granularity.** Backfill classifies at whole-session granularity (vs. the live 5s-debounced window).
- *(Stretch)* chronological replay also enables **supersession detection** — a later decision that
  reverses an earlier one sets `supersededById`.

**Idempotent.** A `processed_sessions` table records `(session_id, project_id, processed_at)`;
re-runs skip processed sessions, and content dedup catches the rest.

**Two execution modes** (user-selectable; also defuses the `claude -p` subscription worry):
1. **Headless** — `hypermnesia backfill [--project <path>] [--since <date>] [--all] [--dry-run]`
   uses the configured classifier adapter (default `claude -p --bare`). For unattended bulk.
2. **Skill-driven** — a Claude Code skill (`/process-sessions`) runs *inside the current interactive
   session*, so the active Claude does the extraction (no separate headless call, no extra
   subscription draw) and persists each memory via `hypermnesia add` with backdated timestamps.

Both share the engine. The macOS app exposes the same as **"Process previous sessions…"** with a
dry-run preview (project, session count, estimated classifier calls + cost) before running.

> **Phase 1 store requirement this imposes:** the node-create path must accept *explicit historical
> timestamps* (`createdAt`, `lastValidatedAt`, `timesApplied`, `timesOverridden`) — not just "now" —
> and the schema needs a `processed_sessions` table.

## Build phases

> The user opted to build the whole system. Phases order the work; each ends on a working slice.

- **Phase 0 — Scaffold.** SPM workspace: `HypermnesiaKit` (lib) + `hypermnesia` (CLI). Design
  docs (done). README, `.gitignore`. App target wired (XcodeGen `project.yml` or Xcode).
- **Phase 1 — Models + Store.** Port the model layer; SQLite schema (nodes/edges/queue/sync_log/
  **processed_sessions** + FTS5); project-id resolution; CRUD with an **explicit-timestamp create
  path** (for backfill); unit tests. *(no networking — pure local)*
- **Phase 2 — Capture pipeline (the linchpin).** Transcript JSONL parser → conversation builder →
  `Classifier` protocol → `ClaudeHeadlessClassifier` (`claude -p --bare`, JSON schema) → dedup
  Layer 1 → drafts. Hook scripts + `install-hooks` + queue drain (`drain`). *Exit test: a real
  Claude Code session produces draft memories.*
- **Phase 3 — Decay + Dedup engines.** Confidence/freshness computation, on-launch + timer recalc,
  revalidation, application tracking; Jaccard dedup both layers; tests against the design constants.
- **Phase 4 — Historical backfill (session replay).** Enumerate `~/.claude/projects/**` transcripts;
  per-project oldest→newest replay with backdated timestamps + reinforcement + idempotency;
  `hypermnesia backfill` (with `--dry-run`) and the `/process-sessions` skill. *Exit test: a 6-month
  history backfills into a memory set whose decay levels match each session's age.*
- **Phase 5 — Hydration.** `hydrate` for `SessionStart`/`UserPromptSubmit`; selection + ranking +
  `formatMemoriesForPrompt`; emits `additionalContext`. *Closes the loop.*
- **Phase 6 — macOS app shell.** Menu-bar agent, capture toast, drafts inbox (confirm/dismiss),
  browser (filter/search), health (decay groups + bulk revalidate), **"Process previous sessions…"**,
  settings (classifier adapter).
- **Phase 7 — Graph.** Port `ForceDirectedLayout`; node shapes/colors, typed-edge rendering, layout
  modes, pan/zoom/select/drag; node detail + edit-in-place; lineage view.
- **Phase 8 — Search + NL query + packaging.** FTS5 search UI; local NL query over memories
  (classifier adapter); signed `.app`; LaunchAgent installer; `doctor`.

---

## Authoritative resolutions (shipped code wins; bugs to fix)

The design synthesis found many divergences between the original's
shipped code and its plans. Resolutions we build to:

- **Decay is confidence-band based, not calendar-label based.** A node's `confidence` is set by an
  age step-function (1.00/0.74/0.49/0.24 at the 30/90/180-day boundaries) × 0.5 if override-rate
  > 30%, clamped to `[0.01, 1.0]`; the UI buckets `confidence` into the 5 `DecayLevel` bands
  (≥0.75/≥0.50/≥0.25/≥0.01/else). Use band anchors **74/49/24**, not 75/50/25.
- **Only `decision`/`convention`/`intent` decay; `fact` never ages.** Carry this rule.
- **Dedup:** reason string `similar_confirmed_exists`; base Jaccard threshold **0.6**, *lowered to
  0.4 when git SHAs match* (this is the shipped behavior — not a "+0.2 boost"); no min-word-length
  filter. **Deliberately drop** `use/uses/using/project` from STOPWORDS (their inclusion silently
  weakened matches in the original).
- **Casing/timestamps:** snake_case for stored/read DTOs, camelCase for request DTOs, all timestamps
  **Unix-ms Int64**. (We control both sides now, but keep this contract internally consistent.)
- **`codeRef` is not produced by the LLM classifier** — it emits the other 6 types (or NONE). Code
  references come from tool/git anchoring (`PostToolUse` file edits + commit SHA).
- **Bugs to FIX (don't reproduce):** preserve `convention.examples`, `intent.behaviors`, and
  `codeRef.snippet` through capture *and* edit-save (the original dropped them); hydration must be
  able to include `intent`/`concern` (original defaulted to fact/convention/decision only); use a
  **stable `conversationId`** = the Claude Code `session_id` (original generated a throwaway UUID);
  resolve the polymorphic create-response so a dedup-skip (`{skipped:true,…}`) is decodable.
- **Momentum/departure** (shipped): a 7-day "departure snapshot" (recent messages, modified files,
  pending plan, AI summary) powers "Continue vs Start Fresh" on `SessionStart`. Port as an optional
  Phase 7+ feature.

## Open items to confirm as we go
- **Project scoping** — global vs per-repo memory DB. Plan: single DB, rows scoped by `project_id`,
  with a "global" project for cross-project facts.
- **Hydration trigger** — `SessionStart` (always) vs `UserPromptSubmit` (relevance-filtered). Plan:
  both, with a budget cap so we never flood context.
- **LaunchAgent vs app-only draining** — ship app-drains-queue first; add LaunchAgent in Phase 7.
