import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Audit")
struct AuditTests {

    @Test("flags a memory whose related file is missing, and penalizes it on apply")
    func missingFileAndApply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("exists.swift").path, contents: Data("x".utf8))

        let store = try MemoryStore(location: .inMemory)
        let node = MemoryNode(
            projectId: "p", type: .decision, status: .confirmed, title: "Use a queue",
            summary: "background work goes through a queue",
            data: .decision(.init(chosen: "queue", relatedFiles: [
                dir.appendingPathComponent("exists.swift").path,
                dir.appendingPathComponent("gone.swift").path,
            ])),
            confidence: 1.0
        )
        try store.upsert(node)

        let findings = MemoryAuditor.audit(store: store, projectId: "p", repoPath: dir.path)
        #expect(findings.count == 1)
        #expect(findings.first?.issue == .missingFile)
        #expect(findings.first?.detail.hasSuffix("gone.swift") == true)

        let flagged = MemoryAuditor.apply(findings, store: store)
        #expect(flagged == 1)
        let updated = try #require(try store.node(id: node.id))
        #expect(updated.confidence < 1.0)          // penalized → will surface in Health
        #expect(updated.needsRevalidation)
    }

    @Test("applying the same finding twice doesn't compound the penalty")
    func idempotentPenalty() throws {
        let store = try MemoryStore(location: .inMemory)
        let node = MemoryNode(projectId: "p", type: .decision, status: .confirmed, title: "t", summary: "s",
                              data: .decision(.init(chosen: "x")), confidence: 1.0)
        try store.upsert(node)
        let findings = [AuditFinding(nodeId: node.id, title: "t", issue: .changedSinceCapture, detail: "f")]

        #expect(MemoryAuditor.apply(findings, store: store) == 1)
        #expect(try store.node(id: node.id)?.confidence == 0.7)
        #expect(MemoryAuditor.apply(findings, store: store) == 0)   // idempotent
        #expect(try store.node(id: node.id)?.confidence == 0.7)     // not 0.49
    }

    @Test("repoPath resolves a path: project id directly")
    func repoPathForPathProject() {
        #expect(MemoryAuditor.repoPath(forProjectId: "path:/Users/x/proj") == "/Users/x/proj")
    }

    @Test("path helpers")
    func helpers() {
        #expect(MemoryAuditor.absolutePath("a.swift", repoPath: "/r") == "/r/a.swift")
        #expect(MemoryAuditor.absolutePath("/abs/a.swift", repoPath: "/r") == "/abs/a.swift")
        #expect(MemoryAuditor.relativePath("/r/sub/a.swift", repoPath: "/r") == "sub/a.swift")
    }
}
