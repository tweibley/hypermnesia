import Foundation

/// A single captured memory.
///
/// Ported from the original `MemoryNode` (`docs/design/01-data-model-and-types.md`) with three
/// deliberate changes for the local-first design:
///  1. `projectId` is an explicit field (the original scoped by the server URL path).
///  2. `conversationId` is the stable Claude Code `session_id` (the original generated a throwaway
///     UUID per classify call, which broke source-back-linking).
///  3. Timestamps are `Date` (the store maps them; the original used Unix-ms `Int64` on the wire).
public struct MemoryNode: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: String
    /// Which project this memory belongs to (git remote URL, else normalized repo path; or
    /// `MemoryNode.globalProjectId` for cross-project knowledge).
    public var projectId: String
    public let type: MemoryType
    public var status: MemoryStatus
    public var title: String
    public var summary: String
    public var data: MemoryData
    public var confidence: Double
    /// Epistemic trust that this memory is correct & well-formed, *independent of age* — the evidence
    /// "belief" in `confidence = belief × freshness`. `nil` for legacy nodes captured before the model
    /// existed; those fall back to age-only decay. Set at capture, evolved by outcomes. See `BeliefEngine`.
    public var belief: Double?

    public let createdAt: Date
    public var updatedAt: Date
    /// Last time this memory was confirmed true (by use or manual revalidation). Drives decay.
    public var lastValidatedAt: Date?
    public var version: Int
    /// Soft-delete marker. Non-nil = deleted.
    public var deletedAt: Date?

    // Decision lineage
    public var supersedesId: String?
    public var supersededById: String?

    // Provenance
    /// Claude Code `session_id` this memory was captured from.
    public var conversationId: String?
    /// The verbatim text the memory was extracted from.
    public var sourceQuote: String?
    /// Commit the memory was captured at (for durable code-reference URLs).
    public var commitSha: String?
    public var branch: String?

    // Decay / evidence accounting
    public var timesApplied: Int        // legacy sighting counter — kept stable; drives auto-confirm + legacy decay
    public var timesOverridden: Int     // applied but reverted/contradicted (a failure / audit drift)
    /// Distinct re-capture sightings (the correctly-named successor to the overloaded `timesApplied`).
    public var timesSighted: Int
    /// Referenced AND the resulting code survived — real corroborating evidence (a non-recapture corroborator).
    public var timesAppliedSuccess: Int
    /// The last audit outcome recorded for this node ("consistent" / "drift"), so a periodic
    /// `recordOutcomes` pass only moves belief on a *change* and doesn't compound an unchanged verdict.
    public var lastAuditOutcome: String?

    /// Reserved project id for memories that aren't tied to a single repo.
    public static let globalProjectId = "__global__"

    public init(
        id: String = UUID().uuidString,
        projectId: String,
        type: MemoryType,
        status: MemoryStatus = .draft,
        title: String,
        summary: String,
        data: MemoryData,
        confidence: Double = 1.0,
        belief: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastValidatedAt: Date? = nil,
        version: Int = 1,
        deletedAt: Date? = nil,
        supersedesId: String? = nil,
        supersededById: String? = nil,
        conversationId: String? = nil,
        sourceQuote: String? = nil,
        commitSha: String? = nil,
        branch: String? = nil,
        timesApplied: Int = 0,
        timesOverridden: Int = 0,
        timesSighted: Int = 0,
        timesAppliedSuccess: Int = 0,
        lastAuditOutcome: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.type = type
        self.status = status
        self.title = title
        self.summary = summary
        self.data = data
        self.confidence = confidence
        self.belief = belief
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastValidatedAt = lastValidatedAt
        self.version = version
        self.deletedAt = deletedAt
        self.supersedesId = supersedesId
        self.supersededById = supersededById
        self.conversationId = conversationId
        self.sourceQuote = sourceQuote
        self.commitSha = commitSha
        self.branch = branch
        self.timesApplied = timesApplied
        self.timesOverridden = timesOverridden
        self.timesSighted = timesSighted
        self.timesAppliedSuccess = timesAppliedSuccess
        self.lastAuditOutcome = lastAuditOutcome
    }

    // MARK: - Derived

    public var isDeleted: Bool { deletedAt != nil }
    public var isSuperseded: Bool { supersededById != nil }

    /// Freshness band from the current confidence.
    public var decayLevel: DecayLevel {
        DecayLevel.from(confidence: confidence, isSuperseded: isSuperseded)
    }

    /// Whether this memory should be reviewed before an agent applies it.
    public var needsRevalidation: Bool { decayLevel.requiresReviewBeforeApplying }

    /// Days since last validation, for display. Decay math itself injects `now` for determinism.
    public func daysSinceValidation(asOf now: Date = Date()) -> Int {
        let anchor = lastValidatedAt ?? createdAt
        return max(0, Int(now.timeIntervalSince(anchor) / 86_400))
    }

    /// Override rate as a 0–100 percentage, for display.
    public var overrideRatePercent: Int {
        guard timesApplied > 0 else { return 0 }
        return Int(Double(timesOverridden) / Double(timesApplied) * 100)
    }
}
