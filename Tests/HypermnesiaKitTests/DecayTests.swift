import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Decay")
struct DecayTests {

    @Test("age multiplier follows the 30/90/180-day buckets")
    func ageBuckets() {
        #expect(DecayEngine.ageMultiplier(ageDays: 0) == 1.00)
        #expect(DecayEngine.ageMultiplier(ageDays: 29) == 1.00)
        #expect(DecayEngine.ageMultiplier(ageDays: 45) == 0.74)
        #expect(DecayEngine.ageMultiplier(ageDays: 120) == 0.49)
        #expect(DecayEngine.ageMultiplier(ageDays: 365) == 0.24)
    }

    @Test("override rate over 30% halves confidence")
    func overridePenalty() {
        // 45 days (0.74) with 4/10 overrides (40% > 30%) → ×0.5
        #expect(DecayEngine.confidence(ageDays: 45, timesApplied: 10, timesOverridden: 4) == 0.37)
        // same age, low override rate → no penalty
        #expect(DecayEngine.confidence(ageDays: 45, timesApplied: 10, timesOverridden: 1) == 0.74)
    }

    @Test("decayed() ages knowledge types but leaves facts untouched")
    func decayedRespectsType() {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let now = created.addingTimeInterval(200 * 86_400) // 200 days later → dormant bucket

        let decision = MemoryNode(projectId: "p", type: .decision, title: "d", summary: "s",
                                  data: .decision(.init(chosen: "x")), confidence: 1.0,
                                  createdAt: created, updatedAt: created, lastValidatedAt: created)
        #expect(DecayEngine.decayed(decision, asOf: now).confidence == 0.24)
        #expect(DecayEngine.decayed(decision, asOf: now).decayLevel == .dormant)

        let fact = MemoryNode(projectId: "p", type: .fact, title: "f", summary: "s",
                              data: .fact(.init(category: "state", key: "k", value: "v")), confidence: 1.0,
                              createdAt: created, updatedAt: created, lastValidatedAt: created)
        #expect(DecayEngine.decayed(fact, asOf: now).confidence == 1.0) // facts never age
    }

    @Test("superseded memories stay obsolete")
    func supersededUntouched() {
        let n = MemoryNode(projectId: "p", type: .decision, title: "d", summary: "s",
                           data: .decision(.init(chosen: "x")), confidence: 0.0,
                           createdAt: Date(), updatedAt: Date(), supersededById: "newer")
        #expect(DecayEngine.decayed(n).decayLevel == .obsolete)
    }
}
