import Foundation

/// Derived, SwiftUI-free view models + pure aggregations that power the app's analytics surfaces:
/// the per-memory **Confidence breakdown**, the per-memory **Timeline**, and the project **Trends**
/// dashboard. Everything here is a pure function of `MemoryNode`s + an injected `now`, so it's
/// deterministic and unit-testable (matching the `DecayEngine` / `BeliefEngine` enum idiom).
///
/// Why a free enum instead of the spec's `MemoryAnalyticsService` protocol: there's exactly one
/// implementation and no I/O — the engine is store-free (the app hands in already-loaded nodes),
/// which keeps the Kit headless and the math trivially testable.
public enum MemoryAnalytics {

    // MARK: - Confidence breakdown

    /// Decomposes a memory's `confidence` into `belief × freshness` for display.
    ///
    /// The card **explains the confidence shown everywhere else** — the list badge, the inspector
    /// header, and (critically) what `MemoryHydrator` actually injects — all of which read the stored
    /// `node.confidence`. So it anchors on that stored value rather than recomputing via
    /// `DecayEngine.decayed`; recomputing would let the card contradict the badge on a node whose
    /// stored confidence predates its current age.
    ///
    ///  - **freshness** — the temporal `DecayEngine.ageMultiplier` (1.0 for non-decaying / superseded).
    ///  - **belief** — the residual trust `confidence / freshness`. For a model-consistent node this
    ///    recovers `BeliefEngine.effectiveBelief` exactly (since `confidence = belief × freshness`);
    ///    it isolates "low because untrusted" from "low because old".
    public static func confidenceBreakdown(for node: MemoryNode, now: Date = Date()) -> ConfidenceBreakdownVM {
        let ageDays = node.daysSinceValidation(asOf: now)
        let decays = node.type.decaysWithTime && !node.isSuperseded
        let confidence = node.confidence
        let freshness = decays ? DecayEngine.ageMultiplier(ageDays: ageDays) : 1.0
        let belief = displayClamp(freshness > 0 ? confidence / freshness : confidence)

        return ConfidenceBreakdownVM(
            id: node.id,
            title: node.title,
            type: node.type,
            status: node.status,
            confidence: confidence,
            belief: belief,
            freshness: freshness,
            decayLevel: node.decayLevel,
            decays: decays,
            usesBeliefModel: node.belief != nil,
            ageDays: ageDays,
            lastValidatedAt: node.lastValidatedAt,
            timesApplied: node.timesApplied,
            timesAppliedSuccess: node.timesAppliedSuccess,
            timesOverridden: node.timesOverridden,
            overrideRate: Double(node.timesOverridden) / Double(max(node.timesApplied, 1)),
            timesSighted: node.timesSighted,
            lastAuditOutcome: node.lastAuditOutcome)
    }

    // MARK: - Timeline

    /// The "story of this memory" as a chronological event list derived from its timestamps and
    /// counters. We have no per-event log, so reinforcement/override appear as aggregate markers at
    /// `updatedAt`, and decay transitions are projected from the validation anchor + age thresholds
    /// (emitting only those that have already elapsed as of `now`).
    public static func timeline(for node: MemoryNode, now: Date = Date()) -> MemoryTimelineVM {
        var events: [MemoryTimelineEventVM] = []

        events.append(.init(timestamp: node.createdAt, kind: .created,
                            title: "Captured",
                            detail: "\(node.type.displayName) memory created"))

        if let validated = node.lastValidatedAt, abs(validated.timeIntervalSince(node.createdAt)) > 1 {
            events.append(.init(timestamp: validated, kind: .validated,
                                title: "Validated",
                                detail: "Confirmed still true; confidence reset"))
        }

        if abs(node.updatedAt.timeIntervalSince(node.createdAt)) > 1 {
            events.append(.init(timestamp: node.updatedAt, kind: .updated,
                                title: "Updated",
                                detail: node.status == .confirmed ? "Edited or confirmed" : "Edited"))
        }

        let applied = node.timesApplied + node.timesAppliedSuccess
        if applied > 0 {
            let success = node.timesAppliedSuccess
            events.append(.init(timestamp: node.updatedAt, kind: .reinforced,
                                title: "Reinforced",
                                detail: "Applied \(node.timesApplied)×" + (success > 0 ? ", \(success) survived in code" : "")))
        }
        if node.timesOverridden > 0 {
            let pct = Int((Double(node.timesOverridden) / Double(max(node.timesApplied, 1))) * 100)
            events.append(.init(timestamp: node.updatedAt, kind: .overridden,
                                title: "Overridden",
                                detail: "Reverted/contradicted \(node.timesOverridden)× (\(pct)%)"))
        }

        // Decay transitions: only decaying, non-superseded types age, so only they cross bands.
        // Belief scales the whole curve, so the band a node enters at each freshness boundary depends
        // on its belief — a belief-0.6 convention is already Stale at the 30-day boundary, not Aging.
        // Compute the actual level per bucket and emit a transition only when the band truly changes.
        if node.type.decaysWithTime && !node.isSuperseded {
            let anchor = node.lastValidatedAt ?? node.createdAt
            let belief = node.belief ?? 1.0
            let boundaries: [(days: Int, mult: Double)] = [
                (DecayEngine.freshDays, DecayEngine.agingMultiplier),
                (DecayEngine.agingDays, DecayEngine.staleMultiplier),
                (DecayEngine.staleDays, DecayEngine.dormantMultiplier),
            ]
            var prevLevel = DecayLevel.from(confidence: belief * DecayEngine.freshMultiplier, isSuperseded: false)
            for b in boundaries {
                let level = DecayLevel.from(confidence: belief * b.mult, isSuperseded: false)
                let at = anchor.addingTimeInterval(Double(b.days) * 86_400)
                if at <= now && level != prevLevel {
                    events.append(.init(timestamp: at, kind: .decayTransition,
                                        title: "Decayed to \(level.displayName)",
                                        detail: "Crossed the \(b.days)-day freshness boundary"))
                }
                prevLevel = level
            }
        }

        events.sort { $0.timestamp < $1.timestamp }
        return MemoryTimelineVM(memoryId: node.id, events: events, trend: trend(for: node, now: now))
    }

    /// Direction-of-travel for confidence. Without history we infer it from current state: a node is
    /// trending **down** once it's aging/overridden/superseded, **up** when freshly validated with
    /// real corroboration, otherwise **stable**.
    private static func trend(for node: MemoryNode, now: Date) -> ConfidenceTrend {
        if node.isSuperseded { return .down }
        let overrideRate = Double(node.timesOverridden) / Double(max(node.timesApplied, 1))
        let ageDays = node.daysSinceValidation(asOf: now)
        if node.type.decaysWithTime && (ageDays >= DecayEngine.freshDays || overrideRate > DecayEngine.overrideRateThreshold) {
            return .down
        }
        if node.timesAppliedSuccess > 0 && overrideRate <= DecayEngine.overrideRateThreshold {
            return .up
        }
        return .stable
    }

    // MARK: - Project trends

    /// Aggregates a project's memories into the trends dashboard's chart series + KPIs.
    ///
    /// **Cohort semantics (important):** we don't snapshot historical confidence, so the per-day
    /// series bucket memories by *creation day* and use each memory's *current stored* confidence /
    /// decay-level — the same value the badges show and `MemoryHydrator` injects (not a re-decayed
    /// one). So "avg injectable confidence" and the decay stack read as "how is the cohort born on
    /// day N doing now" — which still answers whether older memories are rotting — rather than a true
    /// day-by-day historical measurement. KPIs are a current project-wide snapshot, ignoring the window.
    public static func projectTrends(
        nodes: [MemoryNode], window: TrendWindow, now: Date = Date()
    ) -> ProjectTrendsVM {
        let threshold = MemoryHydrator.Options().minConfidence

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let bucketStarts: [Date] = (0..<window.dayCount).reversed().compactMap {
            cal.date(byAdding: .day, value: -$0, to: today)
        }
        let windowStart = bucketStarts.first ?? today

        // Pre-bucket the in-window cohort by creation day for a single pass.
        let inWindow = nodes.filter { $0.createdAt >= windowStart }
        let byDay = Dictionary(grouping: inWindow) { cal.startOfDay(for: $0.createdAt) }

        var newMemories: [TrendPointVM] = []
        var confirmedMemories: [TrendPointVM] = []
        var avgInjectableConfidence: [TrendPointVM] = []
        var decayStack: [StackedDecayPointVM] = []

        for start in bucketStarts {
            let cohort = byDay[start] ?? []
            newMemories.append(.init(bucketStart: start, value: Double(cohort.count)))
            confirmedMemories.append(.init(bucketStart: start,
                                           value: Double(cohort.filter { $0.status == .confirmed }.count)))

            let injectable = cohort.filter { $0.status == .confirmed && !$0.isSuperseded && $0.confidence >= threshold }
            let avg = injectable.isEmpty ? 0 : injectable.map(\.confidence).reduce(0, +) / Double(injectable.count)
            avgInjectableConfidence.append(.init(bucketStart: start, value: avg))

            var f = 0, a = 0, s = 0, d = 0
            for node in cohort {
                switch node.decayLevel {
                case .fresh: f += 1
                case .aging: a += 1
                case .stale: s += 1
                case .dormant, .obsolete: d += 1   // obsolete (superseded/dead) folds into the dormant column
                }
            }
            decayStack.append(.init(bucketStart: start, fresh: f, aging: a, stale: s, dormant: d))
        }

        return ProjectTrendsVM(
            window: window,
            newMemories: newMemories,
            confirmedMemories: confirmedMemories,
            avgInjectableConfidence: avgInjectableConfidence,
            decayStack: decayStack,
            kpis: kpis(nodes: nodes, threshold: threshold))
    }

    /// Current, project-wide snapshot KPIs (window-independent).
    private static func kpis(nodes: [MemoryNode], threshold: Double) -> ProjectTrendKPI {
        let total = nodes.count
        guard total > 0 else { return ProjectTrendKPI(confirmedRate: 0, belowInjectionThresholdRate: 0, aggregateOverrideRate: 0) }

        let confirmed = nodes.filter { $0.status == .confirmed }
        // "Below injection threshold" is only meaningful among injection candidates (confirmed, live).
        let pool = confirmed.filter { !$0.isSuperseded }
        let below = pool.filter { $0.confidence < threshold }.count
        let belowRate = pool.isEmpty ? 0 : Double(below) / Double(pool.count)

        let totalApplied = nodes.reduce(0) { $0 + $1.timesApplied }
        let totalOverridden = nodes.reduce(0) { $0 + $1.timesOverridden }

        return ProjectTrendKPI(
            confirmedRate: Double(confirmed.count) / Double(total),
            belowInjectionThresholdRate: belowRate,
            aggregateOverrideRate: Double(totalOverridden) / Double(max(totalApplied, 1)))
    }

    private static func displayClamp(_ x: Double) -> Double { min(1.0, max(0.0, x)) }
}

// MARK: - View models

/// Confidence breakdown for the inspector's "Confidence" card. `confidence = belief × freshness`.
public struct ConfidenceBreakdownVM: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let type: MemoryType
    public let status: MemoryStatus
    public let confidence: Double          // final score shown (clamp(belief × freshness))
    public let belief: Double              // age-independent trustworthiness
    public let freshness: Double           // age-based multiplier
    public let decayLevel: DecayLevel
    public let decays: Bool                // false → this type holds confidence regardless of age
    public let usesBeliefModel: Bool       // false → legacy age×override node
    public let ageDays: Int
    public let lastValidatedAt: Date?
    public let timesApplied: Int
    public let timesAppliedSuccess: Int
    public let timesOverridden: Int
    public let overrideRate: Double        // timesOverridden / max(timesApplied, 1)
    public let timesSighted: Int
    public let lastAuditOutcome: String?   // "consistent" / "drift" from the last reality check
}

public enum MemoryEventKind: String, Sendable {
    case created, updated, validated, reinforced, overridden, decayTransition
}

public enum ConfidenceTrend: String, Sendable {
    case up, down, stable
}

public struct MemoryTimelineEventVM: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let kind: MemoryEventKind
    public let title: String
    public let detail: String
}

public struct MemoryTimelineVM: Sendable, Equatable {
    public let memoryId: String
    public let events: [MemoryTimelineEventVM]   // sorted ascending by timestamp
    public let trend: ConfidenceTrend
}

public enum TrendWindow: String, CaseIterable, Sendable, Identifiable {
    case days7, days30
    public var id: String { rawValue }
    public var dayCount: Int { self == .days7 ? 7 : 30 }
    public var label: String { self == .days7 ? "7 days" : "30 days" }
}

public struct TrendPointVM: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let bucketStart: Date
    public let value: Double
}

public struct StackedDecayPointVM: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let bucketStart: Date
    public let fresh: Int
    public let aging: Int
    public let stale: Int
    public let dormant: Int   // includes obsolete/superseded
}

public struct ProjectTrendKPI: Sendable, Equatable {
    public let confirmedRate: Double
    public let belowInjectionThresholdRate: Double
    public let aggregateOverrideRate: Double
}

public struct ProjectTrendsVM: Sendable, Equatable {
    public let window: TrendWindow
    public let newMemories: [TrendPointVM]
    public let confirmedMemories: [TrendPointVM]
    public let avgInjectableConfidence: [TrendPointVM]
    public let decayStack: [StackedDecayPointVM]
    public let kpis: ProjectTrendKPI
}
