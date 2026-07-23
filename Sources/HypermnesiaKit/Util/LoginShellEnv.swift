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
/// merged gap-filling: values already present in the process environment always win, so hook/CLI
/// contexts (which already have a real environment) are unchanged.
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

    private static let captured: [String: String] = capture()

    /// The process environment with login-shell values filled into the gaps —
    /// the environment every classifier subprocess should be spawned with.
    public static func classifierEnvironment() -> [String: String] {
        merge(ProcessInfo.processInfo.environment, loginShell: captured)
    }

    /// A single variable, preferring the process environment (used for
    /// `$GEMINI_API_KEY` resolution, which must work in the GUI context too).
    public static func value(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
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
    private static func capture() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = Shell.run(shell, ["-lc", "/usr/bin/env -0"], timeout: 10)
        guard result.succeeded, !result.stdout.isEmpty else { return [:] }
        var env: [String: String] = [:]
        for entry in result.stdout.split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }
}
