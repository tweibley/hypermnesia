import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("MemoryAnalytics")
struct MemoryAnalyticsTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func convention(
        belief: Double?, ageDays: Int, confidence: Double = 1.0,
        status: MemoryStatus = .confirmed, timesApplied: Int = 0, timesOverridden: Int = 0,
        timesAppliedSuccess: Int = 0, supersededById: String? = nil
    ) -> MemoryNode {
        let created = now.addingTimeInterval(-Double(ageDays) * 86_400)
        return MemoryNode(
            projectId: "p", type: .convention, status: status, title: "t", summary: "s",
            data: .convention(.init(rule: "r")), confidence: confidence, belief: belief,
            createdAt: created, updatedAt: created, lastValidatedAt: nil,
            supersededById: supersededById,
            timesApplied: timesApplied, timesOverridden: timesOverridden,
            timesSighted: 0, timesAppliedSuccess: timesAppliedSuccess)
    }

    // MARK: confidence breakdown

    @Test("belief × freshness reconciles to the displayed confidence; belief recovers the model prior")
    func beliefDecomposition() {
        // Model-consistent belief node: stored confidence = belief × freshness(45d).
        let stored = 0.8 * DecayEngine.ageMultiplier(ageDays: 45)
        let vm = MemoryAnalytics.confidenceBreakdown(for: convention(belief: 0.8, ageDays: 45, confidence: stored), now: now)
        #expect(vm.usesBeliefModel)
        #expect(vm.decays)
        #expect(abs(vm.freshness - 0.74) < 1e-9)                       // aging band
        #expect(abs(vm.confidence - stored) < 1e-9)                    // == the value the badge shows
        #expect(abs(vm.belief - 0.8) < 1e-9)                           // residual recovers the prior
        #expect(abs(vm.belief * vm.freshness - vm.confidence) < 1e-9)  // formula holds
    }

    @Test("the card never contradicts the badge — it explains the STORED confidence, not a recompute")
    func storedConfidenceConsistency() {
        // The seeded draft: legacy node stored at 0.8 but only 1 day old (the age formula would say 1.0).
        // The card must report 0.8 to match the list badge — regression test for that exact screenshot bug.
        let draft = convention(belief: nil, ageDays: 1, confidence: 0.8, status: .draft)
        let vm = MemoryAnalytics.confidenceBreakdown(for: draft, now: now)
        #expect(abs(vm.confidence - 0.8) < 1e-9)                       // NOT recomputed to 1.0
        #expect(abs(vm.freshness - 1.0) < 1e-9)                        // fresh (1 day)
        #expect(abs(vm.belief - 0.8) < 1e-9)                           // → low because untrusted, not old
    }

    @Test("belief isolates 'low because untrusted' (full freshness) from 'low because old' (full belief)")
    func beliefVsFreshness() {
        // Untrusted but fresh: stored 0.4 at 5 days → belief 40%, freshness 100%.
        // Override rate = overrides / (successes + overrides) = 5 / (5 + 5) = 0.5.
        let untrusted = MemoryAnalytics.confidenceBreakdown(
            for: convention(belief: nil, ageDays: 5, confidence: 0.4, timesApplied: 10,
                            timesOverridden: 5, timesAppliedSuccess: 5), now: now)
        #expect(abs(untrusted.freshness - 1.0) < 1e-9)
        #expect(abs(untrusted.belief - 0.4) < 1e-9)
        #expect(abs(untrusted.overrideRate - 0.5) < 1e-9)

        // Trusted but old: stored 0.49 at 120 days → belief 100%, freshness 49% (stale band).
        let old = MemoryAnalytics.confidenceBreakdown(for: convention(belief: nil, ageDays: 120, confidence: 0.49), now: now)
        #expect(abs(old.freshness - 0.49) < 1e-9)
        #expect(abs(old.belief - 1.0) < 1e-9)
    }

    @Test("non-decaying types report full freshness and hold confidence as belief")
    func nonDecayingFreshness() {
        let fact = MemoryNode(projectId: "p", type: .fact, status: .confirmed, title: "t", summary: "s",
                              data: .fact(.init(category: "c", key: "k", value: "v")),
                              confidence: 0.9,
                              createdAt: now.addingTimeInterval(-400 * 86_400))   // very old
        let vm = MemoryAnalytics.confidenceBreakdown(for: fact, now: now)
        #expect(!vm.decays)
        #expect(abs(vm.freshness - 1.0) < 1e-9)                        // doesn't age
        #expect(abs(vm.belief - 0.9) < 1e-9)
        #expect(abs(vm.confidence - 0.9) < 1e-9)
    }

    // MARK: timeline

    @Test("timeline emits a created event and decay transitions that have already elapsed")
    func timelineTransitions() {
        let tl = MemoryAnalytics.timeline(for: convention(belief: 0.9, ageDays: 100), now: now)
        #expect(tl.events.first?.kind == .created)
        let transitions = tl.events.filter { $0.kind == .decayTransition }
        #expect(transitions.count == 2)                                // crossed 30d (aging) + 90d (stale), not 180d
        // sorted ascending
        #expect(tl.events.map(\.timestamp) == tl.events.map(\.timestamp).sorted())
        #expect(tl.trend == .down)                                     // aged past fresh
    }

    @Test("non-decaying types never produce decay-transition markers")
    func timelineNoTransitionsForFacts() {
        let fact = MemoryNode(projectId: "p", type: .fact, title: "t", summary: "s",
                              data: .fact(.init(category: "c", key: "k", value: "v")),
                              createdAt: now.addingTimeInterval(-400 * 86_400))
        let tl = MemoryAnalytics.timeline(for: fact, now: now)
        #expect(!tl.events.contains { $0.kind == .decayTransition })
    }

    @Test("override + success counters surface as aggregate timeline markers")
    func timelineReinforcement() {
        let tl = MemoryAnalytics.timeline(
            for: convention(belief: 0.8, ageDays: 5, timesApplied: 4, timesOverridden: 2, timesAppliedSuccess: 1),
            now: now)
        #expect(tl.events.contains { $0.kind == .reinforced })
        #expect(tl.events.contains { $0.kind == .overridden })
    }

    // MARK: project trends

    @Test("project trends bucket by creation day and compute snapshot KPIs")
    func projectTrends() {
        let nodes = [
            convention(belief: 0.9, ageDays: 0, confidence: 1.0, status: .confirmed),      // today, fresh, injectable
            convention(belief: 0.9, ageDays: 0, confidence: 1.0, status: .draft),          // today, draft
            convention(belief: 0.9, ageDays: 2, confidence: 1.0, status: .confirmed),      // 2d ago, confirmed
            convention(belief: 0.2, ageDays: 200, confidence: 0.2, status: .confirmed),    // below injection threshold
        ]
        let vm = MemoryAnalytics.projectTrends(nodes: nodes, window: .days7, now: now)
        #expect(vm.newMemories.count == 7)
        #expect(vm.newMemories.last?.value == 2)                       // two created "today"
        #expect(vm.confirmedMemories.last?.value == 1)                 // one of today's is a draft
        // 4 total, 3 confirmed → confirmedRate 0.75
        #expect(abs(vm.kpis.confirmedRate - 0.75) < 1e-9)
        // injection pool = 3 confirmed non-superseded; one (belief 0.2, 200d) is below 0.50.
        #expect(abs(vm.kpis.belowInjectionThresholdRate - (1.0 / 3.0)) < 1e-9)
    }

    @Test("aggregate override rate = Σoverridden / max(Σ(successes+overrides), 1)")
    func aggregateOverrideRate() {
        // Denominator is application outcomes (successes + overrides), matching
        // BeliefEngine.applicationFactor — never the legacy sighting counter (timesApplied).
        // Σoverridden = 5, Σsuccesses = 15 → 5 / (15 + 5) = 5/20.
        let nodes = [
            convention(belief: 0.9, ageDays: 1, timesApplied: 10, timesOverridden: 2, timesAppliedSuccess: 8),
            convention(belief: 0.9, ageDays: 1, timesApplied: 10, timesOverridden: 3, timesAppliedSuccess: 7),
        ]
        let vm = MemoryAnalytics.projectTrends(nodes: nodes, window: .days7, now: now)
        #expect(abs(vm.kpis.aggregateOverrideRate - (5.0 / 20.0)) < 1e-9)
    }
}
