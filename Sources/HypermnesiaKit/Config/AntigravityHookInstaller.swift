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
        // output redirected to the private bounded diagnostic log. The notch status emitter is its
        // own handler (each gets its own stdin copy) and answers its own decision.
        // On PreInvocation it doubles as the working-state heartbeat (throttled in the CLI, since
        // PreInvocation fires before every model call).
        settings[hookKey] = [
            "PreInvocation": [
                ["type": "command", "command": "\(bin) hydrate --client antigravity"],
                ["type": "command", "command": "\(bin) session-event --client antigravity"],
            ],
            "Stop": [
                ["type": "command", "command": HookDrainDiagnostics.captureCommand(
                    binaryPath: binaryPath, client: "antigravity")],
                ["type": "command", "command": "\(bin) session-event --client antigravity"],
            ],
        ]
        return settings
    }

    /// Hooks are installed but predate some notch status event (no `session-event` handler on
    /// Stop or PreInvocation) — the Settings UI offers a one-click re-install.
    public static func needsReinstall(projectPath: String? = nil) -> Bool {
        guard let ours = read(settingsURL(projectPath: projectPath))[hookKey] as? [String: Any] else { return false }
        return !["Stop", "PreInvocation"].allSatisfy { event in
            ((ours[event] as? [[String: Any]]) ?? [])
                .compactMap({ $0["command"] as? String })
                .contains { $0.contains("session-event") }
        }
    }

    /// Recorded hook binaries (the app-bundle CLI path baked into each handler command). Detects a
    /// dead install after the app is moved/translocated: `isInstalled` stays true but the binary no
    /// longer exists, so every Antigravity hook exec silently fails. The whole subtree under our
    /// (current or pre-rename) hook key is ours, so every command in it is scanned.
    public static func installedBinaryPaths(projectPath: String? = nil) -> [String] {
        let root = read(settingsURL(projectPath: projectPath))
        var paths: [String] = []
        for key in [hookKey, legacyHookKey] {
            guard let ours = root[key] as? [String: Any] else { continue }
            for handlers in ours.values {
                guard let array = handlers as? [[String: Any]] else { continue }
                for entry in array {
                    guard let command = entry["command"] as? String,
                          let path = HookInstaller.recordedBinaryPath(inCommand: command),
                          !paths.contains(path) else { continue }
                    paths.append(path)
                }
            }
        }
        return paths
    }

    /// Recorded hook binaries that no longer exist / aren't executable — the hooks are present in
    /// hooks.json yet every session's hook exec fails silently. Empty when nothing needs repair.
    public static func missingBinaryPaths(projectPath: String? = nil) -> [String] {
        installedBinaryPaths(projectPath: projectPath).filter {
            !FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// True when hooks are recorded but at least one points at a binary that's gone — a broken
    /// install that `isInstalled` reports as healthy.
    public static func hasMissingBinary(projectPath: String? = nil) -> Bool {
        !missingBinaryPaths(projectPath: projectPath).isEmpty
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
