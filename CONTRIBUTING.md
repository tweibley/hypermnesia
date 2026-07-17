# Contributing

Thanks for your interest! Small, focused PRs are the easiest to review.

## Building and testing

```bash
swift build          # engine + CLI (.build/debug/hypermnesia)
swift test           # full suite — should pass before any PR
bash Scripts/make-app.sh   # the macOS app bundle
```

Requires macOS 14+ and a Swift 6 toolchain. The eval harness under `evals/`
has its own [README](evals/README.md) and needs a Claude Code install (and
API budget) to run — it is not part of `swift test`.

## Guidelines

- **Tests:** changes to `HypermnesiaKit` should come with tests
  (`Tests/HypermnesiaKitTests/`). The suite is fast (<1s) — run it often.
- **Commits:** conventional-commit format (`type(scope): subject`), e.g.
  `fix(capture): handle empty transcripts`.
- **Install/uninstall symmetry:** anything that writes user config (hooks,
  permissions, MCP registration) must have an uninstall that exactly reverts
  it, a `--dry-run`, and a round-trip test.
- **Privacy:** no new network calls or telemetry. Anything that would send
  data anywhere must be opt-in and documented in [SECURITY.md](SECURITY.md).

## Reporting bugs

Open a GitHub issue with `hypermnesia doctor` output and reproduction steps.
For security issues, see [SECURITY.md](SECURITY.md).
