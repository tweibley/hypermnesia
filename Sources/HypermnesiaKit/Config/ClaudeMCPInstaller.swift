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

    /// Health of the user-scope (`claude mcp add -s user`) registration, probed live.
    public enum Health: Equatable {
        case notRegistered
        case registeredDisconnected
        /// Registered in `~/.claude.json`, but the live `claude mcp list` probe failed or timed
        /// out (it checks every configured server, so one slow/wedged server sinks it).
        case registeredUnverified
        case connected
        /// The probe failed and no user-scope registration record exists to fall back on.
        case unreadable
    }

    /// Probe the user-scope registration via `claude mcp list`. When the probe itself fails,
    /// falls back to the registration record so a successful `mcp add` isn't reported as broken.
    public static func health(claudeCLI: String) -> Health {
        let list = Shell.run(claudeCLI, ["mcp", "list"], timeout: 20)
        guard list.succeeded else {
            // `claude mcp list` live-probes every configured server (project + plugin scopes too),
            // so one slow server — or a cold `npx …@latest` fetch — times the whole command out.
            return isRegisteredInUserScope() ? .registeredUnverified : .unreadable
        }
        let output = list.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .notRegistered }
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: { $0.hasPrefix("\(server):") }) else { return .notRegistered }
        return line.contains("✔ Connected") ? .connected : .registeredDisconnected
    }

    /// Whether `hypermnesia` is registered at user scope. Read-only peek at `~/.claude.json` —
    /// Claude Code's own state file, which we deliberately never write (see the note above).
    public static func isRegisteredInUserScope() -> Bool {
        let url = URL(fileURLWithPath: NSString(string: "~/.claude.json").expandingTildeInPath)
        let settings = (try? ConfigFile.readObject(at: url)) ?? [:]
        return (settings["mcpServers"] as? [String: Any])?[server] != nil
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
