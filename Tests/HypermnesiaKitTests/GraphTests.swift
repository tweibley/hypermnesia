import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Graph")
struct GraphTests {
    private func node(_ id: String, _ type: MemoryType, files: [String] = [],
                      conversation: String? = nil, supersededBy: String? = nil) -> MemoryNode {
        let data: MemoryData = switch type {
        case .decision: .decision(.init(chosen: "x", relatedFiles: files))
        case .concern: .concern(.init(issue: "i", severity: "low", relatedFiles: files))
        case .intent: .intent(.init(goal: "g", relatedFiles: files))
        default: .convention(.init(rule: "r", relatedFiles: files))
        }
        return MemoryNode(id: id, projectId: "p", type: type, title: id, summary: "s", data: data,
                          supersededById: supersededBy, conversationId: conversation)
    }

    @Test("edges from shared files are typed by endpoint")
    func sharedFileEdges() {
        let edges = GraphBuilder.inferEdges([
            node("a", .decision, files: ["x.swift"]),
            node("b", .intent, files: ["x.swift"]),
            node("c", .concern, files: ["x.swift"]),
        ])
        // a(decision)+b(intent) → implements; anything with concern c → affects
        #expect(edges.contains { $0.source == "a" && $0.target == "b" && $0.relationship == .implements })
        #expect(edges.contains { $0.relationship == .affects })
    }

    @Test("supersession lineage produces a supersedes edge")
    func supersedesEdge() {
        let edges = GraphBuilder.inferEdges([
            node("old", .decision, supersededBy: "new"),
            node("new", .decision),
        ])
        #expect(edges.contains { $0.source == "new" && $0.target == "old" && $0.relationship == .supersedes })
    }

    @Test("same-session memories are chained, not fully connected")
    func sessionChain() {
        let edges = GraphBuilder.inferEdges([
            node("a", .fact, conversation: "s1"),
            node("b", .fact, conversation: "s1"),
            node("c", .fact, conversation: "s1"),
        ]).filter { $0.relationship == .relatedTo }
        #expect(edges.count == 2)   // a-b, b-c (chain), not 3 (clique)
    }
}
