import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Triage")
struct TriageTests {
    private func draft() -> MemoryNode {
        MemoryNode(projectId: "p", type: .convention, status: .draft, title: "Use tabs",
                   summary: "Always use tabs for indentation",
                   data: .convention(.init(rule: "Always use tabs for indentation")), confidence: 0.8)
    }
    private func duplicate() -> MemoryNode {
        MemoryNode(projectId: "p", type: .convention, status: .draft, title: "Tabs",
                   summary: "Always use tabs for indentation in code",
                   data: .convention(.init(rule: "Always use tabs for indentation in code")))
    }

    @Test("a repeated sighting reinforces and auto-confirms a draft")
    func reinforcementAutoConfirms() throws {
        let store = try MemoryStore(location: .inMemory)
        let existing = draft()
        try store.upsert(existing)

        let fresh = SessionIngestor.reconcile([duplicate()], projectId: "p", store: store, autoConfirm: 1)
        #expect(fresh.isEmpty)   // the duplicate is not inserted as a new memory

        let updated = try #require(try store.node(id: existing.id))
        #expect(updated.status == .confirmed)   // 1 repeat sighting ≥ threshold → confirmed
        #expect(updated.timesApplied == 1)
    }

    @Test("auto-confirm disabled reinforces but leaves the draft a draft")
    func reinforcementWithoutAutoConfirm() throws {
        let store = try MemoryStore(location: .inMemory)
        let existing = draft()
        try store.upsert(existing)

        _ = SessionIngestor.reconcile([duplicate()], projectId: "p", store: store, autoConfirm: 0)
        let updated = try #require(try store.node(id: existing.id))
        #expect(updated.status == .draft)
        #expect(updated.timesApplied == 1)   // still reinforced
    }

    @Test("reinforcement does not reset confidence (preserves an audit penalty)")
    func reinforcementPreservesConfidence() throws {
        let store = try MemoryStore(location: .inMemory)
        var penalized = draft()
        penalized.confidence = 0.3   // as if an audit flagged it
        try store.upsert(penalized)

        _ = SessionIngestor.reconcile([duplicate()], projectId: "p", store: store, autoConfirm: 0)
        let updated = try #require(try store.node(id: penalized.id))
        #expect(updated.confidence == 0.3)   // not reset to fresh
        #expect(updated.timesApplied == 1)
    }

    @Test("duplicate reinforcement uses the supplied observation time")
    func reinforcementObservationTime() throws {
        let store = try MemoryStore(location: .inMemory)
        let existing = draft()
        try store.upsert(existing)
        let historicalEnd = Date(timeIntervalSince1970: 1_600_000_000)

        _ = SessionIngestor.reconcile(
            [duplicate()], projectId: "p", store: store, autoConfirm: 0,
            observationAt: historicalEnd
        )

        let updated = try #require(try store.node(id: existing.id))
        #expect(updated.lastValidatedAt == historicalEnd)
        #expect(updated.updatedAt == historicalEnd)
    }

    @Test("a genuinely new memory is inserted")
    func newMemoryInserted() throws {
        let store = try MemoryStore(location: .inMemory)
        try store.upsert(draft())
        let novel = MemoryNode(projectId: "p", type: .fact, title: "Runtime is Swift 6",
                               summary: "the engine builds under Swift 6 strict concurrency",
                               data: .fact(.init(category: "stack", key: "swift", value: "6")))
        let fresh = SessionIngestor.reconcile([novel], projectId: "p", store: store, autoConfirm: 2)
        #expect(fresh.count == 1)
    }

    @Test("confirmation atomically supersedes, purges duplicates, and returns undo snapshots")
    func centralizedConfirmation() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = MemoryNode(
            projectId: "p", type: .fact, status: .confirmed,
            title: "API version", summary: "The API uses version one",
            data: .fact(.init(category: "api", key: "version", value: "v1"))
        )
        var revision = MemoryNode(
            projectId: "p", type: .fact, status: .draft,
            title: "API version two", summary: "The API now uses version two",
            data: .fact(.init(category: "api", key: "version", value: "v2"))
        )
        revision.supersedesId = old.id
        let duplicate = MemoryNode(
            projectId: "p", type: .fact, status: .draft,
            title: "API version two", summary: "The API now uses version two",
            data: .fact(.init(category: "api", key: "version", value: "v2"))
        )
        try store.upsert([old, revision, duplicate])

        let result = try MemoryTriageService.confirm(
            nodeIDs: [revision.id, duplicate.id], store: store,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(result.confirmed == 1)
        #expect(try store.node(id: revision.id)?.status == .confirmed)
        #expect(try store.node(id: old.id)?.supersededById == revision.id)
        #expect(try store.node(id: duplicate.id)?.isDeleted == true)
        #expect(Set(result.snapshots.map(\.id)) == Set([old.id, revision.id, duplicate.id]))

        try store.upsert(result.snapshots)
        #expect(try store.node(id: revision.id)?.status == .draft)
        #expect(try store.node(id: old.id)?.supersededById == nil)
        #expect(try store.node(id: duplicate.id)?.isDeleted == false)
    }

    @Test("single and selected confirmation paths apply identical triage semantics")
    func sharedConfirmationPaths() throws {
        func fixture() throws -> (MemoryStore, MemoryNode, MemoryNode, MemoryNode) {
            let store = try MemoryStore(location: .inMemory)
            let old = MemoryNode(
                id: "old", projectId: "p", type: .fact, status: .confirmed,
                title: "API version", summary: "The API uses version one",
                data: .fact(.init(category: "api", key: "version", value: "v1"))
            )
            let revision = MemoryNode(
                id: "revision", projectId: "p", type: .fact, status: .draft,
                title: "API version two", summary: "The API now uses version two",
                data: .fact(.init(category: "api", key: "version", value: "v2")),
                supersedesId: old.id
            )
            let duplicate = MemoryNode(
                id: "duplicate", projectId: "p", type: .fact, status: .draft,
                title: "API version two", summary: "The API now uses version two",
                data: .fact(.init(category: "api", key: "version", value: "v2"))
            )
            try store.upsert([old, revision, duplicate])
            return (store, old, revision, duplicate)
        }

        let (singleStore, old, revision, duplicate) = try fixture()
        let single = try MemoryTriageService.confirm(nodeIDs: [revision.id], store: singleStore)
        let (selectedStore, _, _, _) = try fixture()
        let selected = try MemoryTriageService.confirm(
            nodeIDs: [revision.id, duplicate.id], store: selectedStore)

        for store in [singleStore, selectedStore] {
            #expect(try store.node(id: revision.id)?.status == .confirmed)
            #expect(try store.node(id: old.id)?.supersededById == revision.id)
            #expect(try store.node(id: duplicate.id)?.isDeleted == true)
        }
        #expect(single.confirmed == selected.confirmed)
        #expect(Set(single.snapshots.map(\.id)) == Set(selected.snapshots.map(\.id)))
    }

    @Test("capture dedup considers same-type memories beyond the newest 500")
    func captureDedupUsesCompleteCorpus() throws {
        let store = try MemoryStore(location: .inMemory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let target = MemoryNode(
            projectId: "p", type: .convention, status: .draft, title: "Use tabs",
            summary: "Always use tabs for indentation",
            data: .convention(.init(rule: "Always use tabs for indentation")),
            confidence: 0.8, createdAt: base, updatedAt: base
        )
        var nodes = [target]
        nodes += (0..<500).map { index in
            MemoryNode(
                projectId: "p", type: .convention, status: .confirmed,
                title: "Unrelated \(index)", summary: "Distinct convention number \(index)",
                data: .convention(.init(rule: "Distinct convention number \(index)")),
                createdAt: base.addingTimeInterval(Double(index + 1)),
                updatedAt: base.addingTimeInterval(Double(index + 1))
            )
        }
        try store.upsert(nodes)

        let fresh = SessionIngestor.reconcile(
            [duplicate()], projectId: "p", store: store, autoConfirm: 0
        )

        #expect(fresh.isEmpty)
        #expect(try store.node(id: target.id)?.timesApplied == 1)
    }
}
