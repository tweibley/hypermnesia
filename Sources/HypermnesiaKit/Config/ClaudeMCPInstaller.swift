import Foundation

/// Registers the `hypermnesia` MCP server in a project's `.mcp.json` — the file Claude Code
/// reads for project-scope MCP servers — so `recall` / `ask` / `remember` exist without the user
/// hand-running `claude mcp add`. Mirrors `CursorMCPInstaller`: idempotent, preserves any other
/// configured servers, and uninstall is install's exact inverse.
///
/// User-global registration intentionally stays with the `claude` CLI (`claude mcp add --scope
/// user …`): `~/.claude.json` is Claude Code's own mutable state file, not a config we should
/// rewrite behind its back. The `install-mcp` command shells out for that scope.
public enum ClaudeMCPInstaller {
    /// The MCP server key written under `mcpServers`.
    public static let server = "hypermnesia"
    /// Pre-rename server key: replaced on install, removed on uninstall.
    static let legacyServer = "hyperthymesia"

    public static func configURL(projectPath: String) -> URL {
        URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .appendingPathComponent(".mcp.json")
    }

    /// Whether our server entry is already present.
    public static func isInstalled(projectPath: String) -> Bool {
        let settings = (try? ConfigFile.readObject(at: configURL(projectPath: projectPath))) ?? [:]
        return (settings["mcpServers"] as? [String: Any])?[server] != nil
    }

    /// Add (or refresh) our server entry, preserving any other `mcpServers` and top-level keys.
    public static func install(binaryPath: String, projectPath: String) throws {
        let url = configURL(projectPath: projectPath)
        let settings = merged(into: try ConfigFile.readObject(at: url), binaryPath: binaryPath)
        try ConfigFile.writeObject(settings, to: url)
    }

    /// Remove our server entry (other servers untouched). Drops the `mcpServers` key if it becomes
    /// empty, but leaves the file in place.
    public static func uninstall(projectPath: String) throws {
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
            "type": "stdio",
            "command": binaryPath,
            "args": ["mcp"],
        ]
        settings["mcpServers"] = servers
        return settings
    }
}
