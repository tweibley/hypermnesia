import Foundation

/// Evidence-based **belief** — how much we trust a memory is *correct and well-formed*, separate from
/// how *recent* it is. The product `belief × freshness` becomes the memory's confidence, fixing the
/// old model where `confidence` was a pure recency proxy that discarded the classifier's belief, the
/// capture-quality verdict, and every application/audit outcome.
///
/// Two explicit update paths (kept separate so it's debuggable *why* belief moved):
///  - **Quality path** (at capture): `capturePrior` from the classifier confidence + validator verdict.
///  - **Outcome path** (post-capture): `corroborationFactor`, `applicationFactor`, `auditFactor`.
///
/// Anti-gaming: pure re-capture cannot inflate belief — a corroboration boost requires at least one
/// *non-recapture* corroborator (a successful application or an audit pass), and it has diminishing
/// returns in the number of distinct sightings.
public enum BeliefEngine {

    // MARK: Tunables
    public static let weakCeiling = 0.55              // CaptureValidator.weakConfidenceCeiling
    public static let maxCorroborationBoost = 0.50    // asymptotic cap on the corroboration multiplier
    public static let corroborationDecay = 0.60       // diminishing-returns base per distinct sighting
    public static let maxApplicationBoost = 0.40
    public static let applicationGainPerSuccess = 0.15
    public static let overrideRateThreshold = 0.30
    public static let overridePenalty = 0.50
    public static let auditConsistentBoost = 1.10
    public static let auditDriftPenalty = 0.40

    public enum AuditState: Sendable, Equatable { case consistent, unknown, drift }

    // MARK: - Quality path (capture)

    /// Epistemic prior at capture: the classifier's confidence, capped when the validator flagged the
    /// capture as weak (incomplete contract / missing prohibition / too vague).
    public static func capturePrior(classifierConfidence: Double, weakCapture: Bool) -> Double {
        clamp(weakCapture ? min(classifierConfidence, weakCeiling) : classifierConfidence)
    }

    // MARK: - Outcome path (post-capture)

    /// Corroboration multiplier (≥ 1). Pure re-capture yields **no** gain — a boost requires a
    /// non-recapture corroborator (successful apply or audit pass) — and saturates with diminishing
    /// returns, so a wrong memory re-extracted every session can't climb.
    public static func corroborationFactor(distinctSightings: Int, hasNonRecaptureCorroborator: Bool) -> Double {
        guard hasNonRecaptureCorroborator, distinctSightings > 0 else { return 1.0 }
        let saturation = 1.0 - pow(corroborationDecay, Double(distinctSightings))   // 0 → 1
        return 1.0 + maxCorroborationBoost * saturation
    }

    /// Application-outcome multiplier. A high override rate halves belief; clean successful applies
    /// raise it with diminishing returns. No applications → neutral.
    public static func applicationFactor(successfulApplications: Int, overrides: Int) -> Double {
        let total = successfulApplications + overrides
        guard total > 0 else { return 1.0 }
        if Double(overrides) / Double(total) > overrideRateThreshold { return overridePenalty }
        return 1.0 + min(maxApplicationBoost, applicationGainPerSuccess * Double(successfulApplications))
    }

    /// Audit multiplier: code still matches the memory → small boost; code drifted away → strong penalty.
    public static func auditFactor(_ state: AuditState) -> Double {
        switch state {
        case .consistent: auditConsistentBoost
        case .unknown: 1.0
        case .drift: auditDriftPenalty
        }
    }

    // MARK: - Composition

    /// Composed epistemic trust (age-independent) = prior × the named outcome factors, clamped.
    public static func effectiveBelief(
        prior: Double,
        distinctSightings: Int = 0,
        hasNonRecaptureCorroborator: Bool = false,
        successfulApplications: Int = 0,
        overrides: Int = 0,
        audit: AuditState = .unknown
    ) -> Double {
        clamp(prior
            * corroborationFactor(distinctSightings: distinctSightings,
                                  hasNonRecaptureCorroborator: hasNonRecaptureCorroborator)
            * applicationFactor(successfulApplications: successfulApplications, overrides: overrides)
            * auditFactor(audit))
    }

    /// Final confidence = epistemic trust × temporal freshness (the existing age curve).
    public static func confidence(effectiveBelief: Double, ageDays: Int) -> Double {
        clamp(effectiveBelief * DecayEngine.ageMultiplier(ageDays: ageDays))
    }

    static func clamp(_ x: Double) -> Double { min(1.0, max(0.01, x)) }
}
