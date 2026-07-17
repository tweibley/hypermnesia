# Security

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories — on this repository, go to
**Security → Advisories → Report a vulnerability** — rather than opening a public issue. You should
hear back within a week.

## What Hypermnesia stores and where

- Everything lives locally under `~/Library/Application Support/Hypermnesia/`
  (`memory.db`, `config.json`, the capture queue, embeddings, an activity log).
  The directory is created `0700`; the database, activity log, and `config.json`
  (which may hold a Gemini API key) are `0600`.
- Captured session transcripts routinely contain sensitive material — code,
  file paths, anything you pasted into a session. Treat the support directory
  accordingly, especially if you relocate it with `HYPERMNESIA_SUPPORT_DIR`.

## What leaves your machine

There is no telemetry. The only network calls go to the classifier/completer
you configure (Gemini via your API key, or `claude -p` via your existing Claude
session): transcript text for classification, and stored memory summaries plus
your question for `ask` and `audit --deep`.

## Trust model: memories steer agents

Hypermnesia's whole purpose is to inject stored memories into future agent
sessions — which makes the memory store an **influence channel**. A memory that
says "always do X" will nudge every later session in that project toward X.
This is inherent to any agent-memory system; the mitigations here are:

- **Human review gate, applied where judgment is needed.** Memories from the
  MCP `remember` tool, *revisions* (a capture that would retire an existing
  memory), and weak or low-confidence captures always land as **drafts**.
  Drafts are never injected or recalled; you confirm them in the app's review
  inbox first. Only confirm memories you actually agree with — a transcript
  that processed untrusted content (a malicious repo's README, pasted web
  output) can propose misleading drafts.
- **Auto-confirmed captures (default on, opt-out).** Clean, fresh,
  high-confidence hook captures skip the inbox and go live immediately —
  fewer drafts to triage, at the cost of injecting classifier output your
  eyes never saw. If your sessions routinely process untrusted content,
  turn off *Settings → Capture → Auto-confirm confident captures* to route
  every capture through review again.
- **Read-only pre-approval.** The installers pre-approve only `recall` and
  `ask` (read-only). `remember` always stays behind the per-session permission
  prompt.
- **Scoped injection.** Only confirmed, non-superseded memories at or above a
  confidence floor are injected, and only for the project they belong to.

If you point the tools at a project or memory store you didn't build, treat
its memories like you would its code: read before you trust.
