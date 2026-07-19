import Foundation
import GRDB

// MARK: - Epiphanies

/// The typed insight kinds a dream may surface. Every kind carries mandatory evidence — the
/// validator drops any epiphany whose receipts don't check out (see `DreamValidator`).
public enum DreamEpiphanyKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A pattern across ≥2 memories (cites their ids).
    case theme
    /// Memories that reinforce each other (cites ≥2 ids).
    case strengthening
    /// An aging concern/backlog memory left dangling (cites the memory).
    case openThread
    /// Two memories that disagree (cites both; the card renders them side by side).
    case contradiction
    /// The user repeating the same instruction across sessions (quotes them verbatim).
    case friction
    /// Transcript evidence that justifies a memory the store is missing (quotes it).
    case gap
}

/// A verbatim transcript excerpt tied to the session it came from — the receipt on a card.
public struct DreamQuote: Codable, Sendable, Hashable {
    public var sessionId: String
    public var text: String

    public init(sessionId: String, text: String) {
        self.sessionId = sessionId
        self.text = text
    }
}

/// One evidence-backed insight in a dream. Arrays decode leniently (a model that omits a key
/// yields an empty list, which the validator then judges) — only `kind`/`title`/`insight` are hard
/// requirements, so a malformed element is skipped without dropping the batch.
public struct DreamEpiphany: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: DreamEpiphanyKind
    public var title: String
    public var insight: String
    public var memoryIds: [String]
    public var sessionIds: [String]
    public var quotes: [DreamQuote]
    /// Model self-score in [0,1]; below-threshold epiphanies are dropped before the quality gate.
    public var score: Double

    public init(
        id: String = UUID().uuidString,
        kind: DreamEpiphanyKind,
        title: String,
        insight: String,
        memoryIds: [String] = [],
        sessionIds: [String] = [],
        quotes: [DreamQuote] = [],
        score: Double = 0.7
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.insight = insight
        self.memoryIds = memoryIds
        self.sessionIds = sessionIds
        self.quotes = quotes
        self.score = min(1.0, max(0.0, score))
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, insight, memoryIds, sessionIds, quotes, score
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(DreamEpiphanyKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        insight = try c.decode(String.self, forKey: .insight)
        memoryIds = try c.decodeIfPresent([String].self, forKey: .memoryIds) ?? []
        sessionIds = try c.decodeIfPresent([String].self, forKey: .sessionIds) ?? []
        quotes = try c.decodeIfPresent([DreamQuote].self, forKey: .quotes) ?? []
        let raw = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0.7
        score = min(1.0, max(0.0, raw))
    }
}

// MARK: - Skill proposals

/// The lifecycle position of a staged skill proposal, driven by journal-card actions.
public enum DreamSkillProposalState: String, Codable, Sendable, Hashable {
    case proposed
    case installed
    case dismissed
    case uninstalled
}

/// A skill the dream proposes — staged in full (frontmatter + body) so the user can preview and
/// edit before anything touches disk. The ≥2-distinct-session evidence gate is enforced by
/// `DreamValidator`; nothing is written until an explicit install.
public struct DreamSkillProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// kebab-case directory name (`.claude/skills/<slug>/SKILL.md`).
    public var slug: String
    public var title: String
    public var description: String
    public var rationale: String
    /// The complete staged `SKILL.md` content.
    public var markdown: String
    /// Verbatim friction quotes from ≥2 distinct sessions — shipped on the card.
    public var evidence: [DreamQuote]
    /// True when a same-slug skill already exists on disk — the card becomes an update-with-diff.
    public var updatesExisting: Bool
    public var state: DreamSkillProposalState

    public init(
        id: String = UUID().uuidString,
        slug: String,
        title: String,
        description: String,
        rationale: String,
        markdown: String,
        evidence: [DreamQuote] = [],
        updatesExisting: Bool = false,
        state: DreamSkillProposalState = .proposed
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.description = description
        self.rationale = rationale
        self.markdown = markdown
        self.evidence = evidence
        self.updatesExisting = updatesExisting
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id, slug, title, description, rationale, markdown, evidence, updatesExisting, state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? slug
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        markdown = try c.decode(String.self, forKey: .markdown)
        evidence = try c.decodeIfPresent([DreamQuote].self, forKey: .evidence) ?? []
        updatesExisting = try c.decodeIfPresent(Bool.self, forKey: .updatesExisting) ?? false
        state = try c.decodeIfPresent(DreamSkillProposalState.self, forKey: .state) ?? .proposed
    }
}

// MARK: - Report-backs & stats

/// A deterministic (never model-generated) note closing the loop on a previous dream's output:
/// whether an installed skill was actually used, whether a confirmed dream memory keeps earning
/// sightings. The system states plainly whether its own suggestions worked.
public struct DreamReportBack: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case skill, memory }
    public var kind: Kind
    /// Skill slug or memory id.
    public var subject: String
    public var title: String
    public var detail: String

    public init(kind: Kind, subject: String, title: String, detail: String) {
        self.kind = kind
        self.subject = subject
        self.title = title
        self.detail = detail
    }
}

/// Honest accounting shown on every journal entry — including quiet nights.
public struct DreamStats: Codable, Sendable, Hashable {
    public var sessionsScanned: Int
    public var memoriesConsidered: Int
    /// Human-readable engine label, e.g. "gemini (gemini-3.5-flash)".
    public var classifier: String
    public var calls: Int
    public var estCostUSD: Double?

    public init(
        sessionsScanned: Int, memoriesConsidered: Int, classifier: String,
        calls: Int, estCostUSD: Double? = nil
    ) {
        self.sessionsScanned = sessionsScanned
        self.memoriesConsidered = memoriesConsidered
        self.classifier = classifier
        self.calls = calls
        self.estCostUSD = estCostUSD
    }
}

// MARK: - Journal entry

public enum DreamOutcome: String, Codable, Sendable, Hashable {
    /// The quality gate passed; the entry carries at least one evidence-complete epiphany.
    case dreamed
    /// The pass ran but nothing cleared the gate (or the model call failed) — logged, never padded.
    case quiet
}

extension DreamOutcome: DatabaseValueConvertible {}

/// Everything a dream produced, stored as one JSON payload column (evolvable without migrations).
public struct DreamPayload: Codable, Sendable, Hashable {
    public var epiphanies: [DreamEpiphany]
    /// Draft `MemoryNode` ids created by this dream (they flow through the normal triage inbox).
    public var proposedMemoryIds: [String]
    public var skillProposals: [DreamSkillProposal]
    public var reportBacks: [DreamReportBack]
    public var stats: DreamStats
    /// Diagnostic note for quiet nights (e.g. the classifier error) — honesty over silence.
    public var note: String?

    public init(
        epiphanies: [DreamEpiphany] = [],
        proposedMemoryIds: [String] = [],
        skillProposals: [DreamSkillProposal] = [],
        reportBacks: [DreamReportBack] = [],
        stats: DreamStats,
        note: String? = nil
    ) {
        self.epiphanies = epiphanies
        self.proposedMemoryIds = proposedMemoryIds
        self.skillProposals = skillProposals
        self.reportBacks = reportBacks
        self.stats = stats
        self.note = note
    }
}

/// One night's dream for one project. `night` is the local calendar day (`yyyy-MM-dd`);
/// `(projectId, night)` is unique — re-running tonight replaces tonight's entry.
public struct DreamJournalEntry: Codable, Sendable, Hashable, Identifiable,
    FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dream_journal"

    public var id: String
    public var projectId: String
    public var night: String
    public var createdAt: Date
    public var outcome: DreamOutcome
    /// 2–3 confident sentences (dreamed nights only).
    public var narrative: String?
    public var payload: DreamPayload
    /// Drives the notch chip + digest; only dreamed nights start unread.
    public var unread: Bool
    public var calls: Int
    public var estCostUSD: Double?

    public init(
        id: String = UUID().uuidString,
        projectId: String,
        night: String,
        createdAt: Date = Date(),
        outcome: DreamOutcome,
        narrative: String? = nil,
        payload: DreamPayload,
        unread: Bool = false,
        calls: Int = 0,
        estCostUSD: Double? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.night = night
        self.createdAt = createdAt
        self.outcome = outcome
        self.narrative = narrative
        self.payload = payload
        self.unread = unread
        self.calls = calls
        self.estCostUSD = estCostUSD
    }
}
