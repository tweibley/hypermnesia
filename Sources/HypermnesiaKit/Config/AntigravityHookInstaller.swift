import Foundation

/// Installs/removes Hypermnesia's capture + hydrate hooks in Google Antigravity's `hooks.json`.
/// The Antigravity analogue of `HookInstaller`: user-global `~/.gemini/config/hooks.json` by
/// default, or a workspace's `.agents/hooks.json` via `projectPath`; idempotent; preserves any
/// other configured hooks.
///
/// Antigravity's hook schema differs from both Claude Code's and Cursor's: the file maps *hook
/// names* to per-event handler lists, so instead of marker-scanning shared event arrays we own a
/// single top-level `"hypermnesia"` key outright — install sets it, uninstall removes it.
/// Events: `PreInvocation` fires before every model call (the hydrate command itself injects only
/// at conversation start); `Stop` fires when the execution loop ends (capture + drain).
public enum AntigravityHookInstaller {
    /// The top-level hook name we own in `hooks.json`.
    static let hookKey = "hypermnesia"
    static let legacyHookKey = "hyperthymesia"   // pre-rename key: replaced on install, removed on uninstall

    public static func settingsURL(projectPath: String? = nil) -> URL {
        base(projectPath: projectPath).appendingPathComponent("hooks.json")
    }

    public static func isInstalled(projectPath: String? = nil) -> Bool {
        read(settingsURL(projectPath: projectPath))[hookKey] != nil
    }

    public static func install(binaryPath: String, projectPath: String? = nil) throws {
        let url = settingsURL(projectPath: projectPath)
        let settings = merged(into: try ConfigFile.readObject(at: url), binaryPath: binaryPath)
        try ConfigFile.writeObject(settings, to: url)
    }

    public static func uninstall(projectPath: String? = nil) throws {
        let url = settingsURL(projectPath: projectPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var settings = try ConfigFile.readObject(at: url)
        let removedCurrent = settings.removeValue(forKey: hookKey) != nil
        let removedLegacy = settings.removeValue(forKey: legacyHookKey) != nil
        guard removedCurrent || removedLegacy else { return }
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Settings with our hook merged in (for install + dry-run preview).
    public static func merged(into existing: [String: Any], binaryPath: String) -> [String: Any] {
        var settings = existing
        settings.removeValue(forKey: legacyHookKey)   // installing replaces a pre-rename hook
        let bin = ConfigFile.shellQuote(binaryPath)
        // Stop's stdout must stay pure JSON ({"decision":…}), so drain is backgrounded with its
        // output discarded — same shape as the Claude/Cursor capture command.
        settings[hookKey] = [
            "PreInvocation": [
                ["type": "command", "command": "\(bin) hydrate --client antigravity"],
            ],
            "Stop": [
                ["type": "command", "command": "\(bin) capture --client antigravity; (nohup \(bin) drain >/dev/null 2>&1 &)"],
            ],
        ]
        return settings
    }

    // MARK: - Helpers

    private static func base(projectPath: String?) -> URL {
        if let projectPath {
            return URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
                .appendingPathComponent(".agents", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    /// Tolerant read for state checks only (`isInstalled`) — a corrupt file just reads "not installed".
    private static func read(_ url: URL) -> [String: Any] {
        (try? ConfigFile.readObject(at: url)) ?? [:]
    }
}
