import Foundation

/// Where a session left off — the short-term counterpart to durable memory. Captured at
/// SessionEnd, injected at the next SessionStart, gone after seven days. Memory answers
/// "why is the codebase like this?"; momentum answers "what was I doing?".
public struct DepartureSnapshot: Codable, Sendable, Equatable {
    public let projectId: String
    public let sessionId: String
    public let endedAt: Date
    public let lastUserPrompt: String?
    public let lastAssistantReply: String?
    public let modifiedFiles: [String]
    /// The assistant's unanswered trailing question, if the session ended on one.
    public let pendingQuestion: String?
}

public enum Momentum {
    /// Snapshots expire after a week — after that, "what you were doing" is stale guidance.
    public static let ttl: TimeInterval = 7 * 86_400
    /// Sessions with fewer transcript events than this leave no snapshot (nothing worth resuming).
    static let minimumEvents = 4
    static let fieldLimit = 700
    static let maxFiles = 8

    // MARK: - Build

    /// Build a snapshot from a finished session's transcript events. Nil for trivial sessions.
    public static func makeSnapshot(
        events: [TranscriptEvent], projectId: String, sessionId: String, endedAt: Date = Date()
    ) -> DepartureSnapshot? {
        guard events.count >= minimumEvents else { return nil }
        let convo = ConversationBuilder.build(from: events, sessionId: sessionId)
        guard !convo.isEmpty else { return nil }

        let lastUser = convo.messages.last(where: { $0.role == "user" })?.content
        let lastAssistant = convo.messages.last(where: { $0.role == "assistant" })?.content
        return DepartureSnapshot(
            projectId: projectId,
            sessionId: sessionId,
            endedAt: endedAt,
            lastUserPrompt: lastUser.map(condense),
            lastAssistantReply: lastAssistant.map(condense),
            modifiedFiles: modifiedFiles(in: convo),
            pendingQuestion: lastAssistant.flatMap(trailingQuestion)
        )
    }

    /// The capture-hook entry point: parse the transcript, build, persist. Failure-safe — a hook
    /// must never break the session over a snapshot.
    public static func recordDeparture(
        transcriptURL: URL, projectId: String, sessionId: String,
        in directory: URL = StoreLocation.supportDirectory
    ) {
        guard let events = try? TranscriptParser.parse(fileAt: transcriptURL),
              let snapshot = makeSnapshot(events: events, projectId: projectId, sessionId: sessionId) else { return }
        save(snapshot, in: directory)
    }

    // MARK: - Store (one latest snapshot per project, JSON on disk)

    public static func snapshotURL(projectId: String, in directory: URL = StoreLocation.supportDirectory) -> URL {
        let safe = projectId.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent("momentum").appendingPathComponent(String(safe) + ".json")
    }

    public static func save(_ snapshot: DepartureSnapshot, in directory: URL = StoreLocation.supportDirectory) {
        let url = snapshotURL(projectId: snapshot.projectId, in: directory)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The project's snapshot, or nil when missing or older than the TTL (expired files are removed).
    public static func load(
        projectId: String, now: Date = Date(), in directory: URL = StoreLocation.supportDirectory
    ) -> DepartureSnapshot? {
        let url = snapshotURL(projectId: projectId, in: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(DepartureSnapshot.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard now.timeIntervalSince(snapshot.endedAt) < ttl else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return snapshot
    }

    public static func clear(projectId: String, in directory: URL = StoreLocation.supportDirectory) {
        try? FileManager.default.removeItem(at: snapshotURL(projectId: projectId, in: directory))
    }

    // MARK: - Render

    /// The `## Previous session` block injected ahead of project memory at SessionStart.
    public static func render(_ snapshot: DepartureSnapshot, now: Date = Date()) -> String {
        let age = relativeAge(from: snapshot.endedAt, to: now)
        var lines = [
            "## Previous session (\(age))",
            "Working state from your last session in this project, in case you're continuing:",
        ]
        if let prompt = snapshot.lastUserPrompt {
            lines.append("- Last request: \(prompt)")
        }
        if let reply = snapshot.lastAssistantReply {
            lines.append("- Where it left off: \(reply)")
        }
        if !snapshot.modifiedFiles.isEmpty {
            lines.append("- Files being modified: " + snapshot.modifiedFiles.joined(separator: ", "))
        }
        if let question = snapshot.pendingQuestion {
            lines.append("- Open question awaiting an answer: \(question)")
        }
        lines.append("If this session is a fresh task, ignore this block and start clean.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Single line, bounded — transcript text must not be able to forge headings in the injected block.
    static func condense(_ text: String) -> String {
        let flat = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count <= fieldLimit ? flat : String(flat.prefix(fieldLimit - 1)) + "…"
    }

    /// File names from the conversation's edit-tool annotations ("→ Edit(auth.swift), Write(x.py)").
    static func modifiedFiles(in convo: Conversation) -> [String] {
        var seen = Set<String>()
        var files: [String] = []
        let pattern = #"(?:Edit|Write|MultiEdit|NotebookEdit|Update)\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for message in convo.messages {
            let range = NSRange(message.content.startIndex..., in: message.content)
            for match in regex.matches(in: message.content, range: range) {
                guard let r = Range(match.range(at: 1), in: message.content) else { continue }
                let file = String(message.content[r])
                if seen.insert(file).inserted { files.append(file) }
                if files.count >= maxFiles { return files }
            }
        }
        return files
    }

    /// The final sentence of the assistant's last message, when it ends with a question. The
    /// condensed form appends tool annotations ("→ Edit(x)") after the text, so a trailing
    /// annotation without its own question mark is stripped before the suffix check.
    static func trailingQuestion(_ text: String) -> String? {
        var flat = condense(text)
        if !flat.hasSuffix("?"),
           let arrow = flat.range(of: "→", options: .backwards),
           !flat[arrow.upperBound...].contains("?") {
            flat = String(flat[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard flat.hasSuffix("?") else { return nil }
        // Find the start of the final sentence: the character after the last sentence
        // terminator ('.', '!', '?') that is *followed by whitespace*. A bare dot inside a
        // filename or version ("settings.json", "v2.3") is not a boundary, so it no longer
        // truncates the question into a garbled fragment ("json file?", "3 first?").
        let chars = Array(flat)
        var start = 0
        for i in chars.indices.dropLast() where chars[i] == "." || chars[i] == "!" || chars[i] == "?" {
            if chars[i + 1].isWhitespace { start = i + 1 }
        }
        let question = String(chars[start...]).trimmingCharacters(in: .whitespaces)
        guard question.count >= 8 else { return nil }
        // Guard against a mid-token split: a real question opens with a capital letter or a
        // common interrogative. Anything else means the boundary landed inside a token, so
        // drop the question rather than inject a meaningless fragment.
        let firstWord = question.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let interrogatives: Set<String> = [
            "should", "want", "do", "does", "did", "can", "could", "would", "will",
            "which", "what", "why", "how", "is", "are", "was", "were", "shall", "may", "any",
        ]
        guard question.first?.isUppercase == true || interrogatives.contains(firstWord) else { return nil }
        return question
    }

    static func relativeAge(from: Date, to: Date) -> String {
        let seconds = to.timeIntervalSince(from)
        switch seconds {
        case ..<(90 * 60): return "\(max(1, Int(seconds / 60))) min ago"
        case ..<(36 * 3_600): return "\(Int((seconds / 3_600).rounded())) h ago"
        default: return "\(Int((seconds / 86_400).rounded())) days ago"
        }
    }
}
