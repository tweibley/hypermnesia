import Foundation

/// Registers the `hypermnesia` MCP server in Cursor's `mcp.json`, so Cursor's agent can call
/// `recall` / `ask` / `remember`. Mirrors `HookInstaller`: user-global `~/.cursor/mcp.json` by
/// default, or a project's `.cursor/mcp.json` via `projectPath`; idempotent; preserves any other
/// configured servers.
///
/// Unlike the Claude path (which shells out to `claude mcp add`), Cursor reads `mcp.json` directly —
/// for both the IDE and the `cursor-agent` CLI — so we just write the file.
public enum CursorMCPInstaller {
    /// The MCP server key written under `mcpServers`.
    public static let server = "hypermnesia"
    /// Pre-rename server key: replaced on install, removed on uninstall.
    static let legacyServer = "hyperthymesia"

    public static func configURL(projectPath: String? = nil) -> URL {
        base(projectPath: projectPath).appendingPathComponent("mcp.json")
    }

    /// Whether our server entry is already present.
    public static func isInstalled(projectPath: String? = nil) -> Bool {
        let servers = read(configURL(projectPath: projectPath))["mcpServers"] as? [String: Any]
        return servers?[server] != nil
    }

    /// Add (or refresh) our server entry, preserving any other `mcpServers` and top-level keys.
    public static func install(binaryPath: String, projectPath: String? = nil) throws {
        let url = configURL(projectPath: projectPath)
        let settings = merged(into: try ConfigFile.readObject(at: url), binaryPath: binaryPath)
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Remove our server entry (other servers untouched). Drops the empty `mcpServers` key if it
    /// becomes empty, but leaves the file in place.
    public static func uninstall(projectPath: String? = nil) throws {
        let url = configURL(projectPath: projectPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var settings = try ConfigFile.readObject(at: url)
        guard var servers = settings["mcpServers"] as? [String: Any] else { return }
        servers.removeValue(forKey: server)
        servers.removeValue(forKey: legacyServer)
        if servers.isEmpty { settings.removeValue(forKey: "mcpServers") } else { settings["mcpServers"] = servers }
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Settings with our server merged into `mcpServers` — for install + dry-run preview.
    public static func merged(into existing: [String: Any], binaryPath: String) -> [String: Any] {
        var settings = existing
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: legacyServer)
        servers[server] = [
            "command": binaryPath,
            "args": ["mcp"],
            "type": "stdio",
        ]
        settings["mcpServers"] = servers
        return settings
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
