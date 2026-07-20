import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression coverage for the H2 conflict-sweep clobber bug: when three (or more) generations of
/// the same memory exist, `sweep` must retire every obsolete generation and leave only the newest
/// live. The original loop re-persisted an immutable snapshot of a middle memory, erasing the
/// `supersededById` a prior iteration had just written — so the middle generation stayed live and
/// kept injecting alongside the memory that replaced it.
@Suite("BugFix H2 conflict sweep")
struct BugFixH2ConflictSweepTests {

    private let project = "github.com/acme/app"

    private func decision(
        _ title: String, chosen: String, id: String = UUID().uuidString, createdAt: Date
    ) -> MemoryNode {
        MemoryNode(id: id, projectId: project, type: .decision, status: .confirmed,
                   title: title, summary: chosen, data: .decision(.init(chosen: chosen)),
                   createdAt: createdAt)
    }

    @Test("sweep retires every obsolete generation in a three-memory chain, leaving only the newest live")
    func sweepChainLeavesOnlyNewestLive() throws {
        let store = try MemoryStore(location: .inMemory)
        let title = "Database engine for local storage"
        // Y (oldest) → X (middle) → N (newest), same topic, materially different content.
        let y = decision(title, chosen: "Use MySQL with a pooled connector",
                         createdAt: Date(timeIntervalSinceNow: -2 * 86_400))
        let x = decision(title, chosen: "Use Postgres for the local store",
                         createdAt: Date(timeIntervalSinceNow: -1 * 86_400))
        let n = decision(title, chosen: "Use SQLite via GRDB instead",
                         createdAt: Date())
        try store.upsert([y, x, n])

        _ = ConflictEngine.sweep(store: store, projectId: project)

        // The newest is the sole survivor and is NOT itself retired.
        let nAfter = try #require(try store.node(id: n.id))
        #expect(nAfter.isSuperseded == false)

        // Both older generations are retired — the middle one's retirement is NOT clobbered.
        #expect(try #require(try store.node(id: x.id)).isSuperseded == true)
        #expect(try #require(try store.node(id: y.id)).isSuperseded == true)

        // Only one memory hydrates — the two contradictory obsolete rules are gone.
        let live = try store.allNodes(projectId: project, status: .confirmed)
            .filter { !$0.isSuperseded && !$0.isDeleted }
        #expect(live.map(\.id) == [n.id])

        // Idempotent: a second pass finds nothing left to reconcile.
        #expect(ConflictEngine.sweep(store: store, projectId: project) == 0)
    }
}
