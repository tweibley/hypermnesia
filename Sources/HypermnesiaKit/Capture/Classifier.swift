import Foundation

/// A hint about an existing memory, passed to the classifier so it avoids re-proposing duplicates.
public struct RecentMemoryHint: Sendable, Hashable {
    public let type: MemoryType
    public let title: String
    public init(type: MemoryType, title: String) {
        self.type = type
        self.title = title
    }
}

/// Extracts memory-worthy items from a condensed conversation. Implementations: `claude -p`
/// headless (default), an API-key adapter, or an on-device model — all interchangeable.
public protocol Classifier: Sendable {
    func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint]
    ) async throws -> [ClassifiedMemory]

    /// A focused re-extraction pass. `focus` is an extra instruction appended OUTSIDE the transcript
    /// (e.g. `ClassifierPrompts.focusedRetryNote`) so the model treats it as a directive, not data.
    /// Adapters that can act on it override this; the default ignores `focus` and runs a normal pass,
    /// so existing conformances (e.g. test mocks) need no changes.
    func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint],
        focus: String?
    ) async throws -> [ClassifiedMemory]
}

public extension Classifier {
    func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint],
        focus: String?
    ) async throws -> [ClassifiedMemory] {
        try await classify(conversation, recentMemories: recentMemories)
    }
}

/// One memory proposed by the classifier (before it becomes a draft node).
public struct ClassifiedMemory: Codable, Sendable, Hashable {
    public let type: MemoryType
    public let confidence: Double
    public let title: String
    public let summary: String
    /// Freeform per-type fields the classifier extracted (keys per `MemoryType`).
    public let context: [String: JSONValue]?
    public let relatedFiles: [String]?
    public let sourceQuote: String?

    public init(
        type: MemoryType, confidence: Double = 0.8, title: String, summary: String,
        context: [String: JSONValue]? = nil, relatedFiles: [String]? = nil, sourceQuote: String? = nil
    ) {
        self.type = type
        self.confidence = min(1.0, max(0.0, confidence))
        self.title = title
        self.summary = summary
        self.context = context
        self.relatedFiles = relatedFiles
        self.sourceQuote = sourceQuote
    }

    private enum CodingKeys: String, CodingKey {
        case type, confidence, title, summary, context, relatedFiles, sourceQuote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(MemoryType.self, forKey: .type)
        // Clamp to [0,1]: an LLM sometimes answers "confidence": 90 (percent), which unclamped would
        // give the memory permanent top-of-injection ranking and make its belief penalty-immune.
        let rawConfidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.8  // original default
        confidence = min(1.0, max(0.0, rawConfidence))
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        context = try c.decodeIfPresent([String: JSONValue].self, forKey: .context)
        relatedFiles = try c.decodeIfPresent([String].self, forKey: .relatedFiles)
        sourceQuote = try c.decodeIfPresent(String.self, forKey: .sourceQuote)
    }

    // MARK: - Mapping to typed payload

    /// Build the strongly-typed `MemoryData` from the freeform `context`.
    ///
    /// Faithful to the original's `buildMemoryData`, **except** it preserves
    /// `convention.examples` and `intent.behaviors` when the classifier supplies them (the original
    /// discarded both at capture time — see `docs/design/00-OVERVIEW.md`).
    public func toMemoryData() -> MemoryData {
        let files = relatedFiles ?? []
        switch type {
        case .decision:
            return .decision(.init(
                problem: string("problem"),
                chosen: string("chosen") ?? "",
                alternatives: stringArray("alternatives"),
                rationale: string("rationale"),
                revisitTriggers: stringArray("revisitTriggers"),
                relatedFiles: files
            ))
        case .convention:
            return .convention(.init(
                trigger: string("trigger"),
                rule: string("rule") ?? summary,
                appliesWhen: string("appliesWhen"),
                excludesWhen: string("excludesWhen"),
                examples: examples(),
                relatedFiles: files
            ))
        case .intent:
            return .intent(.init(
                goal: string("goal") ?? summary,
                behaviors: behaviors(),
                constraints: stringArray("constraints"),
                relatedFiles: files
            ))
        case .fact:
            return .fact(.init(
                category: string("category") ?? "state",
                key: string("key") ?? title,
                value: string("value") ?? summary
            ))
        case .concern:
            return .concern(.init(
                issue: string("issue") ?? summary,
                severity: string("severity") ?? "medium",
                affectedArea: string("affectedArea"),
                appliesWhen: string("appliesWhen"),
                excludesWhen: string("excludesWhen"),
                relatedFiles: files
            ))
        case .backlog:
            return .backlog(.init(
                idea: string("idea") ?? summary,
                priority: string("priority") ?? "medium",
                trigger: string("trigger")
            ))
        case .codeRef:
            return .codeRef(.init(
                filePath: string("filePath") ?? files.first ?? "",
                symbolName: string("symbolName"),
                range: string("range"),
                snippet: string("snippet")
            ))
        }
    }

    /// Turn this into a draft `MemoryNode`. `createdAt` is the *session's* time (backdated for
    /// backfill so decay is correct); `conversationId` is the stable Claude Code session id.
    public func toDraftNode(
        projectId: String,
        sessionId: String?,
        createdAt: Date,
        commitSha: String? = nil,
        branch: String? = nil,
        status: MemoryStatus = .draft
    ) -> MemoryNode {
        MemoryNode(
            projectId: projectId, type: type, status: status,
            title: title, summary: summary, data: toMemoryData(),
            confidence: confidence,
            // Quality path: the (validator-adjusted) classifier confidence is the epistemic prior,
            // so it survives instead of being overwritten by age on the first decay pass.
            belief: confidence,
            createdAt: createdAt, updatedAt: createdAt,
            lastValidatedAt: createdAt,
            conversationId: sessionId, sourceQuote: sourceQuote,
            commitSha: commitSha, branch: branch
        )
    }

    // MARK: context helpers

    private func string(_ key: String) -> String? {
        guard let v = context?[key]?.stringValue, !v.isEmpty else { return nil }
        return v
    }
    private func stringArray(_ key: String) -> [String] {
        guard case .array(let items)? = context?[key] else { return [] }
        return items.compactMap(\.stringValue)
    }
    private func examples() -> [ConventionData.Example] {
        guard case .array(let items)? = context?["examples"] else { return [] }
        return items.compactMap { item in
            guard case .object = item else { return nil }
            let bad = item["bad"]?.stringValue, good = item["good"]?.stringValue
            return (bad == nil && good == nil) ? nil : .init(bad: bad, good: good)
        }
    }
    private func behaviors() -> [IntentData.Behavior] {
        guard case .array(let items)? = context?["behaviors"] else { return [] }
        return items.compactMap { item in
            guard case .object = item else { return nil }
            let g = item["given"]?.stringValue, w = item["when"]?.stringValue, t = item["then"]?.stringValue
            return (g == nil && w == nil && t == nil) ? nil : .init(given: g, when: w, then: t)
        }
    }
}

/// Classifier failures (capture treats these as non-fatal — a session just yields no memories).
public enum ClassifierError: LocalizedError {
    case toolFailed(String)
    case emptyOutput
    case unparseable(String)

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let s): "Classifier process failed: \(s)"
        case .emptyOutput: "Classifier returned no output"
        case .unparseable(let s): "Could not parse classifier output: \(s)"
        }
    }
}
