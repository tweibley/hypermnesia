import Foundation

/// One normalized message in a condensed conversation.
public struct ConversationMessage: Sendable, Hashable, Codable {
    public let role: String   // "user" | "assistant"
    public let content: String
    public let timestamp: Date?

    public init(role: String, content: String, timestamp: Date?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// A condensed session ready for classification.
public struct Conversation: Sendable {
    public let sessionId: String?
    public let cwd: String?
    public let gitBranch: String?
    public let messages: [ConversationMessage]

    public init(sessionId: String?, cwd: String?, gitBranch: String?, messages: [ConversationMessage]) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.messages = messages
    }

    public var startedAt: Date? { messages.compactMap(\.timestamp).min() }
    public var endedAt: Date? { messages.compactMap(\.timestamp).max() }
    public var isEmpty: Bool { messages.isEmpty }

    /// Editing tool labels render as `→ Edit(file), Write(file)` lines (see `ConversationBuilder`).
    /// Includes Cursor's edit tool (`ApplyPatch`) and Antigravity's (`write_to_file`,
    /// `replace_file_content`) alongside Claude Code's, so `isEditHeavy` fires for any client.
    /// (`ApplyPatch` may render with or without an arg, so match the bare name too. Antigravity's
    /// `multi_replace_file_content` is covered by its `replace_file_content` substring — the `_`
    /// before it passes the letter-boundary check — so it isn't listed separately, which would
    /// double-count it.)
    static let editToolMarkers = ["Edit(", "Write(", "MultiEdit(", "NotebookEdit(", "Update(",
                                  "ApplyPatch", "write_to_file", "replace_file_content"]
    static let editHeavyThreshold = 2

    /// How many file-editing tool uses the (rendered) transcript contains.
    public var editToolUseCount: Int {
        messages.reduce(0) { acc, m in acc + Self.countEditMarkers(in: m.content) }
    }

    /// Count edit-tool markers at a word boundary, so `Edit(` isn't also counted inside `MultiEdit(`
    /// / `NotebookEdit(` (which would score a single MultiEdit as two edits).
    static func countEditMarkers(in text: String) -> Int {
        var count = 0
        for marker in editToolMarkers {
            var from = text.startIndex
            while let r = text.range(of: marker, range: from..<text.endIndex) {
                let precededByLetter = r.lowerBound > text.startIndex
                    && text[text.index(before: r.lowerBound)].isLetter
                if !precededByLetter { count += 1 }
                from = r.upperBound
            }
        }
        return count
    }

    /// True when the session changed code enough that a durable memory is plausible — used to decide
    /// whether a fruitless first classification pass is worth a focused retry.
    public var isEditHeavy: Bool { editToolUseCount >= Self.editHeavyThreshold }

    /// Render as plain text for an LLM prompt.
    public func transcriptText() -> String {
        messages.map { "\($0.role.uppercased()): \($0.content)" }.joined(separator: "\n\n")
    }
}

/// Condenses raw transcript events into a `Conversation` suitable for classification.
public enum ConversationBuilder {

    public struct Options: Sendable {
        /// Drop subagent (sidechain) entries from the main conversation.
        public var dropSidechain: Bool = true
        /// Max characters kept per user/assistant text block.
        public var maxTextChars: Int = 4_000
        /// Max characters kept per tool result (errors are most useful; successes are noise).
        public var maxToolResultChars: Int = 240
        /// Total character budget; oldest messages are dropped to fit.
        public var maxTotalChars: Int = 60_000
        public init() {}
    }

    public static func build(
        from events: [TranscriptEvent],
        sessionId: String?,
        options: Options = Options()
    ) -> Conversation {
        var messages: [ConversationMessage] = []
        var cwd: String?
        var gitBranch: String?

        for event in events {
            if options.dropSidechain && event.isSidechain { continue }
            cwd = cwd ?? event.cwd
            gitBranch = gitBranch ?? event.gitBranch

            let content = render(event, options: options)
            guard !content.isEmpty else { continue }
            messages.append(ConversationMessage(
                role: event.role.rawValue,
                content: content,
                timestamp: event.timestamp
            ))
        }

        messages = fitToBudget(messages, maxTotalChars: options.maxTotalChars)
        return Conversation(sessionId: sessionId, cwd: cwd, gitBranch: gitBranch, messages: messages)
    }

    /// Convenience: parse a transcript file and condense it.
    public static func build(
        transcriptAt url: URL,
        sessionId: String?,
        options: Options = Options()
    ) throws -> Conversation {
        let events = try TranscriptParser.parse(fileAt: url)
        return build(from: events, sessionId: sessionId, options: options)
    }

    // MARK: - Rendering

    private static func render(_ event: TranscriptEvent, options: Options) -> String {
        var parts: [String] = []

        for text in event.textBlocks {
            parts.append(truncate(text, to: options.maxTextChars))
        }
        if !event.toolUses.isEmpty {
            parts.append("→ " + event.toolUses.map(\.label).joined(separator: ", "))
        }
        for result in event.toolResults where result.isError {
            let text = truncate(result.text, to: options.maxToolResultChars)
            if !text.isEmpty { parts.append("⚠️ tool error: \(text)") }
        }

        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep the most recent messages that fit the total budget (preserving order).
    private static func fitToBudget(_ messages: [ConversationMessage], maxTotalChars: Int) -> [ConversationMessage] {
        var total = 0
        var kept: [ConversationMessage] = []
        for message in messages.reversed() {
            total += message.content.count
            if total > maxTotalChars && !kept.isEmpty { break }
            kept.append(message)
        }
        return kept.reversed()
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
