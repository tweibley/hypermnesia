import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("CursorInstaller")
struct CursorInstallerTests {

    private func tempProject(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        return dir
    }

    @Test("CursorMCPInstaller registers our server, preserves others, idempotent, uninstalls cleanly")
    func cursorMCP() throws {
        let dir = try tempProject("cursor-mcp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = CursorMCPInstaller.configURL(projectPath: dir.path)
        try Data(#"{"mcpServers":{"other":{"command":"foo","args":["x"]}}}"#.utf8).write(to: url)

        #expect(!CursorMCPInstaller.isInstalled(projectPath: dir.path))
        try CursorMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(CursorMCPInstaller.isInstalled(projectPath: dir.path))

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var servers = json["mcpServers"] as! [String: Any]
        #expect(servers["other"] != nil)   // preserved
        let ours = servers["hypermnesia"] as! [String: Any]
        #expect(ours["command"] as? String == "/usr/local/bin/hypermnesia")
        #expect(ours["args"] as? [String] == ["mcp"])
        #expect(ours["type"] as? String == "stdio")

        // Idempotent: re-install adds no duplicate.
        try CursorMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        servers = json["mcpServers"] as! [String: Any]
        #expect(servers.count == 2)

        // Uninstall removes only ours.
        try CursorMCPInstaller.uninstall(projectPath: dir.path)
        #expect(!CursorMCPInstaller.isInstalled(projectPath: dir.path))
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect((json["mcpServers"] as! [String: Any])["other"] != nil)
    }

    @Test("CursorHookInstaller installs sessionStart/stop/sessionEnd, preserves others, uninstalls cleanly")
    func cursorHooks() throws {
        let dir = try tempProject("cursor-hooks")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = CursorHookInstaller.settingsURL(projectPath: dir.path)
        try Data(#"{"version":1,"hooks":{"stop":[{"type":"command","command":"echo other"}]}}"#.utf8).write(to: url)

        #expect(!CursorHookInstaller.isInstalled(projectPath: dir.path))
        try CursorHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(CursorHookInstaller.isInstalled(projectPath: dir.path))

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(json["version"] as? Int == 1)
        let hooks = json["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == ["sessionStart", "stop", "sessionEnd"])
        // Pre-existing stop hook kept alongside ours.
        let stop = hooks["stop"] as! [[String: Any]]
        #expect(stop.count == 2)
        #expect((hooks["sessionStart"] as! [[String: Any]]).first?["command"] as? String == "'/usr/local/bin/hypermnesia' hydrate --client cursor")
        #expect(((hooks["sessionEnd"] as! [[String: Any]]).first?["command"] as? String)?.contains("capture --client cursor") == true)

        // Idempotent.
        try CursorHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        let again = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["hooks"] as! [String: Any]
        #expect((again["stop"] as! [[String: Any]]).count == 2)

        // Uninstall removes only ours; the echo hook survives.
        try CursorHookInstaller.uninstall(projectPath: dir.path)
        #expect(!CursorHookInstaller.isInstalled(projectPath: dir.path))
        let after = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["hooks"] as! [String: Any]
        let afterStop = after["stop"] as! [[String: Any]]
        #expect(afterStop.count == 1)
        #expect(afterStop.first?["command"] as? String == "echo other")
    }

    @Test("CursorSessions encodes the workspace path Cursor's way and composes the transcript path")
    func cursorEncoding() {
        #expect(CursorSessions.encode(path: "/Users/x/hypermnesia") == "Users-x-hypermnesia")
        let path = CursorSessions.transcriptPath(cwd: "/Users/x/proj", sessionId: "abc").path
        #expect(path.hasSuffix("/.cursor/projects/Users-x-proj/agent-transcripts/abc/abc.jsonl"))
    }
}
