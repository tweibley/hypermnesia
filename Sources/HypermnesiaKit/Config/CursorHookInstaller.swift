import Foundation

/// Installs/removes Hypermnesia's capture + hydrate hooks in Cursor's `hooks.json`. The Cursor
/// analogue of `HookInstaller`: user-global `~/.cursor/hooks.json` by default, or a project's
/// `.cursor/hooks.json` via `projectPath`; idempotent; preserves any other configured hooks.
///
/// Cursor's hook schema differs from Claude Code's:
///   - file shape is `{ "version": 1, "hooks": { "<event>": [ { "command", "type":"command" } ] } }`
///     (a *flat* array of command entries per event, not Claude's nested `{ "hooks": [...] }`);
///   - event names are camelCase (`sessionStart`, `stop`, `sessionEnd`);
///   - the hooks call the CLI with `--client cursor` so it reads Cursor's input/output schema.
///
/// Cursor has no per-prompt context-injection hook, so hydration is `sessionStart`-only.
public enum CursorHookInstaller: HookInstallerType {
    static let marker = "hypermnesia"
    static let legacyMarker = "hyperthymesia"   // pre-rename hooks must stay detectable/removable
    static let hydrateEvents = ["sessionStart"]
    static let captureEvents = ["stop", "sessionEnd"]
    /// Notch working state: a submitted prompt starts a turn…
    static let promptEvents = ["beforeSubmitPrompt"]
    /// …and the observational after-hooks are throttled "still working" heartbeats.
    static let heartbeatEvents = ["afterFileEdit", "afterShellExecution"]

    public static func settingsURL(projectPath: String? = nil) -> URL {
        base(projectPath: projectPath).appendingPathComponent("hooks.json")
    }

    public static func isInstalled(projectPath: String? = nil) -> Bool {
        guard let hooks = read(settingsURL(projectPath: projectPath))["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { entries in
            (entries as? [[String: Any]])?.contains { entryHasMarker($0) } ?? false
        }
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
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, entries) in hooks {
            guard var array = entries as? [[String: Any]] else { continue }
            array.removeAll { entryHasMarker($0) }
            if array.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = array }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Settings with our hooks merged in (for install + dry-run preview).
    public static func merged(into existing: [String: Any], binaryPath: String) -> [String: Any] {
        var settings = existing
        if settings["version"] == nil { settings["version"] = 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let bin = ConfigFile.shellQuote(binaryPath)
        let hydrateCmd = "\(bin) hydrate --client cursor"
        let captureCmd = HookDrainDiagnostics.captureCommand(binaryPath: binaryPath, client: "cursor")
        // Notch status: a separate hook entry (each entry gets its own stdin copy of the payload —
        // a `;` chain would let capture starve it of stdin). beforeSubmitPrompt is answered with
        // `{"continue": true}` by the CLI, so it never holds a prompt.
        let statusCmd = "\(bin) session-event --client cursor"
        for event in hydrateEvents { hooks[event] = mergedEntry(into: hooks[event], commands: [hydrateCmd]) }
        for event in captureEvents { hooks[event] = mergedEntry(into: hooks[event], commands: [captureCmd, statusCmd]) }
        for event in promptEvents + heartbeatEvents { hooks[event] = mergedEntry(into: hooks[event], commands: [statusCmd]) }
        settings["hooks"] = hooks
        return settings
    }

    /// Hooks are installed but predate some notch status event (`session-event` missing from a
    /// stop, prompt, or heartbeat hook) — the Settings UI offers a one-click re-install.
    public static func needsReinstall(projectPath: String? = nil) -> Bool {
        guard isInstalled(projectPath: projectPath),
              let hooks = read(settingsURL(projectPath: projectPath))["hooks"] as? [String: Any] else { return false }
        let statusCarriers = captureEvents + promptEvents + heartbeatEvents
        return !statusCarriers.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? [])
                .filter { entryHasMarker($0) }
                .compactMap { $0["command"] as? String }
                .contains { $0.contains("session-event") }
        }
    }

    /// Recorded hook binaries (the app-bundle CLI path baked into each command). Detects a dead
    /// install after the app is moved/translocated: `isInstalled` stays true but the binary no longer
    /// exists, so every Cursor hook exec silently fails. Reuses HookInstaller's shell-quoted-token
    /// parse; Cursor's flat `{command,type}` entries carry the command directly.
    public static func installedBinaryPaths(projectPath: String? = nil) -> [String] {
        guard let hooks = read(settingsURL(projectPath: projectPath))["hooks"] as? [String: Any] else { return [] }
        var paths: [String] = []
        for entries in hooks.values {
            guard let array = entries as? [[String: Any]] else { continue }
            for entry in array where entryHasMarker(entry) {
                guard let command = entry["command"] as? String,
                      let path = HookInstaller.recordedBinaryPath(inCommand: command),
                      !paths.contains(path) else { continue }
                paths.append(path)
            }
        }
        return paths
    }

    static func mergedEntry(into existing: Any?, commands: [String]) -> [[String: Any]] {
        var entries = (existing as? [[String: Any]]) ?? []
        entries.removeAll { entryHasMarker($0) }
        entries.append(contentsOf: commands.map { ["type": "command", "command": $0] })
        return entries
    }

    private static func entryHasMarker(_ entry: [String: Any]) -> Bool {
        {
            guard let command = entry["command"] as? String else { return false }
            return command.contains(marker) || command.contains(legacyMarker)
        }()
    }

    // MARK: - Helpers

    private static func base(projectPath: String?) -> URL {
        if let projectPath {
            return URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
                .appendingPathComponent(".cursor", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor", isDirectory: true)
    }

    /// Tolerant read for state checks only (`isInstalled`) — a corrupt file just reads "not installed".
    private static func read(_ url: URL) -> [String: Any] {
        (try? ConfigFile.readObject(at: url)) ?? [:]
    }
}
