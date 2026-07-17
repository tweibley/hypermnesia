import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("ConflictEngine")
struct ConflictTests {

    private let project = "github.com/acme/app"

    private func decision(
        _ title: String, chosen: String, id: String = UUID().uuidString, createdAt: Date = Date()
    ) -> MemoryNode {
        MemoryNode(id: id, projectId: project, type: .decision, status: .confirmed,
                   title: title, summary: chosen, data: .decision(.init(chosen: chosen)),
                   createdAt: createdAt)
    }

    private func fact(category: String, key: String, value: String) -> MemoryNode {
        MemoryNode(projectId: project, type: .fact, status: .confirmed,
                   title: "\(category): \(key)", summary: value,
                   data: .fact(.init(category: category, key: key, value: value)))
    }

    @Test("a fact with the same key but a different value conflicts; same value doesn't")
    func factRevisionDetected() {
        let old = fact(category: "stack", key: "database", value: "postgres")
        let revised = fact(category: "stack", key: "database", value: "sqlite")
        #expect(ConflictEngine.conflict(of: revised, in: [old])?.id == old.id)

        let unrelated = fact(category: "stack", key: "cache", value: "redis")
        #expect(ConflictEngine.conflict(of: unrelated, in: [old]) == nil)
    }

    @Test("a decision revising the same subject conflicts; a near-duplicate reinforces instead")
    func decisionRevisionVsDuplicate() {
        let old = decision("Database engine for local storage", chosen: "Use Postgres for the local store")
        let revised = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        // Same title, different substance → conflict.
        #expect(ConflictEngine.conflict(of: revised, in: [old])?.id == old.id)

        // Near-identical text is a duplicate (reinforcement), never a conflict.
        let dup = decision("Database engine for local storage", chosen: "Use Postgres for the local store")
        #expect(DedupEngine.isDuplicate(dup, old))
        #expect(ConflictEngine.conflict(of: dup, in: [old]) == nil)

        // A different subject entirely → no conflict.
        let other = decision("HTTP client library", chosen: "Use URLSession directly")
        #expect(ConflictEngine.conflict(of: other, in: [old]) == nil)
    }

    @Test("already-superseded and deleted memories are never conflict targets")
    func supersededAndDeletedExcluded() {
        var old = decision("Database engine for local storage", chosen: "Use Postgres")
        old.supersededById = "newer"
        let revised = decision("Database engine for local storage", chosen: "Use SQLite instead")
        #expect(ConflictEngine.conflict(of: revised, in: [old]) == nil)

        var gone = decision("Database engine for local storage", chosen: "Use MySQL")
        gone.supersededById = nil
        gone.deletedAt = Date()
        #expect(ConflictEngine.conflict(of: revised, in: [gone]) == nil)
    }

    @Test("applySupersede marks the old memory superseded only for a confirmed reviser")
    func applySupersedeRespectsConfirmGate() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = decision("Database engine for local storage", chosen: "Use Postgres")
        try store.upsert(old)

        var draft = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        draft.status = .draft
        draft.supersedesId = old.id
        try store.upsert(draft)

        // Draft status: no effect (dismissing a draft must leave the old memory alone).
        ConflictEngine.applySupersede(for: draft, store: store)
        #expect(try #require(try store.node(id: old.id)).isSuperseded == false)

        // Confirmed: the old memory is now superseded and drops out of hydration.
        draft.status = .confirmed
        try store.upsert(draft)
        ConflictEngine.applySupersede(for: draft, store: store)
        let oldAfter = try #require(try store.node(id: old.id))
        #expect(oldAfter.supersededById == draft.id)
    }

    @Test("sweep retires the older of two conflicting confirmed memories, newer-wins")
    func sweepNewerWins() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = decision("Database engine for local storage", chosen: "Use Postgres for the local store",
                           createdAt: Date(timeIntervalSinceNow: -86_400))
        let new = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        try store.upsert([old, new])

        let applied = ConflictEngine.sweep(store: store, projectId: project)
        #expect(applied == 1)
        #expect(try #require(try store.node(id: old.id)).supersededById == new.id)
        #expect(try #require(try store.node(id: new.id)).supersedesId == old.id)

        // Idempotent: a second pass finds nothing left to do.
        #expect(ConflictEngine.sweep(store: store, projectId: project) == 0)
    }

    @Test("sweep never re-retires a pair the user restored")
    func sweepRespectsRestore() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = decision("Database engine for local storage", chosen: "Use Postgres for the local store",
                           createdAt: Date(timeIntervalSinceNow: -86_400))
        let new = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        try store.upsert([old, new])
        #expect(ConflictEngine.sweep(store: store, projectId: project) == 1)

        // Restore clears supersededById but leaves the reviser's supersedesId as a tombstone.
        var restored = try #require(try store.node(id: old.id))
        restored.supersededById = nil
        try store.upsert(restored)

        #expect(ConflictEngine.sweep(store: store, projectId: project) == 0)
        #expect(try #require(try store.node(id: old.id)).isSuperseded == false)
    }

    @Test("sweep ignores drafts — the human gate still owns those")
    func sweepIgnoresDrafts() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = decision("Database engine for local storage", chosen: "Use Postgres for the local store",
                           createdAt: Date(timeIntervalSinceNow: -86_400))
        var draft = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        draft.status = .draft
        try store.upsert([old, draft])

        #expect(ConflictEngine.sweep(store: store, projectId: project) == 0)
        #expect(try #require(try store.node(id: old.id)).isSuperseded == false)
    }

    @Test("confident captures auto-confirm; weak, low-confidence, and revision captures stay drafts")
    func confidentCaptureAutoConfirm() throws {
        let store = try MemoryStore(location: .inMemory)

        // Clean, high-confidence, nothing contradicted → goes live immediately.
        var confident = decision("HTTP client library", chosen: "Use URLSession directly")
        confident.status = .draft
        confident.confidence = 0.92
        let live = SessionIngestor.reconcile([confident], projectId: project, store: store,
                                             autoConfirm: 0, confirmConfident: true)
        #expect(live.first?.status == .confirmed)

        // Below the floor → draft.
        var tentative = decision("Retry policy for uploads", chosen: "Exponential backoff, 3 tries")
        tentative.status = .draft
        tentative.confidence = 0.6
        let held = SessionIngestor.reconcile([tentative], projectId: project, store: store,
                                             autoConfirm: 0, confirmConfident: true)
        #expect(held.first?.status == .draft)

        // A revision NEVER auto-confirms, no matter how confident — it would retire an accepted memory.
        let old = decision("Database engine for local storage", chosen: "Use Postgres for the local store")
        try store.upsert(old)
        var revision = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        revision.status = .draft
        revision.confidence = 0.99
        let gated = SessionIngestor.reconcile([revision], projectId: project, store: store,
                                              autoConfirm: 0, confirmConfident: true)
        #expect(gated.first?.status == .draft)
        #expect(gated.first?.supersedesId == old.id)

        // Feature off → everything stays a draft.
        var offCase = decision("Logging format", chosen: "Structured JSON lines")
        offCase.status = .draft
        offCase.confidence = 0.95
        let off = SessionIngestor.reconcile([offCase], projectId: project, store: store,
                                            autoConfirm: 0, confirmConfident: false)
        #expect(off.first?.status == .draft)
    }

    @Test("retriage settles a pre-existing draft backlog by the same policy as new captures")
    func retriageDraftBacklog() throws {
        let store = try MemoryStore(location: .inMemory)

        func draft(_ title: String, confidence: Double, conversationId: String?,
                   supersedesId: String? = nil, ageDays: Double = 0) -> MemoryNode {
            let when = Date(timeIntervalSinceNow: -ageDays * 86_400)
            return MemoryNode(projectId: project, type: .convention, status: .draft,
                              title: title, summary: title, data: .convention(.init(rule: title)),
                              confidence: confidence, belief: confidence,
                              createdAt: when, updatedAt: when, lastValidatedAt: when,
                              supersedesId: supersedesId, conversationId: conversationId)
        }

        let confident = draft("Always use structured logging in services", confidence: 0.93, conversationId: "s1")
        let weak = draft("Maybe prefer tabs in generated fixtures", confidence: 0.5, conversationId: "s1")
        let agentWrite = draft("Deploy fridays are fine actually", confidence: 0.95, conversationId: nil)
        let old = decision("Database engine for local storage", chosen: "Use Postgres")
        try store.upsert(old)
        let revision = draft("Database engine for local storage", confidence: 0.97,
                             conversationId: "s2", supersedesId: old.id)
        try store.upsert([confident, weak, agentWrite, revision])

        let confirmed = SessionIngestor.retriageDrafts(store: store, projectId: project, confirmConfident: true)
        #expect(confirmed == 1)
        #expect(try #require(try store.node(id: confident.id)).status == .confirmed)
        #expect(try #require(try store.node(id: weak.id)).status == .draft)        // under the floor
        #expect(try #require(try store.node(id: agentWrite.id)).status == .draft)  // MCP remember stays gated
        #expect(try #require(try store.node(id: revision.id)).status == .draft)    // revisions need a human

        // Idempotent, and a no-op when the policy is off.
        #expect(SessionIngestor.retriageDrafts(store: store, projectId: project, confirmConfident: true) == 0)
        #expect(SessionIngestor.retriageDrafts(store: store, projectId: project, confirmConfident: false) == 0)
    }

    @Test("reconcile links a captured revision via supersedesId (draft-gated)")
    func reconcileLinksConflict() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = decision("Database engine for local storage", chosen: "Use Postgres for the local store")
        try store.upsert(old)

        var candidate = decision("Database engine for local storage", chosen: "Use SQLite via GRDB instead")
        candidate.status = .draft
        let fresh = SessionIngestor.reconcile([candidate], projectId: project, store: store, autoConfirm: 0)

        let linked = try #require(fresh.first)
        #expect(linked.supersedesId == old.id)
        // Capture alone must NOT supersede — the old memory stays live until the draft is confirmed.
        #expect(try #require(try store.node(id: old.id)).isSuperseded == false)
    }
}
