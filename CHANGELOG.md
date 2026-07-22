# Changelog

Notable changes to Hypermnesia. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [SemVer](https://semver.org).

## [Unreleased]

## [0.5.0] — 2026-07-22

### Added

- **Antigravity's `agy` CLI is now a classifier backend.** If you use Google Antigravity, sessions
  can be classified through `agy --print` on your existing Google sign-in — no separate
  `GEMINI_API_KEY` needed, the same way `claude -p` rides your Claude subscription. Select it
  explicitly (Settings → Classifier → "Antigravity (agy)", or `--classifier antigravity` on
  `drain`/`backfill`/`classify`), or let **Automatic** find it: auto now resolves Gemini key →
  `claude` CLI → `agy` CLI, so existing setups are unchanged and `agy` only steps in when nothing
  else is available. Natural-language `ask` and Memory Dreams run on it too, a new
  "Antigravity model" field in Settings picks the `agy models` name (default
  `gemini-3.6-flash-medium`), and `hypermnesia doctor` now checks for whichever CLI your effective
  classifier actually uses.

## [0.4.0] — 2026-07-21

### Added

- **The `hypermnesia` terminal command now works out of the box.** Downloaded installs ship the
  CLI inside the app bundle, but nothing ever put it on PATH — so every documented command
  (`hypermnesia setup`, `install-cursor-mcp`, `install-antigravity-mcp`, …) failed with "command
  not found". The app now links the bundled CLI to `~/.local/bin/hypermnesia` on every launch,
  which also re-points the link after updates or app moves and never touches a from-source
  install it didn't create.
- **One-click PATH install for shells without `~/.local/bin`.** A new "Terminal command" row in
  Settings → Onboarding shows whether `hypermnesia` resolves in your shell; if `~/.local/bin`
  isn't on your PATH, it offers a VS Code-style install into `/usr/local/bin` behind the standard
  macOS administrator prompt. The system link chains through the `~/.local/bin` link, so the
  password prompt happens at most once, ever.

## [0.3.2] — 2026-07-21

### Changed

- **Marketing site redesign.** hypermnesia.app rebuilt with an interactive memory playground,
  CLI simulator, FAQ accordion, and live memory-graph visualization. Fonts remain self-hosted
  and analytics unchanged; no external requests were added. App behavior is unchanged — this
  release exists to ship the site with a matching version.

## [0.3.1] — 2026-07-21

### Fixed

- **Screenshot mode no longer starves hidden projects.** The `HYPERMNESIA_HIDE_PROJECTS` filter
  had leaked into the storage layer, so background ingest re-triage and daily maintenance silently
  skipped hidden projects while the env var was set. The store now separates truth
  (`allProjects()`) from presentation (`visibleProjects()`): data-integrity work always sees every
  project; only user-facing surfaces (sidebar, badge, ⌘K, dreams) apply the hide filter.
- **Release automation:** every release now deploys the site with the tagged version
  automatically; the deploy is a reusable, manually-dispatchable workflow
  (`gh workflow run deploy-site.yml`), pinned to wrangler 4 (v3 can't deploy assets-only
  Workers).

### Changed

- **Internal restructuring (no behavior changes beyond the fix above).** Classifier-captured file
  paths are normalized to repo-relative at capture, matching code refs; codeRef lifecycle policy
  is expressed as `MemoryType` capabilities instead of scattered type checks; the reality-check
  audit is read-only, with rename-repair an explicit prior step; the Settings model moved to its
  own file with MCP registration detection relocated into the kit; the three per-client hook
  installers share one binary-health protocol.

## [0.3.0] — 2026-07-20

### Added

- **Code-reference capture (opt-in).** Hypermnesia now produces `codeRef` memories
  deterministically from the file edits observed in transcripts — no LLM involved — fulfilling the
  classifier's long-standing "captured separately from file edits" promise. One aggregated draft
  node per repo-relative path, confirmed by sighting accrual; paths are normalized per client
  dialect (Claude Code, Cursor, Antigravity), filtered through a denylist plus your repo's own
  `.gitignore`, and repaired across git renames by the memory auditor. Code refs stay out of
  SessionStart ranking and instead annotate linked memories or surface when a prompt mentions the
  file. Off by default — enable in Settings → Capture (`HYPERMNESIA_CODE_REFS` overrides for dev).
- **Night-sky constellation graph.** The graph view was unusable past ~60 nodes; it's now a
  single-canvas renderer that stays legible at scale: importance-driven node sizing and label
  priority, greedy label decluttering, named cluster constellations with soft hulls, curved edges
  that fade with zoom, 2-hop click-to-focus, an auto-framing camera, and twinkle on fresh memories
  (respects Reduce Motion). Dense graphs drop the chronological session chains so semantic
  clusters stay readable.
- **Site: real-app screenshot tour** — six screenshots of Hypermnesia holding this repository's
  own memory, generated reproducibly by two env-gated dev harnesses
  (`HYPERMNESIA_HIDE_PROJECTS`, `HYPERMNESIA_SCREENSHOT_DIR`).

### Fixed

- **MCP registration no longer reports a false error.** `claude mcp list` live-probes every
  configured MCP server, so one slow server (or a cold `npx` fetch) timed the check out and a
  successful registration showed "Could not read MCP server list". The app now falls back to the
  registration record itself and shows "Registered — connection check timed out" instead.
- **GitHub release notes** now use the version's curated CHANGELOG section as the release body
  instead of an empty auto-generated one.

## [0.2.1] — 2026-07-20

Bug-fix release: 38 user-facing issues surfaced by an adversarial multi-agent audit, plus a
cross-client hook-health follow-up. No schema or config migrations; 49 new regression tests
(310 → 359).

### Fixed

- **Capture no longer silently dies when the app moves.** Hooks record an absolute path to the
  bundled CLI, so moving or translocating Hypermnesia.app left capture and hydration dead while
  everything still reported "installed ✓". Install state now verifies the recorded binary exists
  and is executable; `doctor` and Settings report the broken install and offer a reinstall that
  re-points the hooks — for Claude Code, Cursor, and Antigravity.
- **Obsolete memories no longer resurface.** The retroactive supersede sweep rewrote a stale
  in-memory copy of a middle-generation memory, un-retiring it so both it and its replacement
  were injected into every session. It now writes from live state and skips already-retired nodes.
- **Dream skills are correctly scoped per project.** Install / update / uninstall / usage keyed on
  slug alone, so installing a same-named skill into a second project rewrote the first project's
  copy and Uninstall could delete another project's files. All lookups now key on
  (slug, scope, project); update-with-diff honors the scope you picked; Uninstall targets this
  project's copy.
- **Recall no longer returns nothing for ordinary questions.** The keyword fallback required every
  query token to match (FTS5 implicit AND); it now uses OR ranking.
- **Capture reliability:** a transient transcript read error no longer permanently seals a session;
  `backfill` reports per-session failures instead of an indistinguishable "0 memories"; sessions
  with a large early attachment are read fully; a re-observed rule is no longer absorbed into a
  superseded memory.
- **MCP:** `remember` reinforces an existing memory instead of piling up duplicate drafts; `ask`
  surfaces backend failures as errors; the stdio loop handles requests concurrently so a slow `ask`
  no longer blocks other tool calls.
- **Dreams:** "Dream now" is gated against the nightly pass (no double-billed, half-lost runs);
  re-running a dream preserves installed-skill state and report-back links; user-scope skill usage
  is counted across all projects.
- **App:** the memory list is no longer capped at 500 rows; login-shell probes moved off the
  launch/main thread with timeouts (no beachball at startup or when registering the MCP server);
  draft-review keyboard shortcuts advance to the next draft; a notch card for a tmux/ssh session no
  longer no-ops-and-dismisses; "agent finished" pops aren't starved by disabled attention pops; the
  Brain MRI and Storage view no longer stutter or block the UI.
- **"Remove all memories"** now also clears the Dream Journal; the confidence override rate no
  longer reads over 100%.
- **CLI / site:** `doctor` checks the actually-configured classifier; `backfill --project … --all`
  is rejected as contradictory; config writes preserve symlinked settings files; the release build
  fails rather than ship without its Sparkle appcast; the site privacy copy discloses analytics
  accurately.

## [0.2.0] — 2026-07-20

### Added

- **Memory Dreams**: after your Mac wakes and goes idle, Hypermnesia consolidates recent
  Claude Code, Cursor, and Antigravity sessions into an evidence-backed Dream Journal —
  typed epiphanies that lead with their receipts (verbatim transcript quotes, cited
  memories, side-by-side contradictions with one-tap supersede), draft memories through
  the normal review inbox, and skill proposals with a full lifecycle: staged `SKILL.md`
  preview/edit, install into detected skill layouts only (`.claude/skills`,
  `.cursor/skills`, `~/.gemini/skills`), update-with-diff (never clobbers), one-tap
  uninstall, and watermark-based usage report-backs ("used twice since Tuesday" — or
  honestly, not at all). One morning digest across all projects, a quiet "Dreamed" notch
  chip while unread, a skippable REM replay on the brain MRI in a night palette, and a
  stats-only share card. Consent-shaped throughout: off by default with a cost estimate
  shown, per-night call cap, idle/battery/return-to-keyboard guards, per-night calls and
  estimated cost recorded in the journal — and no dream is better than a bad dream:
  nights that don't clear the quality gate are logged as quiet, never padded. Manual
  pass: `hypermnesia dream [--project P] [--days N]`; the first dream runs right after
  "Process previous sessions", priced into its consent dialog. Inspired by
  [gemini-dreams](https://github.com/jswortz/gemini-dreams) by
  [@jswortz](https://github.com/jswortz) — thank you.

### Deprecated

- **Homebrew cask**: the `tweibley/tap` cask no longer receives version bumps — the
  [direct download](https://github.com/tweibley/hypermnesia/releases/latest/download/Hypermnesia.zip)
  (signed & notarized, with built-in Sparkle auto-update) is now the sole install channel.
  Existing brew installs of 0.1.1 or later keep updating themselves in place via the in-app
  updater, so no action is required. To stop Homebrew tracking the app entirely, run
  `brew uninstall --cask tweibley/tap/hypermnesia` and reinstall from the direct download —
  your memories, settings, and hooks are untouched (avoid `--zap`, which deletes local data).

## [0.1.1] — 2026-07-18

### Added

- **Auto-update**: direct-download installs now keep themselves current via
  [Sparkle](https://sparkle-project.org) — a signed `appcast.xml` is published with every release,
  and the app offers "Check for Updates…" in the app menu and the menu-bar popover. Background
  checks are gentle: no surprise dialogs, just an "Update available" banner in the popover.
  Homebrew installs keep updating via `brew upgrade`, as before.
- **About update status**: Settings → About now shows updater state at a glance
  ("Unavailable in this build", "No pending update", or "Update available: x.y.z"),
  plus a one-click "Check now" action when updater wiring is active.
- **Notch status**: live session status pops from the Mac's notch (top-center on displays
  without one) — when an agent finishes its turn, and when a Claude Code session needs you
  (permission request / waiting for input). One click jumps back to that exact session: the
  precise iTerm2/Terminal tab via its tty, the hosting IDE window via its URL scheme, or the
  host app. Cards auto-hide while you're already in that session's app; attention cards persist
  up to 15 minutes, finished pops fade after 90 seconds. New `Notification` + `session-event`
  hooks feed a local JSONL event log the app watches; configurable under Settings → Notch, with
  a one-click hook update for installs that predate the feature. Preview it any time with
  `hypermnesia notch-demo` (or Settings → Notch → Preview cards) — sample cards ride the real
  pipeline, including click-to-jump-back into the terminal that ran the command.
- **Working state**: the notch also shows agents *while they run* — a slim "N working" strip
  (never a pop) that unfolds on hover into one row per running session with the project, what it's
  chewing on, and elapsed turn time; click a row to jump there. Turn starts are stamped by
  Claude Code's `UserPromptSubmit`, Cursor's `beforeSubmitPrompt`, and Antigravity's
  `PreInvocation`; throttled per-tool heartbeats (`PostToolUse`, `afterFileEdit` /
  `afterShellExecution`, `PreInvocation`) keep long turns honest and expire dead ones — and the
  moment you approve a stalled permission prompt in its terminal, the heartbeat clears the stale
  "needs your input" card. A Cursor stop you aborted yourself now clears silently instead of
  popping "finished". Toggleable under Settings → Notch ("Show agents while they work").
- **Durable capture queue**: hooks snapshot the host transcript into Application Support before
  enqueueing, so Claude/Cursor/Antigravity deleting their file after the hook returns cannot strand
  the out-of-band drain. Snapshot failure falls back to the host path (retryable) instead of
  dropping the session; snapshots are removed only when no surviving queue row still needs them.
- **Clear failed captures**: `hypermnesia drain --clear-failed` and a **Clear failed** button on the
  queue banner remove terminal queue failures without touching memories or host transcripts.
- **Queue health**: the app banner and `hypermnesia doctor` report pending / processing / retrying /
  failed counts plus the latest failure reason.
- **Hook drain diagnostics**: background SessionEnd drains append to a bounded rotating log at
  `~/Library/Logs/Hypermnesia/drain.log` instead of discarding stdout/stderr.
- **Consented backfill**: "Process previous sessions" proposes candidates first; nothing is enqueued
  until you confirm. Confirmed historical sessions keep `source: backfill` through the shared drain.
- **CLI contract tests**: a new test target runs the `hypermnesia` binary as a subprocess to lock
  hook/MCP command contracts.
- **App icon**: packaged `.icns` wired into `make-app` / `release` so the dock and Finder show a
  proper icon.

### Fixed

- Bulk draft confirm now runs the same triage path as single confirm (supersession + near-duplicate
  purge), so batch actions no longer skip cleanup.
- Maintenance audit outcomes are recorded with the findings they produced (no more empty-array
  recording).
- Historical reinforcement uses the transcript's end time for backfill; live capture still uses now.
- Transcript parsing skips corrupt/truncated lines instead of discarding an entire healthy session;
  wholly undecodable backfill sessions are sealed so they are not re-proposed forever. Missing
  *managed* snapshots fail immediately; missing host paths stay retryable.
- Capture-queue drain, prune, and clear-failed no longer delete a `sha256(sessionId)` snapshot
  still referenced by another row (or refreshed since the deleting pass began). Re-enqueue resets
  the retry budget.
- Notch frontmost suppression is transient (multi-tab same host app); release builds include Apple
  Events entitlement + usage string so click-back works under hardened runtime. `quickTitle` trims
  a byte-capped truncated final line so notch cards get real titles.
- Hook installs prefer the app-bundled CLI (version-matched) over a stale PATH binary; background
  drain commands restore a shell redirect into `drain.log`. Confirmed backfill snapshots off the
  MainActor so large histories do not beachball the UI.
- Config load/save is typed and atomic (0600 temp + rename); Settings surfaces persistence errors
  instead of silently falling back.

### Changed

- Release workflow verifies the tagged SHA and runs the Swift test suite before signing credentials
  are used.
- Capture-queue rows record live vs backfill `source`; uncapped store readers remove correctness
  caps that truncated large corpora during audit/embed paths.

## [0.1.0] — 2026-07-15

First public release.

### Capture → Classify → Curate → Decay → Hydrate

- Automatic session capture for **Claude Code**, **Cursor**, and **Google Antigravity** via hooks;
  incremental live classification with a shared out-of-band queue, plus `backfill` (per-repo or
  `--all`, every client) with backdated decay.
- Pluggable classifier: Gemini (recommended, via your API key) or `claude -p`; a validation gate
  drops degenerate captures and one focused retry recovers missed extractions.
- Draft review gate: captured and `remember`-written memories are drafts until confirmed in the
  app; near-duplicates reinforce the original instead of piling up, and repeat sightings can
  auto-confirm.
- **Conflict-aware revisions:** a captured memory that contradicts an existing one (a reversed
  decision, a fact whose value changed) links it at capture and supersedes it on confirm — superseded
  memories drop out of injection, search, and Ask.
- Evidence-based confidence (belief × freshness) with reality-check audits (deterministic file
  checks, optional LLM deep check) feeding outcome signals back into belief.
- Hydration at session start and per-prompt by relevance (Claude Code), session/conversation start
  (Cursor, Antigravity), with prompt-injection hardening and budget caps.

### Surfaces

- macOS menu-bar + window app: review inbox, full-text + semantic search, force-directed graph,
  Health, Trends, live MRI activity view, natural-language Ask, navigable revision chains.
- Review workflow: undoable triage (transient Undo bar, ⌘Z), multi-select batch confirm/dismiss,
  an "x of n" progress counter through the draft queue, and a side-by-side NOW/NEW comparison on
  drafts that revise an existing memory.
- First run: a get-started screen and actionable empty states (set up capture, process previous
  sessions, or load sample data — all in-app); with hooks installed, a waiting state that turns
  into a one-time celebration when the first capture lands. The menu-bar icon shows a count when
  drafts await review anywhere, with an opt-in macOS notification per capture pass.
- Payoff visibility: the menu bar shows the last time memories were injected into a session, and
  each memory's inspector shows when it last went into one.
- Navigation: ⌘K quick-open across every project, ⌘1–⌘6 view switching, drafts grouped by the
  capture session they came from, and Ask with recent-question history and copy-answer.
- Autonomy: confident captures auto-confirm (revisions, weak captures, and agent `remember`
  writes still wait for review — see SECURITY.md); a daily per-project maintenance pass audits
  reality and reconciles contradictions, and a retroactive conflict sweep retires the older of
  two conflicting confirmed memories (newer-wins, with Restore as the escape hatch).
- Observability: an activity Feed view (⌘6) lists every injection, capture, recall, audit
  outcome, and supersede with resolved memory titles. Launch-at-login keeps it all running.
- Session momentum: the last session's working state (request, files in flight, an unanswered
  question) is snapshotted at session end and injected at the next session start (7-day TTL,
  own toggle) — the agent picks up where you left off. CLAUDE.md import bootstraps draft
  memories from conventions teams already wrote down, and related files/commits deep-link to
  the local editor or a commit-pinned GitHub permalink.
- Brain MRI: memories cluster into labeled per-type regions with drafts dashed and superseded
  memories hollow; graph edges show as faint filaments and a supersede plays as a signal
  traveling from the retired memory to its replacement. Space/←/→ drive replay, the scrubber
  shows wall-clock time, nodes and the ticker click through to the list, and rendering pauses
  when the window is hidden (with Reduce Motion honored).
- Editing & sharing: type-specific payload fields are editable in place, and any memory can be
  copied as portable Markdown for PRs or CLAUDE.md files. The details inspector dismisses with
  ✕ or Escape.
- CLI: `setup` one-shot install, memory management (`list` / `show` / `delete` / `export`,
  `--json`), `recall`/`ask`, `audit`, `backfill`, `drain --dry-run`, and installers for hooks and
  MCP on both clients (all with `--uninstall` inverses and `--dry-run`).
- MCP server (`recall` / `ask` / `remember`) usable from any MCP client.

### Storage & privacy

- Everything local: GRDB/SQLite with FTS5 at `~/Library/Application Support/Hypermnesia/`;
  on-device Apple embeddings; no telemetry. Only classifier traffic leaves the machine — see
  [SECURITY.md](SECURITY.md).
