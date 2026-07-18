import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("MCP")
struct MCPTests {
    private func handler() throws -> MCPHandler { MCPHandler(store: try MemoryStore(location: .inMemory)) }
    private let project = "github.com/t/x"

    @Test("initialize returns server info and tool capability")
    func initialize() async throws {
        let mcp = try handler()
        let response = await mcp.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ])
        let result = response?["result"] as? [String: Any]
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "hypermnesia")
        #expect(result?["capabilities"] != nil)
        #expect(response?["id"] as? Int == 1)
    }

    @Test("tools/list advertises recall, ask, remember")
    func toolsList() async throws {
        let mcp = try handler()
        let response = await mcp.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["recall", "ask", "remember"])
    }

    @Test("remember stores a DRAFT that recall ignores until confirmed — MCP writes go through the review gate")
    func rememberThenRecall() async throws {
        let store = try MemoryStore(location: .inMemory)
        let mcp = MCPHandler(store: store)
        let stored = await mcp.handle([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "remember", "arguments": [
                "type": "fact", "title": "Database", "summary": "Uses Postgres 16", "project": project,
            ]],
        ])
        let content = ((stored?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(content?.contains("draft") == true)

        // The memory lands as a draft and is NOT injected/recalled yet — any MCP client can call
        // remember, so its writes must not skip the human review gate.
        let drafts = try store.nodes(projectId: project, status: .draft, limit: 10)
        #expect(drafts.count == 1)
        let unconfirmed = await mcp.handle([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "recall", "arguments": ["query": "Postgres", "project": project]],
        ])
        let before = ((unconfirmed?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(before?.contains("Postgres") != true)

        // Confirming it (what the app's review inbox does) makes it recallable.
        var node = try #require(drafts.first)
        node.status = .confirmed
        try store.upsert(node)
        let recalled = await mcp.handle([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "recall", "arguments": ["query": "Postgres", "project": project]],
        ])
        let text = ((recalled?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.contains("Postgres") == true)
    }

    @Test("notifications get no response; unknown methods error")
    func notificationsAndErrors() async throws {
        let mcp = try handler()
        let none = await mcp.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(none == nil)

        let bad = await mcp.handle(["jsonrpc": "2.0", "id": 9, "method": "no/such"])
        #expect((bad?["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("remember conflict detection considers same-type memories beyond newest 500")
    func rememberConflictUsesCompleteCorpus() async throws {
        let store = try MemoryStore(location: .inMemory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let old = MemoryNode(
            projectId: project, type: .fact, status: .confirmed,
            title: "Legacy endpoint", summary: "Uses SOAP XML transport",
            data: .fact(.init(category: "state", key: "Target", value: "SOAP")),
            createdAt: base, updatedAt: base
        )
        var nodes = [old]
        nodes += (0..<500).map { index in
            MemoryNode(
                projectId: project, type: .fact, status: .confirmed,
                title: "Decoy \(index)", summary: "Unrelated state \(index)",
                data: .fact(.init(category: "state", key: "decoy-\(index)", value: "\(index)")),
                createdAt: base.addingTimeInterval(Double(index + 1)),
                updatedAt: base.addingTimeInterval(Double(index + 1))
            )
        }
        try store.upsert(nodes)
        let mcp = MCPHandler(store: store)

        _ = await mcp.handle([
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": "remember", "arguments": [
                "type": "fact", "title": "Target",
                "summary": "Uses GraphQL federation", "project": project,
            ]],
        ])

        let draft = try #require(try store.allNodes(projectId: project, status: .draft).first)
        #expect(draft.supersedesId == old.id)
    }
}
