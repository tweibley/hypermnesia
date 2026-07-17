import Foundation

/// Pre-approves Hypermnesia's **read-only** MCP tools in Claude Code's `permissions.allow`, so an
/// agent's first `recall`/`ask` call doesn't trip the per-session permission prompt — the friction
/// that makes the MCP *pull* path feel less automatic than the silent hooks *push* path.
///
/// Mirrors `HookInstaller`: same `settings.json` target (user-global `~/.claude/settings.json` by
/// default, or a project's `.claude/settings.json` via `projectPath`), idempotent, preserves any
/// existing rules. Shared by the CLI (`allow-tools` / `install-hooks`) and the app's Settings.
///
/// **Deliberately read-only.** `recall` and `ask` only read memory and are safe to silence. `remember`
/// *writes* a memory, so it stays behind the per-session prompt unless the user allows it themselves.
public enum PermissionInstaller {
    /// The MCP server name — the `mcp__<server>__<tool>` prefix Claude Code uses for permission rules.
    public static let server = "hypermnesia"

    /// The read-only tools safe to pre-approve.
    public static let readOnlyTools = ["mcp__\(server)__recall", "mcp__\(server)__ask"]
    /// Pre-rename rule names — removed by both install (replace) and uninstall (inverse).
    static let legacyTools = ["mcp__hyperthymesia__recall", "mcp__hyperthymesia__ask"]

    /// Same settings file the hooks live in.
    public static func settingsURL(projectPath: String? = nil) -> URL {
        HookInstaller.settingsURL(projectPath: projectPath)
    }

    /// Which read-only tools are NOT yet allowed — drives "check, and if missing, prompt".
    public static func missing(projectPath: String? = nil) -> [String] {
        let allowed = Set(currentAllow(projectPath: projectPath))
        return readOnlyTools.filter { !allowed.contains($0) }
    }

    /// Whether all of our read-only tools are already pre-approved.
    public static func isInstalled(projectPath: String? = nil) -> Bool {
        missing(projectPath: projectPath).isEmpty
    }

    /// Add our read-only tools to `permissions.allow` (idempotent; existing rules preserved).
    public static func install(projectPath: String? = nil) throws {
        let url = settingsURL(projectPath: projectPath)
        let settings = merged(into: try ConfigFile.readObject(at: url))
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Remove our read-only tools from `permissions.allow` (other rules untouched).
    public static func uninstall(projectPath: String? = nil) throws {
        let url = settingsURL(projectPath: projectPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var settings = try ConfigFile.readObject(at: url)
        guard var permissions = settings["permissions"] as? [String: Any],
              var allow = permissions["allow"] as? [Any] else { return }
        let ours = Set(readOnlyTools + legacyTools)
        allow.removeAll { ($0 as? String).map(ours.contains) ?? false }
        permissions["allow"] = allow
        settings["permissions"] = permissions
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Settings with our tools merged into `permissions.allow` — for install + dry-run preview.
    /// Appends only the missing tools, preserving any existing (and non-string) allow entries.
    public static func merged(into existing: [String: Any]) -> [String: Any] {
        var settings = existing
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [Any] ?? []
        let stale = Set(legacyTools)
        allow.removeAll { ($0 as? String).map(stale.contains) ?? false }   // replace pre-rename rules
        let present = Set(allow.compactMap { $0 as? String })
        for tool in readOnlyTools where !present.contains(tool) { allow.append(tool) }
        permissions["allow"] = allow
        settings["permissions"] = permissions
        return settings
    }

    // MARK: - Helpers

    private static func currentAllow(projectPath: String?) -> [String] {
        let permissions = readSettings(settingsURL(projectPath: projectPath))["permissions"] as? [String: Any]
        return (permissions?["allow"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Tolerant read for state checks only (`isInstalled`/`missing`) — a corrupt file reads "not installed".
    private static func readSettings(_ url: URL) -> [String: Any] {
        (try? ConfigFile.readObject(at: url)) ?? [:]
    }
}
