import Foundation

/// Computes memory confidence from age + override rate. Ported from the original's decay model
/// (`docs/design/03-decay-and-aging.md`); confidence is authoritative and buckets into `DecayLevel`.
public enum DecayEngine {
    // Day boundaries
    public static let freshDays = 30
    public static let agingDays = 90
    public static let staleDays = 180
    // Age-bucket multipliers
    public static let freshMultiplier = 1.00
    public static let agingMultiplier = 0.74
    public static let staleMultiplier = 0.49
    public static let dormantMultiplier = 0.24
    // Override penalty
    public static let overrideRateThreshold = 0.30
    public static let overridePenalty = 0.50

    /// Confidence multiplier from days since last validation.
    public static func ageMultiplier(ageDays: Int) -> Double {
        if ageDays < freshDays { return freshMultiplier }
        if ageDays < agingDays { return agingMultiplier }
        if ageDays < staleDays { return staleMultiplier }
        return dormantMultiplier
    }

    /// Full confidence: age multiplier × override penalty (halved if override rate > 30%), clamped.
    public static func confidence(ageDays: Int, timesApplied: Int, timesOverridden: Int) -> Double {
        var c = ageMultiplier(ageDays: ageDays)
        if timesApplied > 0, Double(timesOverridden) / Double(timesApplied) > overrideRateThreshold {
            c *= overridePenalty
        }
        return min(1.0, max(0.01, c))
    }

    /// Return a copy of `node` with confidence recomputed as of `now`.
    ///
    /// Only decaying types age (decision/convention/intent); facts/concerns/backlog/codeRefs keep
    /// their confidence. Superseded memories are left at 0 (obsolete).
    public static func decayed(_ node: MemoryNode, asOf now: Date = Date()) -> MemoryNode {
        guard node.type.decaysWithTime, !node.isSuperseded else { return node }
        var updated = node
        let ageDays = node.daysSinceValidation(asOf: now)
        if let prior = node.belief {
            // Evidence-based: effective trust × temporal freshness. The capture-quality `belief` prior is
            // moved by the outcome counters — corroboration (sightings, gated on a real corroborator),
            // application success, and overrides/drift — then aged by freshness.
            let effective = BeliefEngine.effectiveBelief(
                prior: prior,
                distinctSightings: node.timesSighted,
                hasNonRecaptureCorroborator: node.timesAppliedSuccess > 0,
                successfulApplications: node.timesAppliedSuccess,
                overrides: node.timesOverridden,
                audit: .unknown)   // live audit is folded into the success/override counters, not a separate term
            updated.confidence = BeliefEngine.confidence(effectiveBelief: effective, ageDays: ageDays)
        } else {
            // Legacy nodes (captured before the belief model): unchanged age × override decay.
            updated.confidence = confidence(
                ageDays: ageDays,
                timesApplied: node.timesApplied,
                timesOverridden: node.timesOverridden
            )
        }
        return updated
    }
}
