# Changelog

Notable changes to Hypermnesia. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [SemVer](https://semver.org).

## [Unreleased]

### Added

- **Auto-update**: direct-download installs now keep themselves current via
  [Sparkle](https://sparkle-project.org) — a signed `appcast.xml` is published with every release,
  and the app offers "Check for Updates…" in the app menu and the menu-bar popover. Background
  checks are gentle: no surprise dialogs, just an "Update available" banner in the popover.
  Homebrew installs keep updating via `brew upgrade`, as before.
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
