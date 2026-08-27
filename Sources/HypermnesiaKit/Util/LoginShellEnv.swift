import Foundation

/// The user's login-shell environment, for subprocesses that need more than launchd's bare env.
///
/// A Finder/Dock-launched app inherits launchd's minimal environment: PATH is
/// `/usr/bin:/bin:/usr/sbin:/sbin` and profile-exported variables (`ANTHROPIC_API_KEY`,
/// `GEMINI_API_KEY`, …) are absent. Passing that environment to a spawned classifier breaks every
/// setup that works fine in a terminal: an `apiKeyHelper` script in `~/.local/bin` exits 127
/// ("command not found"), an npm-shim `claude` can't find `node`, an API-key user gets
/// "Not logged in · Please run /login", and `$GEMINI_API_KEY` silently resolves to nothing.
///
/// The login shell is asked ONCE per process (same caching pattern as `CLIPath`'s lookup) and
/// merged gap-filling: values already present in the process environment always win — with one
/// exception. When this process runs *inside* a Claude Code session (hooks, the backgrounded
/// drain), the parent session's own `CLAUDE_*`/`ANTHROPIC_*` variables are stripped first
/// (`strippingParentClaudeSession`): they configure the parent's transport/auth, and inheriting
/// them breaks the spawned classifier under host-managed auth and gateway setups.
public enum LoginShellEnvironment {
    /// Shell bookkeeping that must not leak from the login shell: each would describe that
    /// throwaway shell, not this process (the subprocess cwd is set explicitly to
    /// `ClassifierWorkdir`, so a stale `PWD` would actively lie to scripts that trust it).
    ///
    /// Everything else fills in when absent — deliberately NO allowlist. `claude` setups depend
    /// on an open-ended set of variables: the `ANTHROPIC_*`/`CLAUDE_CODE_*` gateway families
    /// (code.claude.com/docs/en/gateways), proxy and CA overrides, and above all `apiKeyHelper`
    /// scripts (e.g. a Portkey `claude-gateway` helper), which are arbitrary shell that can read
    /// any variable the user exports (`PORTKEY_API_KEY`, a vault token, …). An allowlist would
    /// silently break the next such setup; gap-filling the user's own login environment into the
    /// user's own subprocess is safe by construction.
    static let excludedKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    static func isPreserved(_ key: String) -> Bool {
        !excludedKeys.contains(key)
    }

    /// Markers that this process was spawned from *inside* a Claude Code session (hook, MCP
    /// server, or the backgrounded drain those hooks launch).
    static let nestedSessionMarkers = ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID"]

    /// Variable families a parent Claude Code session injects into its subprocesses. They
    /// describe — and authenticate — *that* session, not this process, and a child `claude`
    /// spawned for classification must not inherit them: `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1`
    /// makes the child expect a host-injected token that is never exported to hooks ("Not logged
    /// in · Please run /login"), and the host's session-scoped `ANTHROPIC_CUSTOM_HEADERS` shadows
    /// the settings.json value gateway setups require (Portkey: "400 … x-portkey-config or
    /// x-portkey-provider header is required"). Dropping the whole families is safe: anything the
    /// user exports in their own shell profile is restored by the login-shell gap-fill, and the
    /// child CLI reads settings.json (`env`, `apiKeyHelper`) itself.
    static let parentSessionPrefixes = ["CLAUDE_", "ANTHROPIC_"]

    /// The process environment with the parent Claude session's variables removed — a no-op
    /// outside a nested-session context (GUI app, plain terminal), where those variables are the
    /// user's own.
    static func strippingParentClaudeSession(_ env: [String: String]) -> [String: String] {
        guard nestedSessionMarkers.contains(where: { !(env[$0] ?? "").isEmpty }) else { return env }
        return env.filter { key, _ in
            key != "CLAUDECODE" && !parentSessionPrefixes.contains { key.hasPrefix($0) }
        }
    }

    private static let captured: [String: String] = capture()

    /// The process environment with login-shell values filled into the gaps —
    /// the environment every classifier subprocess should be spawned with.
    public static func classifierEnvironment() -> [String: String] {
        merge(strippingParentClaudeSession(ProcessInfo.processInfo.environment), loginShell: captured)
    }

    /// A single variable, preferring the process environment (used for
    /// `$GEMINI_API_KEY` resolution, which must work in the GUI context too). Reads through the
    /// same parent-session strip as `classifierEnvironment()`, so lookups like `CLAUDE_CONFIG_DIR`
    /// answer for the child we would spawn, not for the parent session.
    public static func value(_ key: String) -> String? {
        let env = strippingParentClaudeSession(ProcessInfo.processInfo.environment)
        if let v = env[key], !v.isEmpty { return v }
        return captured[key]
    }

    /// Pure merge, separated for testability. Process values win; login-shell values fill gaps.
    /// PATH is the exception: the two are joined (process entries first, duplicates dropped) so
    /// resolved absolute tool paths keep working while login-shell directories become reachable.
    static func merge(
        _ processEnv: [String: String], loginShell: [String: String]
    ) -> [String: String] {
        var env = processEnv
        for (key, loginValue) in loginShell where isPreserved(key) {
            guard !loginValue.isEmpty else { continue }
            if key == "PATH" {
                let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
                let extra = loginValue.split(separator: ":").map(String.init)
                    .filter { !current.contains($0) }
                env["PATH"] = (current + extra).joined(separator: ":")
            } else if (env[key] ?? "").isEmpty {
                env[key] = loginValue
            }
        }
        return env
    }

    /// Ask the user's login shell for its environment, NUL-separated so values containing
    /// newlines can't corrupt the parse. Best-effort: any failure yields an empty dictionary,
    /// which makes the merge a no-op.
    ///
    /// The shell is spawned with a MINIMAL base environment, not the inherited one: in a hook
    /// context the parent Claude session's exported variables would pass through `-lc` untouched
    /// and be indistinguishable from profile exports — the gap-fill would reinject exactly what
    /// `strippingParentClaudeSession` removed. With a clean base (the same one Terminal.app gives
    /// a new login shell), the capture contains only what the profile itself exports.
    private static func capture() -> [String: String] {
        let processEnv = ProcessInfo.processInfo.environment
        let shell = processEnv["SHELL"] ?? "/bin/zsh"
        var base: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "TMPDIR"] {
            base[key] = processEnv[key]
        }
        let result = Shell.run(shell, ["-lc", "/usr/bin/env -0"], environment: base, timeout: 10)
        guard result.succeeded, !result.stdout.isEmpty else { return [:] }
        var env: [String: String] = [:]
        for entry in result.stdout.split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }
}
