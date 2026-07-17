# Hypermnesia — Feature Roadmap

Ten features to raise the system's utility, grounded in the current architecture (capture → classify
→ decay → dedup → hydrate, with a macOS app, CLI, and Claude Code hooks). Ordered roughly by leverage.

Status legend: ✅ done · 🔨 in progress · 🔜 next · 💡 idea

---

## Better retrieval & correctness (the core value)

### 1. Semantic retrieval via embeddings ✅
**Done.** On-device sentence embeddings (`AppleEmbedder` via `NLEmbedding`, free/offline) stored as
Float vectors (`memory_embedding` table), ranked by cosine (`SemanticIndex`). Wired into per-prompt
hydration (`MemoryHydrator.relevantContext`) and NL query (`MemoryQA`), with an FTS fallback and lazy
indexing. Verified: a query sharing *no keywords* with a memory still retrieves it. *(Follow-up: use
it for the app's browser search too — still FTS; and an optional Gemini-embeddings adapter.)*

### 2. Reality-check audits ✅
**Done.** `MemoryAuditor` checks memories against the live repo: related files that no longer exist
(`missingFile`) and files changed since the memory's commit (`changedSinceCapture`, via `git diff`),
plus optional LLM verification (`--deep` → `outdated`). Flagged memories take a confidence penalty so
they drop in the decay model and surface in **Health** for review. CLI `audit --project P [--deep]
[--apply]` and a "Reality check" button in the app's Health view. +3 tests.

### 3. Two-way CLAUDE.md sync ⏸️ (deferred — unsure if needed)
**Value:** Claude Code already reads `CLAUDE.md`. Makes memories work without hooks, git-versioned,
and **team-shareable** for free — the lightest path to shared memory.
**Sketch:** Maintain a generated `## Project Memory` block in the repo's `CLAUDE.md` from confirmed
conventions/decisions; ingest existing `CLAUDE.md` as seed memories. `hypermnesia sync-claude-md`.
**Effort:** Low–Medium.

## Cut curation friction (adoption)

### 4. Frictionless triage ✅
**Done.** **Reinforcement auto-confirm** — a draft captured across N sessions confirms itself (dedup
now *reinforces* the existing memory instead of dropping the duplicate; configurable, default 2).
**Bulk actions** — Confirm/Dismiss all drafts from the toolbar. **Keyboard-fast review** — ⌘↩ confirm
/ ⌘⌫ dismiss in the inspector, auto-advancing to the next draft. **In-place edit** of title/summary
(re-indexes the embedding). +3 tests. *(Follow-up: merge / split.)*

### 5. Pinned & protected memories 💡
**Value:** Critical invariants ("money is integer cents") should never decay and always hydrate.
**Sketch:** A `pinned` flag (new column) → excluded from decay, force-included in hydration, badge in UI.
**Effort:** Low.

## Extend reach & generality

### 6. Global, cross-project memory 💡
**Value:** Much of your taste is universal, not per-repo. Your conventions follow you everywhere.
**Sketch:** The model already reserves `__global__`. Surface a **Global** project, "promote to global"
action, and hydrate global + project together.
**Effort:** Low–Medium.

### 7. MCP server ✅
**Done.** `hypermnesia mcp` runs a stdio JSON-RPC MCP server (`MCPHandler`) exposing three tools to
any MCP client (Cursor, Claude Desktop, …): **recall** (semantic memory retrieval), **ask** (NL
query), and **remember** (store a memory). Verified over a live stdio handshake. +4 tests.

## Anchor to code & show value

### 8. Code-anchored "decision blame" 💡
**Value:** Like `git blame`, but for *why*. Ask "what's the history of `auth.swift`?" and get the
decisions/concerns about it; inject those when a session touches those files.
**Sketch:** Index memories by file/symbol (already have `relatedFiles`, `commitSha`); a lookup +
file-scoped hydration.
**Effort:** Medium.

### 9. Provenance & real usage tracking 💡
**Value:** Builds trust ("used 6×, last applied Tuesday") and improves decay accuracy.
**Sketch:** "Open original session" (jump to the transcript turn via `conversationId`/`sourceQuote`);
wire `timesApplied`/`timesOverridden` (in schema, unused) to a Stop/PostToolUse signal of whether
injected guidance was followed.
**Effort:** Medium.

### 10. Lineage & auto-supersession 💡
**Value:** See how the project's thinking evolved (REST → GraphQL) — gold for onboarding.
**Sketch:** Auto-detect when a new decision reverses an old one and link via the existing
`supersedesId`/`supersededById`; per-decision timeline view; populate the graph's `supersedes` edges.
**Effort:** Medium.

---

## Build order
1 (semantic retrieval) → 2 (audits) make injected memories both *relevant* and *true*. **4** is the
adoption unlock. **3** and **7** are the highest-leverage moves toward "general."

**Quick wins:** live DB-watching (views auto-update, no manual Refresh) · menu-bar badge + weekly
digest surfacing captured concerns/bugs.
