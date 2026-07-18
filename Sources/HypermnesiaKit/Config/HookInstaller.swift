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
    /// Feed the app's notch status display: Notification (permission request / waiting for input)
    /// and PostToolUse (a cheap throttled "still working" heartbeat).
    static let statusEvents = ["Notification", "PostToolUse"]

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
        let captureCmd = HookDrainDiagnostics.captureCommand(binaryPath: binaryPath)
        let statusCmd = "\(bin) session-event"
        // SessionStart hydrates; UserPromptSubmit hydrates AND stamps the turn's start for the
        // notch working state. Status emitters are always their own hook command — Claude Code
        // feeds the payload to each command's stdin, whereas a `;` chain would let the first
        // command starve the second of stdin.
        hooks["SessionStart"] = mergedEntry(into: hooks["SessionStart"], commands: [hydrateCmd])
        hooks["UserPromptSubmit"] = mergedEntry(into: hooks["UserPromptSubmit"], commands: [hydrateCmd, statusCmd])
        for event in captureEvents { hooks[event] = mergedEntry(into: hooks[event], commands: [captureCmd, statusCmd]) }
        for event in statusEvents { hooks[event] = mergedEntry(into: hooks[event], commands: [statusCmd]) }
        settings["hooks"] = hooks
        return settings
    }

    /// Hooks are installed but predate some notch status event (no Notification/PostToolUse hook,
    /// or Stop/UserPromptSubmit without `session-event`) — the Settings UI offers a one-click
    /// re-install.
    public static func needsReinstall(projectPath: String? = nil) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL(projectPath: projectPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        guard isInstalled(projectPath: projectPath) else { return false }
        let statusCarriers = statusEvents + captureEvents + ["UserPromptSubmit"]
        return !statusCarriers.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? [])
                .filter { entryHasMarker($0) }
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String }
                .contains { $0.contains("session-event") }
        }
    }

    static func mergedEntry(into existing: Any?, commands: [String]) -> [[String: Any]] {
        var entries = (existing as? [[String: Any]]) ?? []
        entries.removeAll { entryHasMarker($0) }
        entries.append(["hooks": commands.map { ["type": "command", "command": $0] }])
        return entries
    }

    private static func entryHasMarker(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains(marker) || command.contains(legacyMarker)
        } ?? false
    }
}
