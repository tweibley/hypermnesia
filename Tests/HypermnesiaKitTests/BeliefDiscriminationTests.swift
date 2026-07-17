import Foundation
import Testing
@testable import HypermnesiaKit

/// Offline discrimination eval (the Layer-1 gate): does evidence-based confidence rank *trustworthy*
/// memories above *untrustworthy* ones better than the old age-only model — and is it better
/// *calibrated* (confidence ≈ P(correct))? No subject runs; deterministic; runs in `swift test`.
@Suite("BeliefDiscrimination")
struct BeliefDiscriminationTests {

    /// One labeled memory with the evidence both models see. `label` = should we trust/inject it (1) or not (0).
    /// `ageDays` is days-since-last-validation (drives freshness for BOTH models). The age-only model is
    /// given the *conflated* live counter (`timesApplied` = sightings + applies) to be charitable to it.
    struct Case {
        let name: String
        let label: Double            // 1 trustworthy, 0 not
        // evidence-model inputs
        let classifierConfidence: Double
        let weak: Bool
        let distinctSightings: Int
        let nonRecaptureCorroborator: Bool
        let successfulApplications: Int
        let overrides: Int
        let audit: BeliefEngine.AuditState
        let ageDays: Int

        var ageOnlyConfidence: Double {
            // The shipped/legacy model: ageMultiplier × override penalty, from the conflated counter.
            DecayEngine.confidence(
                ageDays: ageDays,
                timesApplied: distinctSightings + successfulApplications,
                timesOverridden: overrides)
        }
        var evidenceConfidence: Double {
            let belief = BeliefEngine.effectiveBelief(
                prior: BeliefEngine.capturePrior(classifierConfidence: classifierConfidence, weakCapture: weak),
                distinctSightings: distinctSightings,
                hasNonRecaptureCorroborator: nonRecaptureCorroborator,
                successfulApplications: successfulApplications,
                overrides: overrides,
                audit: audit)
            return BeliefEngine.confidence(effectiveBelief: belief, ageDays: ageDays)
        }
    }

    // Fixture spans the categories you required: good (fresh + reinforced), repeated-but-wrong,
    // recent-but-low-quality, drifted, and stale.
    static let fixture: [Case] = [
        // ---- trustworthy (label 1) ----
        Case(name: "good_fresh",            label: 1, classifierConfidence: 0.90, weak: false, distinctSightings: 1, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 0, audit: .unknown,    ageDays: 5),
        Case(name: "good_applied",          label: 1, classifierConfidence: 0.85, weak: false, distinctSightings: 2, nonRecaptureCorroborator: true,  successfulApplications: 4, overrides: 0, audit: .consistent, ageDays: 12),
        Case(name: "old_correct_reinforced",label: 1, classifierConfidence: 0.80, weak: false, distinctSightings: 3, nonRecaptureCorroborator: true,  successfulApplications: 5, overrides: 0, audit: .consistent, ageDays: 20),
        Case(name: "solid_convention",      label: 1, classifierConfidence: 0.90, weak: false, distinctSightings: 2, nonRecaptureCorroborator: true,  successfulApplications: 3, overrides: 0, audit: .consistent, ageDays: 40),
        Case(name: "decent_unverified",     label: 1, classifierConfidence: 0.80, weak: false, distinctSightings: 1, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 0, audit: .unknown,    ageDays: 25),
        Case(name: "high_quality_audited",  label: 1, classifierConfidence: 0.95, weak: false, distinctSightings: 3, nonRecaptureCorroborator: true,  successfulApplications: 6, overrides: 0, audit: .consistent, ageDays: 9),
        // ---- untrustworthy (label 0) ----
        Case(name: "recent_low_quality",    label: 0, classifierConfidence: 0.40, weak: true,  distinctSightings: 1, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 0, audit: .unknown,    ageDays: 3),
        Case(name: "recent_vague",          label: 0, classifierConfidence: 0.45, weak: true,  distinctSightings: 1, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 0, audit: .unknown,    ageDays: 8),
        Case(name: "repeated_but_wrong",    label: 0, classifierConfidence: 0.60, weak: false, distinctSightings: 5, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 2, audit: .unknown,    ageDays: 10),
        Case(name: "repeated_but_wrong_2",  label: 0, classifierConfidence: 0.55, weak: false, distinctSightings: 4, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 1, audit: .unknown,    ageDays: 6),
        Case(name: "drifted",               label: 0, classifierConfidence: 0.85, weak: false, distinctSightings: 2, nonRecaptureCorroborator: true,  successfulApplications: 2, overrides: 0, audit: .drift,      ageDays: 30),
        Case(name: "overridden_often",      label: 0, classifierConfidence: 0.70, weak: false, distinctSightings: 2, nonRecaptureCorroborator: true,  successfulApplications: 1, overrides: 4, audit: .unknown,    ageDays: 15),
        Case(name: "stale_unreinforced",    label: 0, classifierConfidence: 0.60, weak: false, distinctSightings: 1, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 0, audit: .unknown,    ageDays: 220),
        Case(name: "obsolete_wrong",        label: 0, classifierConfidence: 0.50, weak: false, distinctSightings: 1, nonRecaptureCorroborator: false, successfulApplications: 0, overrides: 3, audit: .drift,      ageDays: 120),
    ]

    // ---- metrics ----

    /// ROC-AUC via the Mann–Whitney statistic (fraction of (pos,neg) pairs the score ranks correctly).
    static func auc(_ scores: [(score: Double, label: Double)]) -> Double {
        let pos = scores.filter { $0.label == 1 }.map(\.score)
        let neg = scores.filter { $0.label == 0 }.map(\.score)
        guard !pos.isEmpty, !neg.isEmpty else { return 0.5 }
        var wins = 0.0
        for p in pos { for n in neg { wins += p > n ? 1.0 : (p == n ? 0.5 : 0.0) } }
        return wins / Double(pos.count * neg.count)
    }

    /// Brier score: mean squared error treating the confidence as P(correct). Lower is better.
    static func brier(_ scores: [(score: Double, label: Double)]) -> Double {
        scores.reduce(0.0) { $0 + pow($1.score - $1.label, 2) } / Double(scores.count)
    }

    /// Reliability bins: for each confidence band, predicted (mean score) vs actual (mean label).
    static func reliability(_ scores: [(score: Double, label: Double)], bins: Int = 5) -> [(band: String, n: Int, predicted: Double, actual: Double)] {
        var out: [(String, Int, Double, Double)] = []
        for b in 0..<bins {
            let lo = Double(b) / Double(bins), hi = Double(b + 1) / Double(bins)
            let inBin = scores.filter { $0.score > lo - 1e-9 && ($0.score < hi || (b == bins - 1 && $0.score <= hi + 1e-9)) }
            guard !inBin.isEmpty else { continue }
            let pred = inBin.reduce(0.0) { $0 + $1.score } / Double(inBin.count)
            let act = inBin.reduce(0.0) { $0 + $1.label } / Double(inBin.count)
            out.append((String(format: "%.1f–%.1f", lo, hi), inBin.count, pred, act))
        }
        return out
    }

    @Test("evidence-based confidence out-discriminates and out-calibrates age-only decay")
    func gate() {
        let ageScores = Self.fixture.map { (score: $0.ageOnlyConfidence, label: $0.label) }
        let evScores  = Self.fixture.map { (score: $0.evidenceConfidence, label: $0.label) }

        let aucAge = Self.auc(ageScores),  aucEv = Self.auc(evScores)
        let brierAge = Self.brier(ageScores), brierEv = Self.brier(evScores)

        // Per-case table (printed for the report).
        print("\n=== Belief discrimination — per case (label | age-only | evidence) ===")
        for c in Self.fixture {
            print(String(format: "  %-22@  y=%.0f   age=%.2f   ev=%.2f",
                         c.name as NSString, c.label, c.ageOnlyConfidence, c.evidenceConfidence))
        }
        print(String(format: "\nROC-AUC   age-only=%.3f   evidence=%.3f   (higher = better ranking)", aucAge, aucEv))
        print(String(format: "Brier     age-only=%.3f   evidence=%.3f   (lower  = better calibration)", brierAge, brierEv))
        print("\nReliability (evidence):")
        for r in Self.reliability(evScores) {
            print(String(format: "  band %@  n=%d  predicted=%.2f  actual=%.2f", r.band as NSString, r.n, r.predicted, r.actual))
        }

        // The gate: evidence must rank better AND be better calibrated.
        #expect(aucEv > aucAge)
        #expect(brierEv < brierAge)
    }
}
