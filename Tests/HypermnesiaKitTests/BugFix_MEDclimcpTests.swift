import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression tests for cluster MED-cli-mcp.
@Suite("BugFix_MEDclimcp")
struct BugFix_MEDclimcpTests {
    private let project = "github.com/t/medclimcp"

    // MARK: - MCP `remember` reinforces an existing memory instead of inserting a duplicate draft

    @Test("remember called twice with the same content reinforces, it does not create a second draft")
    func rememberReinforcesInsteadOfDuplicating() async throws {
        let store = try MemoryStore(location: .inMemory)
        let mcp = MCPHandler(store: store)
        let args: [String: Any] = [
            "type": "convention", "title": "Formatting",
            "summary": "Run swiftformat before committing", "project": project,
        ]
        func call() async -> String? {
            let resp = await mcp.handle([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "remember", "arguments": args],
            ])
            return ((resp?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        }

        let first = await call()
        #expect(first?.contains("draft") == true)
        let afterFirst = try store.allNodes(projectId: project, type: .convention)
        #expect(afterFirst.count == 1)

        // Second identical remember must NOT insert a new draft — it reinforces the existing one.
        let second = await call()
        #expect(second?.contains("Reinforced") == true)
        let afterSecond = try store.allNodes(projectId: project, type: .convention)
        #expect(afterSecond.count == 1)
        // The repeat sighting is recorded on the existing memory.
        #expect(afterSecond.first?.timesSighted == 1)
        #expect(afterSecond.first?.timesApplied == 1)
    }

    // MARK: - MCP `ask` surfaces backend failures as an error result, not a silent "no answer"

    @Test("ask with an empty question returns an isError result")
    func askEmptyQuestionIsError() async throws {
        let store = try MemoryStore(location: .inMemory)
        let mcp = MCPHandler(store: store)
        let resp = await mcp.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "ask", "arguments": ["question": "", "project": project]],
        ])
        let result = resp?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == true)
    }

    // MARK: - ConfigFile.writeObject writes through a symlink instead of replacing it

    @Test("writeObject follows a symlink and updates its target, keeping the link intact")
    func writeObjectPreservesSymlink() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("medclimcp-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Simulate a dotfiles setup: real file lives in a repo, config path is a symlink to it.
        let realFile = tmp.appendingPathComponent("dotfiles-settings.json")
        try Data("{\"existing\":true}".utf8).write(to: realFile)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: realFile.path)
        let linkPath = tmp.appendingPathComponent("settings.json")
        try fm.createSymbolicLink(at: linkPath, withDestinationURL: realFile)

        try ConfigFile.writeObject(["hooks": ["installed"]], to: linkPath)

        // The path we wrote to is still a symlink (not clobbered into a plain file)...
        let isSymlink = (try? linkPath.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        #expect(isSymlink == true)
        // ...and the new content landed in the dotfiles-managed target.
        let written = try ConfigFile.readObject(at: realFile)
        #expect(written["hooks"] as? [String] == ["installed"])
        // The target's mode was preserved (not reset to a default like 0644/0755).
        let mode = (try fm.attributesOfItem(atPath: realFile.path)[.posixPermissions]) as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }
}
