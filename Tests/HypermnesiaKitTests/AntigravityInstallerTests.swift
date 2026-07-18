import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("AntigravityInstaller")
struct AntigravityInstallerTests {

    private func tempProject(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        return dir
    }

    @Test("AntigravityMCPInstaller registers our server, preserves others, idempotent, uninstalls cleanly")
    func antigravityMCP() throws {
        let dir = try tempProject("agy-mcp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = AntigravityMCPInstaller.configURL(projectPath: dir.path)
        try Data(#"{"mcpServers":{"other":{"serverUrl":"https://example.com/mcp"}}}"#.utf8).write(to: url)

        #expect(!AntigravityMCPInstaller.isInstalled(projectPath: dir.path))
        try AntigravityMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(AntigravityMCPInstaller.isInstalled(projectPath: dir.path))

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var servers = json["mcpServers"] as! [String: Any]
        #expect(servers["other"] != nil)   // preserved
        let ours = servers["hypermnesia"] as! [String: Any]
        #expect(ours["command"] as? String == "/usr/local/bin/hypermnesia")
        #expect(ours["args"] as? [String] == ["mcp"])
        // Antigravity has no `type` field — stdio is inferred from `command`.
        #expect(ours["type"] == nil)

        // Idempotent: re-install adds no duplicate.
        try AntigravityMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        servers = json["mcpServers"] as! [String: Any]
        #expect(servers.count == 2)

        // Uninstall removes only ours.
        try AntigravityMCPInstaller.uninstall(projectPath: dir.path)
        #expect(!AntigravityMCPInstaller.isInstalled(projectPath: dir.path))
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect((json["mcpServers"] as! [String: Any])["other"] != nil)
    }

    @Test("MCP install treats an existing zero-byte mcp_config.json as a fresh file")
    func antigravityMCPEmptyFile() throws {
        // Real installs ship an empty (0-byte) ~/.gemini/config/mcp_config.json — that must read as
        // a fresh config, not as corrupt.
        let dir = try tempProject("agy-mcp-empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = AntigravityMCPInstaller.configURL(projectPath: dir.path)
        try Data().write(to: url)

        try AntigravityMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(AntigravityMCPInstaller.isInstalled(projectPath: dir.path))
    }

    @Test("AntigravityHookInstaller owns the hypermnesia hook key, preserves other hooks, uninstalls cleanly")
    func antigravityHooks() throws {
        let dir = try tempProject("agy-hooks")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = AntigravityHookInstaller.settingsURL(projectPath: dir.path)
        try Data(#"{"my-linter":{"PostToolUse":[{"matcher":"run_command","hooks":[{"command":"./lint.sh"}]}]}}"#.utf8)
            .write(to: url)

        #expect(!AntigravityHookInstaller.isInstalled(projectPath: dir.path))
        try AntigravityHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(AntigravityHookInstaller.isInstalled(projectPath: dir.path))
        #expect(!AntigravityHookInstaller.needsReinstall(projectPath: dir.path))

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(json["my-linter"] != nil)   // other hook preserved
        let ours = json["hypermnesia"] as! [String: Any]
        #expect(Set(ours.keys) == ["PreInvocation", "Stop"])
        // PreInvocation hydrates AND heartbeats the notch working state.
        let preCommands = (ours["PreInvocation"] as! [[String: Any]]).compactMap { $0["command"] as? String }
        #expect(preCommands == ["'/usr/local/bin/hypermnesia' hydrate --client antigravity",
                                "'/usr/local/bin/hypermnesia' session-event --client antigravity"])
        let stopCommands = (ours["Stop"] as! [[String: Any]]).compactMap { $0["command"] as? String }
        #expect(stopCommands.count == 2)
        #expect(stopCommands.first?.contains("capture --client antigravity") == true)
        #expect(stopCommands.first?.contains("drain") == true)
        #expect(stopCommands.last == "'/usr/local/bin/hypermnesia' session-event --client antigravity")

        // A notch-v1 config (session-event on Stop only) predates the working heartbeat.
        var v1 = json
        var v1Ours = ours
        v1Ours["PreInvocation"] = [["type": "command", "command": "'/usr/local/bin/hypermnesia' hydrate --client antigravity"]]
        v1["hypermnesia"] = v1Ours
        try JSONSerialization.data(withJSONObject: v1).write(to: url)
        #expect(AntigravityHookInstaller.needsReinstall(projectPath: dir.path))
        try AntigravityHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(!AntigravityHookInstaller.needsReinstall(projectPath: dir.path))

        // Idempotent: re-install keeps exactly one of our key.
        try AntigravityHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        let again = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(again.count == 2)

        // Uninstall removes only ours; the linter hook survives.
        try AntigravityHookInstaller.uninstall(projectPath: dir.path)
        #expect(!AntigravityHookInstaller.isInstalled(projectPath: dir.path))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(after["my-linter"] != nil)
        #expect(after["hypermnesia"] == nil)
    }

    @Test("global config lands in ~/.gemini/config; project config in <project>/.agents")
    func antigravityPaths() {
        #expect(AntigravityHookInstaller.settingsURL().path.hasSuffix("/.gemini/config/hooks.json"))
        #expect(AntigravityMCPInstaller.configURL().path.hasSuffix("/.gemini/config/mcp_config.json"))
        #expect(AntigravityHookInstaller.settingsURL(projectPath: "/tmp/p").path == "/tmp/p/.agents/hooks.json")
        #expect(AntigravityMCPInstaller.configURL(projectPath: "/tmp/p").path == "/tmp/p/.agents/mcp_config.json")
    }
}
