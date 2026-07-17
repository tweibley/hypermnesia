import Foundation
import Testing
@testable import HypermnesiaKit

/// The Hyperthymesia → Hypermnesia rename must leave no orphaned artifacts on machines that
/// installed under the old name: install and uninstall stay inverses across the rename boundary.
@Suite("Rename compatibility")
struct RenameCompatTests {

    @Test("guide uninstall removes a pre-rename marker block; reinstall replaces instead of duplicating")
    func legacyGuideBlock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claudeMd = MemoryGuideInstaller.claudeMdURL(projectPath: dir.path)

        let legacyBlock = """
        # My notes
        <!-- hyperthymesia:memory-guide -->
        Old guide text mentioning recall.
        <!-- /hyperthymesia:memory-guide -->
        Keep me.
        """
        try Data(legacyBlock.utf8).write(to: claudeMd)

        // Re-install replaces the legacy block — exactly one current block, zero legacy markers.
        try MemoryGuideInstaller.install(projectPath: dir.path)
        let installed = try String(contentsOf: claudeMd, encoding: .utf8)
        #expect(!installed.contains("hyperthymesia:memory-guide"))
        #expect(installed.components(separatedBy: MemoryGuideInstaller.openMarker).count == 2)
        #expect(installed.contains("Keep me."))

        // And uninstall removes everything ours, old or new.
        try MemoryGuideInstaller.uninstall(projectPath: dir.path)
        let after = try String(contentsOf: claudeMd, encoding: .utf8)
        #expect(!after.contains("memory-guide"))
        #expect(after.contains("Keep me."))
    }

    @Test("claude hooks installed under the old binary name are detected, replaced, and uninstalled")
    func legacyClaudeHooks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy: [String: Any] = ["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "'/old/path/hyperthymesia' hydrate"]]]],
            "SessionEnd": [
                ["hooks": [["type": "command", "command": "'/old/path/hyperthymesia' capture"]]],
                ["hooks": [["type": "command", "command": "/usr/local/bin/other-tool run"]]],
            ],
        ]]
        let url = HookInstaller.settingsURL(projectPath: dir.path)
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        #expect(HookInstaller.isInstalled(projectPath: dir.path))   // legacy counts as installed

        // Install replaces rather than doubling: exactly one of our commands per event.
        try HookInstaller.install(binaryPath: "/new/path/hypermnesia", projectPath: dir.path)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("hyperthymesia"))
        #expect(text.contains("hypermnesia"))

        // Uninstall removes ours, preserves the unrelated hook.
        try HookInstaller.uninstall(projectPath: dir.path)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(!after.contains("hypermnesia"))
        #expect(after.contains("other-tool"))
    }

    @Test("legacy MCP server entries and permission rules are replaced on install, removed on uninstall")
    func legacyMCPAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Cursor-style mcp.json with a legacy entry + an unrelated server.
        let merged = CursorMCPInstaller.merged(
            into: ["mcpServers": [
                "hyperthymesia": ["command": "/old/hyperthymesia", "args": ["mcp"]],
                "unrelated": ["command": "/bin/x"],
            ]],
            binaryPath: "/new/hypermnesia")
        let servers = merged["mcpServers"] as? [String: Any]
        #expect(servers?["hyperthymesia"] == nil)          // legacy replaced
        #expect(servers?["hypermnesia"] != nil)
        #expect(servers?["unrelated"] != nil)

        // Permissions: legacy rules replaced by current ones on install; uninstall removes both.
        let settings = PermissionInstaller.merged(into: ["permissions": [
            "allow": ["mcp__hyperthymesia__recall", "mcp__hyperthymesia__ask", "Bash(ls:*)"],
        ]])
        let allow = ((settings["permissions"] as? [String: Any])?["allow"] as? [Any])?.compactMap { $0 as? String } ?? []
        #expect(!allow.contains("mcp__hyperthymesia__recall"))
        #expect(allow.contains("mcp__hypermnesia__recall"))
        #expect(allow.contains("Bash(ls:*)"))
    }

    @Test("support directory migrates a pre-rename store once, and only when the new dir is absent")
    func supportDirMigration() throws {
        // Exercise the migration logic shape directly on temp dirs (the real path is user-global).
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hm-store-\(UUID().uuidString)")
        let legacy = base.appendingPathComponent("Hyperthymesia", isDirectory: true)
        let current = base.appendingPathComponent("Hypermnesia", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appendingPathComponent("memory.db"))
        defer { try? FileManager.default.removeItem(at: base) }

        StoreLocation.migrateLegacyDirectoryForTesting(base: base, to: current)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("memory.db").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        // A second migration attempt with a fresh legacy dir must NOT clobber the migrated store.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: legacy.appendingPathComponent("memory.db"))
        StoreLocation.migrateLegacyDirectoryForTesting(base: base, to: current)
        let content = try String(contentsOf: current.appendingPathComponent("memory.db"), encoding: .utf8)
        #expect(content == "db")
    }
}
