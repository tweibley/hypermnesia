import Foundation

/// Installs/removes Hypermnesia's capture + hydrate hooks in Claude Code settings. Shared by the
/// CLI (`install-hooks`) and the app's Settings toggle.
public enum HookInstaller {
    static let marker = "hypermnesia"
    /// Pre-rename binary name: detection/uninstall/replace must keep matching hooks installed
    /// under the old name, or a rename-era machine ends up with doubled (and broken) hooks.
    static let legacyMarker = "hyperthymesia"
    static let hydrateEvents = ["SessionStart", "UserPromptSubmit"]
    static let captureEvents = ["Stop", "SessionEnd"]

    public static func settingsURL(projectPath: String? = nil) -> URL {
        let base = projectPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent(".claude/settings.json")
    }

    public static func isInstalled(projectPath: String? = nil) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL(projectPath: projectPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
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
        settings["hooks"] = hooks
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Settings with our hooks merged in (for install + dry-run preview).
    public static func merged(into existing: [String: Any], binaryPath: String) -> [String: Any] {
        var settings = existing
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let bin = ConfigFile.shellQuote(binaryPath)
        let hydrateCmd = "\(bin) hydrate"
        let captureCmd = "\(bin) capture; (nohup \(bin) drain >/dev/null 2>&1 &)"
        for event in hydrateEvents { hooks[event] = mergedEntry(into: hooks[event], command: hydrateCmd) }
        for event in captureEvents { hooks[event] = mergedEntry(into: hooks[event], command: captureCmd) }
        settings["hooks"] = hooks
        return settings
    }

    static func mergedEntry(into existing: Any?, command: String) -> [[String: Any]] {
        var entries = (existing as? [[String: Any]]) ?? []
        entries.removeAll { entryHasMarker($0) }
        entries.append(["hooks": [["type": "command", "command": command]]])
        return entries
    }

    private static func entryHasMarker(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains(marker) || command.contains(legacyMarker)
        } ?? false
    }
}
