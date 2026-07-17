import Foundation

/// Safe-to-share numbers computed from a project's corpus at export time. This is the entire
/// vocabulary share artifacts may speak in: counts, ratios, and type names — never memory titles
/// or content, because images travel further than the person who exported them intended (the
/// digest document is the deliberate, content-carrying artifact).
public struct ShareStats: Sendable {
    public let projectName: String
    /// Confirmed, not superseded/deleted — the memories that actually hydrate sessions.
    public let memoryCount: Int
    public let typeCounts: [(type: MemoryType, count: Int)]
    /// Fraction of live memories fresh enough to apply without review.
    public let healthyShare: Double
    public let connectionCount: Int
    public let sessionCount: Int
    public let appliedCount: Int
    /// Days since the earliest capture (1-based: a brand-new corpus is "1 day of memory").
    public let memoryAgeDays: Int?

    /// Compute from a corpus. `edges` come in from the caller because renderers need them too.
    public static func compute(
        projectName: String, memories: [MemoryNode], edges: [MemoryEdge], now: Date = Date()
    ) -> ShareStats {
        let live = memories.filter { $0.status == .confirmed && !$0.isSuperseded && !$0.isDeleted }
        let typeCounts = MemoryType.allCases.compactMap { type -> (type: MemoryType, count: Int)? in
            let count = live.count { $0.type == type }
            return count > 0 ? (type: type, count: count) : nil
        }
        let healthy = live.count { !$0.decayLevel.requiresReviewBeforeApplying }
        return ShareStats(
            projectName: projectName,
            memoryCount: live.count,
            typeCounts: typeCounts,
            healthyShare: live.isEmpty ? 0 : Double(healthy) / Double(live.count),
            connectionCount: edges.count,
            sessionCount: Set(live.compactMap(\.conversationId)).count,
            appliedCount: live.reduce(0) { $0 + $1.timesAppliedSuccess },
            memoryAgeDays: live.map(\.createdAt).min().map {
                max(1, Int(now.timeIntervalSince($0) / 86_400) + 1)
            }
        )
    }
}
