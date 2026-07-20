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

    @Test("repairCodeRefPaths rewrites a git-renamed file; missing without rename still flags")
    func codeRefRenameRepair() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func git(_ args: [String]) throws {
            let r = Shell.run("git", ["-C", dir.path] + args, cwd: dir.path)
            guard r.succeeded else { throw NSError(domain: "git", code: Int(r.status), userInfo: [
                NSLocalizedDescriptionKey: r.stderr
            ]) }
        }
        try git(["init"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        let old = dir.appendingPathComponent("Old.swift")
        try Data("v1".utf8).write(to: old)
        try git(["add", "Old.swift"])
        try git(["commit", "-m", "add"])
        let sha = try #require(ProjectIdentity.headSha(cwd: dir.path))
        try git(["mv", "Old.swift", "New.swift"])
        try git(["commit", "-m", "rename"])

        let store = try MemoryStore(location: .inMemory)
        let codeRef = MemoryNode(
            projectId: "p", type: .codeRef, status: .confirmed,
            title: "Old.swift", summary: "Old.swift",
            data: .codeRef(.init(filePath: "Old.swift")),
            confidence: 1.0, commitSha: sha
        )
        let vanished = MemoryNode(
            projectId: "p", type: .codeRef, status: .confirmed,
            title: "Gone.swift", summary: "Gone.swift",
            data: .codeRef(.init(filePath: "Gone.swift")),
            confidence: 1.0, commitSha: sha
        )
        try store.upsert([codeRef, vanished])

        let repaired = MemoryAuditor.repairCodeRefPaths(store: store, projectId: "p", repoPath: dir.path)
        #expect(repaired == 1)
        let fixed = try #require(try store.node(id: codeRef.id))
        if case .codeRef(let d) = fixed.data {
            #expect(d.filePath == "New.swift")
        } else {
            Issue.record("expected codeRef")
        }
        #expect(fixed.title == "New.swift")

        let findings = MemoryAuditor.audit(store: store, projectId: "p", repoPath: dir.path)
        #expect(findings.contains { $0.nodeId == vanished.id && $0.issue == .missingFile })
        #expect(!findings.contains { $0.nodeId == codeRef.id && $0.issue == .missingFile })
    }

    @Test("rename repair merges into an existing codeRef at the new path instead of duplicating")
    func codeRefRenameCollisionMerges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-rename-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func git(_ args: [String]) throws {
            let r = Shell.run("git", ["-C", dir.path] + args, cwd: dir.path)
            guard r.succeeded else { throw NSError(domain: "git", code: Int(r.status), userInfo: [
                NSLocalizedDescriptionKey: r.stderr
            ]) }
        }
        try git(["init"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        let old = dir.appendingPathComponent("Old.swift")
        try Data("v1".utf8).write(to: old)
        try git(["add", "Old.swift"])
        try git(["commit", "-m", "add"])
        let sha = try #require(ProjectIdentity.headSha(cwd: dir.path))
        try git(["mv", "Old.swift", "New.swift"])
        try git(["commit", "-m", "rename"])

        let store = try MemoryStore(location: .inMemory)
        let stale = MemoryNode(
            projectId: "p", type: .codeRef, status: .confirmed,
            title: "Old.swift", summary: "Old.swift",
            data: .codeRef(.init(filePath: "Old.swift")),
            confidence: 1.0, commitSha: sha, timesApplied: 3, timesSighted: 3
        )
        // Post-rename edits already created a draft node at the new path.
        let survivor = MemoryNode(
            projectId: "p", type: .codeRef, status: .draft,
            title: "New.swift", summary: "New.swift",
            data: .codeRef(.init(filePath: "New.swift")),
            confidence: 0.9, timesApplied: 1, timesSighted: 1
        )
        try store.upsert([stale, survivor])

        let repaired = MemoryAuditor.repairCodeRefPaths(store: store, projectId: "p", repoPath: dir.path)
        #expect(repaired == 1)

        let remaining = try store.allNodes(projectId: "p", type: .codeRef)
        #expect(remaining.count == 1)
        let merged = try #require(remaining.first)
        #expect(merged.id == survivor.id)
        #expect(merged.timesSighted == 4)   // sighting history folded in, not lost
        #expect(merged.timesApplied == 4)
        let gone = try #require(try store.node(id: stale.id))
        #expect(gone.isDeleted)
    }
}
