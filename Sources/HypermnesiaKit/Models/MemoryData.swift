import Foundation

// MARK: - Type-specific payloads

/// A choice made between alternatives — the "why" behind the code.
public struct DecisionData: Codable, Equatable, Sendable, Hashable {
    public var problem: String?
    public var chosen: String
    public var alternatives: [String]
    public var rationale: String?
    /// Conditions that should make us revisit this decision.
    public var revisitTriggers: [String]
    public var relatedFiles: [String]

    public init(
        problem: String? = nil,
        chosen: String,
        alternatives: [String] = [],
        rationale: String? = nil,
        revisitTriggers: [String] = [],
        relatedFiles: [String] = []
    ) {
        self.problem = problem
        self.chosen = chosen
        self.alternatives = alternatives
        self.rationale = rationale
        self.revisitTriggers = revisitTriggers
        self.relatedFiles = relatedFiles
    }
}

/// A rule the project follows. Carries good/bad examples (the original dropped these on capture and
/// edit — we preserve them; see `docs/design/00-OVERVIEW.md`).
public struct ConventionData: Codable, Equatable, Sendable, Hashable {
    public var trigger: String?
    public var rule: String
    /// The specific situation or subsystem this convention governs.
    public var appliesWhen: String?
    /// Adjacent cases this convention must NOT be applied to (prevents over-application).
    public var excludesWhen: String?
    public var examples: [Example]
    public var relatedFiles: [String]

    public struct Example: Codable, Equatable, Sendable, Hashable {
        public var bad: String?
        public var good: String?
        public init(bad: String? = nil, good: String? = nil) {
            self.bad = bad
            self.good = good
        }
    }

    public init(
        trigger: String? = nil,
        rule: String,
        appliesWhen: String? = nil,
        excludesWhen: String? = nil,
        examples: [Example] = [],
        relatedFiles: [String] = []
    ) {
        self.trigger = trigger
        self.rule = rule
        self.appliesWhen = appliesWhen
        self.excludesWhen = excludesWhen
        self.examples = examples
        self.relatedFiles = relatedFiles
    }
}

/// A goal and the behaviors that satisfy it. Carries given/when/then behaviors (preserved — the
/// original dropped them on capture).
public struct IntentData: Codable, Equatable, Sendable, Hashable {
    public var goal: String
    public var behaviors: [Behavior]
    public var constraints: [String]
    public var relatedFiles: [String]

    public struct Behavior: Codable, Equatable, Sendable, Hashable {
        public var given: String?
        public var when: String?
        public var then: String?
        public init(given: String? = nil, when: String? = nil, then: String? = nil) {
            self.given = given
            self.when = when
            self.then = then
        }
    }

    public init(
        goal: String,
        behaviors: [Behavior] = [],
        constraints: [String] = [],
        relatedFiles: [String] = []
    ) {
        self.goal = goal
        self.behaviors = behaviors
        self.constraints = constraints
        self.relatedFiles = relatedFiles
    }
}

/// A stable piece of project state, as a category/key/value triple.
public struct FactData: Codable, Equatable, Sendable, Hashable {
    public var category: String
    public var key: String
    public var value: String

    public init(category: String, key: String, value: String) {
        self.category = category
        self.key = key
        self.value = value
    }
}

/// A risk or known problem.
public struct ConcernData: Codable, Equatable, Sendable, Hashable {
    public var issue: String
    public var severity: String
    public var affectedArea: String?
    /// The specific situation or subsystem this concern governs.
    public var appliesWhen: String?
    /// Adjacent cases this concern must NOT be applied to (prevents over-application).
    public var excludesWhen: String?
    public var relatedFiles: [String]

    public init(
        issue: String,
        severity: String,
        affectedArea: String? = nil,
        appliesWhen: String? = nil,
        excludesWhen: String? = nil,
        relatedFiles: [String] = []
    ) {
        self.issue = issue
        self.severity = severity
        self.affectedArea = affectedArea
        self.appliesWhen = appliesWhen
        self.excludesWhen = excludesWhen
        self.relatedFiles = relatedFiles
    }
}

/// A deferred idea / future work.
public struct BacklogData: Codable, Equatable, Sendable, Hashable {
    public var idea: String
    public var priority: String
    public var trigger: String?

    public init(idea: String, priority: String, trigger: String? = nil) {
        self.idea = idea
        self.priority = priority
        self.trigger = trigger
    }
}

/// A durable pointer into the codebase. `snippet` is preserved (the original dropped it).
public struct CodeRefData: Codable, Equatable, Sendable, Hashable {
    public var filePath: String
    public var symbolName: String?
    /// e.g. "L10-L20".
    public var range: String?
    public var snippet: String?

    public init(filePath: String, symbolName: String? = nil, range: String? = nil, snippet: String? = nil) {
        self.filePath = filePath
        self.symbolName = symbolName
        self.range = range
        self.snippet = snippet
    }
}

// MARK: - Tagged union

/// The type-specific payload of a memory, encoded as a `{ "type": ..., "content": {...} }` envelope
/// (matches the original wire format so classifier output and stored data interoperate).
public enum MemoryData: Codable, Equatable, Sendable, Hashable {
    case decision(DecisionData)
    case convention(ConventionData)
    case intent(IntentData)
    case fact(FactData)
    case concern(ConcernData)
    case backlog(BacklogData)
    case codeRef(CodeRefData)

    /// The `MemoryType` discriminant for this payload.
    public var type: MemoryType {
        switch self {
        case .decision: .decision
        case .convention: .convention
        case .intent: .intent
        case .fact: .fact
        case .concern: .concern
        case .backlog: .backlog
        case .codeRef: .codeRef
        }
    }

    /// Per-case payload accessors (nil when the payload is a different case). Used by editors that
    /// need to extract → mutate → re-embed one case's struct.
    public var decisionData: DecisionData? { if case .decision(let d) = self { d } else { nil } }
    public var conventionData: ConventionData? { if case .convention(let c) = self { c } else { nil } }
    public var intentData: IntentData? { if case .intent(let i) = self { i } else { nil } }
    public var factData: FactData? { if case .fact(let f) = self { f } else { nil } }
    public var concernData: ConcernData? { if case .concern(let c) = self { c } else { nil } }
    public var backlogData: BacklogData? { if case .backlog(let b) = self { b } else { nil } }
    public var codeRefData: CodeRefData? { if case .codeRef(let c) = self { c } else { nil } }

    /// Files referenced by this payload (used for edge inference and the detail view).
    public var relatedFiles: [String] {
        switch self {
        case .decision(let d): d.relatedFiles
        case .convention(let c): c.relatedFiles
        case .intent(let i): i.relatedFiles
        case .fact: []
        case .concern(let c): c.relatedFiles
        case .backlog: []
        case .codeRef(let c): [c.filePath]
        }
    }

    /// Same payload with each `relatedFiles` entry rewritten by `transform`. Fact/backlog carry no
    /// files; codeRef's `filePath` is deliberately untouched — `CodeRefExtractor` already emits it
    /// normalized, and it doubles as the node's dedup identity.
    public func mappingRelatedFiles(_ transform: (String) -> String) -> MemoryData {
        switch self {
        case .decision(var d): d.relatedFiles = d.relatedFiles.map(transform); return .decision(d)
        case .convention(var c): c.relatedFiles = c.relatedFiles.map(transform); return .convention(c)
        case .intent(var i): i.relatedFiles = i.relatedFiles.map(transform); return .intent(i)
        case .concern(var c): c.relatedFiles = c.relatedFiles.map(transform); return .concern(c)
        case .fact, .backlog, .codeRef: return self
        }
    }

    private enum CodingKeys: String, CodingKey { case type, content }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MemoryType.self, forKey: .type)
        switch type {
        case .decision: self = .decision(try container.decode(DecisionData.self, forKey: .content))
        case .convention: self = .convention(try container.decode(ConventionData.self, forKey: .content))
        case .intent: self = .intent(try container.decode(IntentData.self, forKey: .content))
        case .fact: self = .fact(try container.decode(FactData.self, forKey: .content))
        case .concern: self = .concern(try container.decode(ConcernData.self, forKey: .content))
        case .backlog: self = .backlog(try container.decode(BacklogData.self, forKey: .content))
        case .codeRef: self = .codeRef(try container.decode(CodeRefData.self, forKey: .content))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .decision(let c): try container.encode(c, forKey: .content)
        case .convention(let c): try container.encode(c, forKey: .content)
        case .intent(let c): try container.encode(c, forKey: .content)
        case .fact(let c): try container.encode(c, forKey: .content)
        case .concern(let c): try container.encode(c, forKey: .content)
        case .backlog(let c): try container.encode(c, forKey: .content)
        case .codeRef(let c): try container.encode(c, forKey: .content)
        }
    }
}
