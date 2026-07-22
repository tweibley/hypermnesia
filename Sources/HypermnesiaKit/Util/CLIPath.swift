import Foundation

/// Resolves external CLI tools to an absolute path.
///
/// A Finder- or Dock-launched `.app` inherits launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// which excludes `~/.local/bin`, Homebrew, and npm prefixes — so a bare executable name fails to
/// launch there. Hook/daemon code already runs in a proper shell context and resolves bare names
/// fine, so the fast path below avoids spawning a login shell in that (hot) case and only falls back
/// to a login-shell lookup + known install locations when the tool isn't already reachable.
public enum CLIPath {
    /// Absolute path for `name`, or `name` unchanged if it can't be resolved (so callers still get a
    /// best-effort attempt). Checks the current PATH first, then a login shell, then `fallbacks`.
    public static func resolve(_ name: String, fallbacks: [String] = []) -> String {
        if name.contains("/") { return name }
        return find(name, fallbacks: fallbacks) ?? name
    }

    /// Absolute path for `name`, or `nil` when the tool genuinely isn't installed — the
    /// availability probe behind `Classifiers.autoKind`.
    public static func find(_ name: String, fallbacks: [String] = []) -> String? {
        // Fast path: already reachable on the current PATH (the CLI/hook context).
        if let onPath = which(name, shell: nil) { return onPath }

        // GUI context: ask the user's login shell, which sources their PATH.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let viaShell = which(name, shell: shell) { return viaShell }

        for fallback in fallbacks {
            let expanded = NSString(string: fallback).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        return nil
    }

    private static let claudeFallbacks = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]

    private static let agyFallbacks = [
        "~/.local/bin/agy",
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy"
    ]

    /// The `claude` CLI, resolved via PATH/login-shell with the usual install locations as fallbacks.
    public static func claude() -> String {
        resolve("claude", fallbacks: claudeFallbacks)
    }

    /// The `claude` CLI's path, or `nil` when it isn't installed.
    public static func findClaude() -> String? {
        find("claude", fallbacks: claudeFallbacks)
    }

    /// The Antigravity `agy` CLI, resolved via PATH/login-shell with install-location fallbacks.
    public static func agy() -> String {
        resolve("agy", fallbacks: agyFallbacks)
    }

    /// The `agy` CLI's path, or `nil` when it isn't installed.
    public static func findAgy() -> String? {
        find("agy", fallbacks: agyFallbacks)
    }

    private static func which(_ name: String, shell: String?) -> String? {
        let found: String
        if let shell {
            found = Shell.run(shell, ["-lc", "command -v \(name)"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            found = Shell.run("/usr/bin/env", ["sh", "-c", "command -v \(name)"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (!found.isEmpty && FileManager.default.isExecutableFile(atPath: found)) ? found : nil
    }
}
