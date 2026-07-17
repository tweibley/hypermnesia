import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("BeliefEngine")
struct BeliefEngineTests {

    @Test("capture prior: weak captures are capped, strong ones pass through")
    func capturePrior() {
        #expect(BeliefEngine.capturePrior(classifierConfidence: 0.9, weakCapture: false) == 0.9)
        #expect(BeliefEngine.capturePrior(classifierConfidence: 0.9, weakCapture: true) == 0.55)
        #expect(BeliefEngine.capturePrior(classifierConfidence: 0.4, weakCapture: true) == 0.4)   // already below cap
    }

    @Test("anti-gaming: pure re-capture cannot raise belief without a non-recapture corroborator")
    func recaptureDoesNotInflate() {
        // 10 sightings, but never applied/audited → factor stays exactly neutral.
        #expect(BeliefEngine.corroborationFactor(distinctSightings: 10, hasNonRecaptureCorroborator: false) == 1.0)
        let belief = BeliefEngine.effectiveBelief(
            prior: 0.6, distinctSightings: 10, hasNonRecaptureCorroborator: false)
        #expect(belief == 0.6)   // unchanged from the prior
    }

    @Test("corroboration boosts with a real corroborator, with diminishing returns and a cap")
    func corroborationDiminishes() {
        let f1 = BeliefEngine.corroborationFactor(distinctSightings: 1, hasNonRecaptureCorroborator: true)
        let f3 = BeliefEngine.corroborationFactor(distinctSightings: 3, hasNonRecaptureCorroborator: true)
        let f50 = BeliefEngine.corroborationFactor(distinctSightings: 50, hasNonRecaptureCorroborator: true)
        #expect(f1 > 1.0)
        #expect(f3 > f1)                                   // increasing
        #expect((f3 - f1) > (f50 - f3))                    // diminishing returns
        #expect(f50 <= 1.0 + BeliefEngine.maxCorroborationBoost + 1e-9)   // capped
    }

    @Test("application: high override rate halves belief; clean applies boost (capped)")
    func applicationOutcomes() {
        #expect(BeliefEngine.applicationFactor(successfulApplications: 0, overrides: 0) == 1.0)
        #expect(BeliefEngine.applicationFactor(successfulApplications: 1, overrides: 4) == 0.5)   // rate 0.8
        let boost = BeliefEngine.applicationFactor(successfulApplications: 3, overrides: 0)
        #expect(boost > 1.0 && boost <= 1.0 + BeliefEngine.maxApplicationBoost + 1e-9)
    }

    @Test("audit: drift strongly penalizes, consistency mildly boosts")
    func audit() {
        #expect(BeliefEngine.auditFactor(.drift) == 0.40)
        #expect(BeliefEngine.auditFactor(.unknown) == 1.0)
        #expect(BeliefEngine.auditFactor(.consistent) == 1.10)
    }

    @Test("effective belief clamps to [0.01, 1.0]")
    func clamps() {
        let high = BeliefEngine.effectiveBelief(
            prior: 0.95, distinctSightings: 5, hasNonRecaptureCorroborator: true,
            successfulApplications: 6, overrides: 0, audit: .consistent)
        #expect(high == 1.0)   // would exceed 1.0 unclamped
        let low = BeliefEngine.effectiveBelief(prior: 0.5, successfulApplications: 0, overrides: 9, audit: .drift)
        #expect(low >= 0.01 && low < 0.5)
    }
}
