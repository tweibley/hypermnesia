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
}
