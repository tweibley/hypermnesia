import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression tests for the "MED-store" bug cluster:
///  1. Erase paths (`hardDeleteAllMemories` / `hardDeleteProject`) must also wipe the v9 Dream Journal.
///  2. The FTS keyword-recall fallback (`MemoryStore.search`) must use OR semantics, so a
///     natural-language recall query surfaces a relevant memory instead of failing closed.
///  3. `MemoryAnalytics` override-rate must divide by application outcomes
///     (`timesAppliedSuccess + timesOverridden`), never by the legacy re-capture sighting counter.
@Suite("BugFix MED-store")
struct BugFix_MEDstoreTests {

    private func makeStore() throws -> MemoryStore { try MemoryStore(location: .inMemory) }

    private func node(
        project: String = "github.com/acme/app",
        type: MemoryType = .convention,
        title: String = "Storage convention",
        rule: String = "All storage goes through a GRDB DatabaseQueue in the app",
        confidence: Double = 1.0,
        timesApplied: Int = 0,
        timesOverridden: Int = 0,
        timesAppliedSuccess: Int = 0
    ) -> MemoryNode {
        // Validate "now" so decay-on-read keeps the node above the hydrator's 0.50 injection floor;
        // a fixed epoch would age past the dormant boundary and be filtered out before the FTS
        // keyword fallback ever runs, masking the OR-semantics behavior this suite is asserting.
        let now = Date()
        return MemoryNode(
            projectId: project, type: type, status: .confirmed,
            title: title, summary: rule, data: .convention(.init(rule: rule)),
            confidence: confidence, createdAt: now, updatedAt: now, lastValidatedAt: now,
            timesApplied: timesApplied, timesOverridden: timesOverridden,
            timesAppliedSuccess: timesAppliedSuccess)
    }

    private func dream(project: String, night: String) -> DreamJournalEntry {
        DreamJournalEntry(
            projectId: project, night: night, outcome: .dreamed,
            narrative: "a narrative synthesized from erased memories",
            payload: DreamPayload(stats: .init(
                sessionsScanned: 1, memoriesConsidered: 2, classifier: "test", calls: 1)),
            unread: true, calls: 1)
    }

    // MARK: - Bug 1: erase must include the Dream Journal

    @Test("hardDeleteAllMemories also wipes the Dream Journal")
    func hardDeleteAllRemovesDreams() throws {
        let store = try makeStore()
        try store.upsert(node(project: "p1"))
        try store.upsert(node(project: "p2"))
        try store.upsertDreamEntry(dream(project: "p1", night: "2026-07-17"))
        try store.upsertDreamEntry(dream(project: "p2", night: "2026-07-18"))

        try store.hardDeleteAllMemories()

        #expect(try store.dreamEntries().isEmpty)
        #expect(try store.unreadDreamEntries().isEmpty)
        #expect(try store.latestDreamNight(projectId: "p1") == nil)
        #expect(try store.latestDreamNight(projectId: "p2") == nil)
    }

    @Test("hardDeleteProject wipes only that project's Dream Journal rows")
    func hardDeleteProjectRemovesDreams() throws {
        let store = try makeStore()
        try store.upsert(node(project: "keep"))
        try store.upsert(node(project: "wipe"))
        try store.upsertDreamEntry(dream(project: "keep", night: "2026-07-17"))
        try store.upsertDreamEntry(dream(project: "wipe", night: "2026-07-17"))

        try store.hardDeleteProject(projectId: "wipe")

        #expect(try store.dreamEntries(projectId: "wipe").isEmpty)
        #expect(try store.latestDreamNight(projectId: "wipe") == nil)
        // Untouched project keeps its journal.
        #expect(try store.dreamEntries(projectId: "keep").count == 1)
        #expect(try store.latestDreamNight(projectId: "keep") == "2026-07-17")
    }

    // MARK: - Bug 4: keyword fallback uses OR, not implicit AND

    @Test("natural-language query surfaces a memory even though not every token matches")
    func keywordFallbackUsesOr() throws {
        let store = try makeStore()
        try store.upsert(node())

        // A full sentence: under FTS5 implicit AND this returned zero (no memory contains all of
        // {how, do, we, handle, storage, in, the, app}); with OR + rank it must surface the match.
        let hits = try store.search(
            projectId: "github.com/acme/app",
            query: "how do we handle storage in the app?")
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Storage convention")

        // A query that shares no meaningful token still returns nothing.
        #expect(try store.search(
            projectId: "github.com/acme/app",
            query: "what colour is the login button").isEmpty)
    }

    @Test("hydrator keyword fallback (no embedder) returns relevant context")
    func hydratorFallbackNoEmbedder() throws {
        let store = try makeStore()
        try store.upsert(node(
            title: "Auth tokens live in the keychain",
            rule: "Never write auth tokens to UserDefaults; use the keychain wrapper."))

        let result = MemoryHydrator.relevantContextResult(
            store: store, projectId: "github.com/acme/app",
            query: "how should I handle authentication tokens in the API layer",
            embedder: nil)
        #expect(result != nil)
        #expect(result?.memories.contains { $0.title == "Auth tokens live in the keychain" } == true)
    }

    // MARK: - Bug 3: override-rate divisor

    @Test("override rate divides by application outcomes, not the sighting counter")
    func overrideRateDenominator() throws {
        // A memory sighted 0 times, applied successfully once, overridden once → 50%, not 100%+.
        let drifted = node(timesApplied: 0, timesOverridden: 1, timesAppliedSuccess: 1)
        let vm = MemoryAnalytics.confidenceBreakdown(for: drifted)
        #expect(vm.overrideRate == 0.5)

        // Never applied, one override (the old bug produced 1.0 / 100%+): denominator clamps to 1.
        let neverApplied = node(timesApplied: 0, timesOverridden: 1, timesAppliedSuccess: 0)
        #expect(MemoryAnalytics.confidenceBreakdown(for: neverApplied).overrideRate == 1.0)

        // A pile of legacy sightings must NOT dilute the override rate down toward zero.
        let manySightings = node(timesApplied: 99, timesOverridden: 1, timesAppliedSuccess: 1)
        #expect(MemoryAnalytics.confidenceBreakdown(for: manySightings).overrideRate == 0.5)
    }

    @Test("timeline reinforcement reflects successful applications, not sightings")
    func timelineReinforcement() throws {
        // Only sighted (legacy counter), never applied in code → no "Reinforced" event.
        let sightedOnly = node(timesApplied: 3, timesOverridden: 0, timesAppliedSuccess: 0)
        let tl1 = MemoryAnalytics.timeline(for: sightedOnly)
        #expect(!tl1.events.contains { $0.kind == .reinforced })

        // Two successful applications → "Reinforced" event reporting the real count.
        let applied = node(timesApplied: 0, timesOverridden: 0, timesAppliedSuccess: 2)
        let tl2 = MemoryAnalytics.timeline(for: applied)
        let event = try #require(tl2.events.first { $0.kind == .reinforced })
        #expect(event.detail.contains("2×"))
        #expect(!event.detail.contains("0×"))
    }

    @Test("aggregate override-rate KPI uses application outcomes")
    func aggregateOverrideRate() throws {
        // Across the project: 2 successful applications, 2 overrides → 50%.
        // Legacy sightings (timesApplied) must not enter the denominator.
        let nodes = [
            node(timesApplied: 50, timesOverridden: 1, timesAppliedSuccess: 1),
            node(timesApplied: 50, timesOverridden: 1, timesAppliedSuccess: 1),
        ]
        let vm = MemoryAnalytics.projectTrends(nodes: nodes, window: .days30)
        #expect(vm.kpis.aggregateOverrideRate == 0.5)
    }
}
