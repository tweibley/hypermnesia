import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("ClaudeMCPInstaller")
struct ClaudeMCPInstallerTests {

    private func tempProject() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test("install and uninstall are inverses; other servers are preserved")
    func roundTripPreservesOtherServers() throws {
        let project = tempProject()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let url = ClaudeMCPInstaller.configURL(projectPath: project)

        // Pre-existing config with an unrelated server and a top-level key.
        try ConfigFile.writeObject([
            "mcpServers": ["other": ["command": "other-bin", "args": []]],
            "unrelated": "keep-me",
        ], to: url)

        try ClaudeMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: project)
        #expect(ClaudeMCPInstaller.isInstalled(projectPath: project))
        var settings = try ConfigFile.readObject(at: url)
        var servers = try #require(settings["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        #expect(settings["unrelated"] as? String == "keep-me")
        let entry = try #require(servers[ClaudeMCPInstaller.server] as? [String: Any])
        #expect(entry["command"] as? String == "/usr/local/bin/hypermnesia")
        #expect(entry["args"] as? [String] == ["mcp"])

        try ClaudeMCPInstaller.uninstall(projectPath: project)
        #expect(!ClaudeMCPInstaller.isInstalled(projectPath: project))
        settings = try ConfigFile.readObject(at: url)
        servers = try #require(settings["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)                    // untouched
        #expect(settings["unrelated"] as? String == "keep-me")
    }

    @Test("uninstall with no file or no entry is a safe no-op")
    func uninstallToleratesAbsence() throws {
        let project = tempProject()
        defer { try? FileManager.default.removeItem(atPath: project) }
        try ClaudeMCPInstaller.uninstall(projectPath: project)   // no file
        #expect(!FileManager.default.fileExists(atPath: ClaudeMCPInstaller.configURL(projectPath: project).path))

        try ClaudeMCPInstaller.install(binaryPath: "bin", projectPath: project)
        try ClaudeMCPInstaller.uninstall(projectPath: project)
        try ClaudeMCPInstaller.uninstall(projectPath: project)   // idempotent
        let settings = try ConfigFile.readObject(at: ClaudeMCPInstaller.configURL(projectPath: project))
        #expect(settings["mcpServers"] == nil)                   // empty key dropped
    }
}
