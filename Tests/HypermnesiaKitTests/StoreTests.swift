import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Store")
struct StoreTests {

    private func makeStore() throws -> MemoryStore { try MemoryStore(location: .inMemory) }

    private func sampleNode(
        project: String = "github.com/acme/app",
        type: MemoryType = .convention,
        title: String = "Use tabs",
        data: MemoryData = .convention(.init(rule: "Use tabs for indentation")),
        status: MemoryStatus = .confirmed,
        created: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MemoryNode {
        MemoryNode(
            projectId: project, type: type, status: status,
            title: title, summary: "summary", data: data,
            confidence: 1.0, createdAt: created, updatedAt: created, lastValidatedAt: created
        )
    }

    @Test("node round-trips through SQLite, payload intact")
    func nodeRoundTrip() throws {
        let store = try makeStore()
        let node = sampleNode(
            type: .convention,
            data: .convention(.init(rule: "Use tabs", examples: [.init(bad: "spaces", good: "tabs")]))
        )
        try store.upsert(node)

        let fetched = try #require(try store.node(id: node.id))
        #expect(fetched.title == node.title)
        #expect(fetched.type == .convention)
        #expect(fetched.confidence == 1.0)
        guard case .convention(let c) = fetched.data else { Issue.record("payload type lost"); return }
        #expect(c.examples == [.init(bad: "spaces", good: "tabs")])
        #expect(fetched.createdAt == node.createdAt) // backdated timestamp preserved
    }

    @Test("enum columns are stored cleanly so type/status filters work")
    func enumColumnFiltering() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(type: .convention, title: "conv"))
        try store.upsert(sampleNode(type: .fact, title: "fact",
                                    data: .fact(.init(category: "stack", key: "db", value: "postgres"))))

        let conventions = try store.nodes(projectId: "github.com/acme/app", type: .convention)
        #expect(conventions.count == 1)
        #expect(conventions.first?.title == "conv")

        let drafts = try store.nodes(projectId: "github.com/acme/app", status: .draft)
        #expect(drafts.isEmpty)
    }

    @Test("memories are isolated per project")
    func projectIsolation() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(project: "github.com/acme/a", title: "A"))
        try store.upsert(sampleNode(project: "github.com/acme/b", title: "B"))

        #expect(try store.nodes(projectId: "github.com/acme/a").count == 1)
        #expect(try store.nodes(projectId: "github.com/acme/b").count == 1)
        #expect(try Set(store.projects()) == ["github.com/acme/a", "github.com/acme/b"])
    }

    @Test("soft delete hides from lists and search; counts reflect it")
    func softDelete() throws {
        let store = try makeStore()
        let node = sampleNode(title: "Temporary")
        try store.upsert(node)
        try store.softDeleteNode(id: node.id)

        #expect(try store.nodes(projectId: node.projectId).isEmpty)
        #expect(try store.nodes(projectId: node.projectId, includeDeleted: true).count == 1)
        #expect(try store.search(projectId: node.projectId, query: "Temporary").isEmpty)
    }

    @Test("full-text search hits title and payload body")
    func ftsSearch() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(type: .fact, title: "Database",
                                    data: .fact(.init(category: "stack", key: "db", value: "PostgreSQL 16"))))
        try store.upsert(sampleNode(type: .convention, title: "Formatting",
                                    data: .convention(.init(rule: "Use tabs"))))

        let byBody = try store.search(projectId: "github.com/acme/app", query: "postgresql")
        #expect(byBody.count == 1)
        #expect(byBody.first?.title == "Database")

        let byTitle = try store.search(projectId: "github.com/acme/app", query: "formatting")
        #expect(byTitle.first?.title == "Formatting")
    }

    @Test("FTS scopes to the project so a busy project can't starve another's matches")
    func ftsProjectScoping() throws {
        let store = try makeStore()
        // A big project with many matches for the same term...
        for i in 0..<200 {
            try store.upsert(sampleNode(project: "github.com/big/app", title: "shared-term note \(i)",
                                        data: .convention(.init(rule: "shared-term rule \(i)"))))
        }
        // ...must not crowd out a small project's own genuine matches.
        try store.upsert(sampleNode(project: "github.com/small/app", title: "shared-term here",
                                    data: .convention(.init(rule: "shared-term small rule"))))
        let hits = try store.search(projectId: "github.com/small/app", query: "shared-term", limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.title == "shared-term here")
    }

    @Test("nodesMissingEmbedding finds the un-embedded tail past the fetch cap")
    func missingEmbeddingTail() throws {
        let store = try makeStore()
        var ids: [String] = []
        for i in 0..<30 {
            let n = sampleNode(title: "n\(i)")
            try store.upsert(n)
            ids.append(n.id)
        }
        // Embed the first 28; the 2 tail nodes have no embedding.
        for id in ids.prefix(28) { try store.setEmbedding(nodeId: id, model: "m", vector: [0.1, 0.2]) }
        // With a cap of 28, the old "fetch-then-filter" returned 0 (the fetched slice was all embedded).
        let missing = try store.nodesMissingEmbedding(projectId: "github.com/acme/app", model: "m", limit: 28)
        #expect(Set(missing.map(\.id)) == Set(ids.suffix(2)))
    }

    @Test("counts group by type")
    func counts() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(type: .convention, title: "c1"))
        try store.upsert(sampleNode(type: .convention, title: "c2"))
        try store.upsert(sampleNode(type: .fact, title: "f1",
                                    data: .fact(.init(category: "x", key: "y", value: "z"))))
        let counts = try store.counts(projectId: "github.com/acme/app")
        #expect(counts[.convention] == 2)
        #expect(counts[.fact] == 1)
    }

    @Test("edges replace cleanly")
    func edges() throws {
        let store = try makeStore()
        let p = "github.com/acme/app"
        try store.replaceEdges(projectId: p, with: [
            MemoryEdge(projectId: p, source: "a", target: "b", relationship: .relatedTo),
            MemoryEdge(projectId: p, source: "a", target: "c", relationship: .supersedes),
        ])
        #expect(try store.edges(projectId: p).count == 2)
        try store.replaceEdges(projectId: p, with: [
            MemoryEdge(projectId: p, source: "a", target: "b", relationship: .relatedTo),
        ])
        #expect(try store.edges(projectId: p).count == 1)
    }

    @Test("capture queue enqueue / drain / update")
    func captureQueue() throws {
        let store = try makeStore()
        var item = CaptureQueueItem(
            sessionId: "sess-1", projectId: "p", transcriptPath: "/t.jsonl", cwd: "/repo"
        )
        try store.enqueue(item)

        let pending = try store.pendingCaptures()
        #expect(pending.count == 1)

        item.status = .done
        try store.updateCapture(item)
        #expect(try store.pendingCaptures().isEmpty)
    }

    @Test("capture queue health separates pending, processing, retries, and terminal errors")
    func captureQueueHealth() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try store.enqueue(.init(
            sessionId: "pending", projectId: "p", transcriptPath: "/pending", cwd: "/repo",
            enqueuedAt: base, status: .pending, attempts: 0))
        try store.enqueue(.init(
            sessionId: "retry", projectId: "p", transcriptPath: "/retry", cwd: "/repo",
            enqueuedAt: base.addingTimeInterval(1), status: .pending, attempts: 2,
            lastError: "temporary classifier failure"))
        try store.enqueue(.init(
            sessionId: "processing", projectId: "p", transcriptPath: "/processing", cwd: "/repo",
            enqueuedAt: base.addingTimeInterval(2), status: .processing, attempts: 1))
        try store.enqueue(.init(
            sessionId: "failed", projectId: "p", transcriptPath: "/failed", cwd: "/repo",
            enqueuedAt: base.addingTimeInterval(3), status: .error, attempts: 5,
            lastError: "classification failed 5×"))
        try store.enqueue(.init(
            sessionId: "done", projectId: "p", transcriptPath: "/done", cwd: "/repo",
            enqueuedAt: base.addingTimeInterval(4), status: .done))

        let health = try store.captureQueueHealth()

        #expect(health.pending == 1)
        #expect(health.processing == 1)
        #expect(health.retrying == 1)
        #expect(health.terminalErrors == 1)
        #expect(health.lastError?.sessionId == "failed")
        #expect(health.lastError?.message == "classification failed 5×")
    }

    @Test("prune does not delete a snapshot still referenced by an active queue row")
    func prunePreservesSharedSnapshots() throws {
        let store = try makeStore()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = support.appendingPathComponent("host.jsonl")
        try "transcript".write(to: source, atomically: true, encoding: .utf8)
        let managed = try TranscriptSnapshotStore.snapshot(
            transcript: source, sessionId: "shared", in: support)

        // Old done row + fresh pending re-enqueue share the same managed path.
        try store.enqueue(.init(
            sessionId: "shared", projectId: "p", transcriptPath: managed.path,
            cwd: "/repo", enqueuedAt: Date().addingTimeInterval(-40 * 86_400), status: .done))
        try store.enqueue(.init(
            id: UUID().uuidString, sessionId: "shared-live", projectId: "p",
            transcriptPath: managed.path, cwd: "/repo", status: .pending))

        #expect(try store.pruneFinishedCaptures(olderThanDays: 30, supportDirectory: support) == 1)
        #expect(try store.captureQueueHealth().pending == 1)
        #expect(FileManager.default.fileExists(atPath: managed.path))
    }

    @Test("clearing failed captures preserves active rows, memories, and host transcripts")
    func clearFailedCaptures() throws {
        let store = try makeStore()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = support.appendingPathComponent("host.jsonl")
        try "transcript".write(to: source, atomically: true, encoding: .utf8)
        let managed = try TranscriptSnapshotStore.snapshot(
            transcript: source, sessionId: "failed-managed", in: support)
        let memory = sampleNode(title: "Keep me")
        try store.upsert(memory)
        try store.enqueue(.init(
            sessionId: "failed-managed", projectId: "p", transcriptPath: managed.path,
            cwd: "/repo", status: .error, attempts: 5))
        try store.enqueue(.init(
            sessionId: "failed-host", projectId: "p", transcriptPath: source.path,
            cwd: "/repo", status: .error, attempts: 5))
        try store.enqueue(.init(
            sessionId: "pending", projectId: "p", transcriptPath: source.path,
            cwd: "/repo", status: .pending))

        #expect(try store.clearFailedCaptures(supportDirectory: support) == 2)

        #expect(try store.captureQueueHealth().pending == 1)
        #expect(try store.captureQueueHealth().terminalErrors == 0)
        #expect(try store.node(id: memory.id) != nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

    @Test("processed sessions are idempotent")
    func processedSessions() throws {
        let store = try makeStore()
        #expect(try store.isProcessed(sessionId: "sess-1") == false)
        try store.markProcessed(.init(sessionId: "sess-1", projectId: "p", source: .backfill, memoryCount: 3))
        #expect(try store.isProcessed(sessionId: "sess-1") == true)
    }

    @Test("hard delete project removes related records")
    func hardDeleteProject() throws {
        let store = try makeStore()
        let p1 = "github.com/acme/a"
        let p2 = "github.com/acme/b"

        let n1 = sampleNode(project: p1, title: "A1")
        let n2 = sampleNode(project: p1, title: "A2")
        let n3 = sampleNode(project: p2, title: "B1")
        try store.upsert([n1, n2, n3])
        try store.setEmbedding(nodeId: n1.id, model: "test", vector: [0.1, 0.2])
        try store.replaceEdges(projectId: p1, with: [
            MemoryEdge(projectId: p1, source: n1.id, target: n2.id, relationship: .relatedTo)
        ])
        try store.enqueue(CaptureQueueItem(sessionId: "sess-delete", projectId: p1, transcriptPath: "/t", cwd: "/repo"))
        try store.setCursor(sessionId: "sess-delete", projectId: p1, count: 3)
        try store.markProcessed(.init(sessionId: "sess-delete", projectId: p1, source: .live, memoryCount: 2))

        let removed = try store.hardDeleteProject(projectId: p1)
        #expect(removed == 2)
        #expect(try store.projects() == [p2])
        #expect(try store.nodes(projectId: p1).isEmpty)
        #expect(try store.search(projectId: p1, query: "A1").isEmpty)
        #expect(try store.edges(projectId: p1).isEmpty)
        #expect(try store.pendingCaptures().isEmpty)
        #expect(try store.isProcessed(sessionId: "sess-delete") == false)
    }

    @Test("hard delete all clears projects and search")
    func hardDeleteAllMemories() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(project: "github.com/acme/a", title: "A1"))
        try store.upsert(sampleNode(project: "github.com/acme/b", title: "B1"))

        let removed = try store.hardDeleteAllMemories()
        #expect(removed == 2)
        #expect(try store.projects().isEmpty)
        #expect(try store.nodes(projectId: "github.com/acme/a").isEmpty)
        #expect(try store.search(projectId: "github.com/acme/b", query: "B1").isEmpty)
    }
}
