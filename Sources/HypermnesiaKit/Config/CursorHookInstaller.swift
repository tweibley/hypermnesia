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
public enum CursorHookInstaller {
    static let marker = "hypermnesia"
    static let legacyMarker = "hyperthymesia"   // pre-rename hooks must stay detectable/removable
    static let hydrateEvents = ["sessionStart"]
    static let captureEvents = ["stop", "sessionEnd"]

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
        let captureCmd = "\(bin) capture --client cursor; (nohup \(bin) drain >/dev/null 2>&1 &)"
        for event in hydrateEvents { hooks[event] = mergedEntry(into: hooks[event], command: hydrateCmd) }
        for event in captureEvents { hooks[event] = mergedEntry(into: hooks[event], command: captureCmd) }
        settings["hooks"] = hooks
        return settings
    }

    static func mergedEntry(into existing: Any?, command: String) -> [[String: Any]] {
        var entries = (existing as? [[String: Any]]) ?? []
        entries.removeAll { entryHasMarker($0) }
        entries.append(["type": "command", "command": command])
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
