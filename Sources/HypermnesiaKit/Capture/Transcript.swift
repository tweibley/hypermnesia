import Foundation

/// A single tool invocation pulled from the transcript.
public struct ToolUse: Sendable, Hashable {
    public let id: String?
    public let name: String
    /// A short human label, e.g. `Edit(auth.swift)` or `Bash(npm test)`.
    public let label: String
}

/// The result of a tool call.
public struct ToolResult: Sendable, Hashable {
    public let toolUseID: String?
    public let isError: Bool
    public let text: String
}

/// One meaningful event from a Claude Code transcript (a user or assistant turn).
public struct TranscriptEvent: Sendable, Hashable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let timestamp: Date?
    public let cwd: String?
    public let gitBranch: String?
    /// True for sidechain (subagent) entries — usually dropped from the main conversation.
    public let isSidechain: Bool
    public let textBlocks: [String]
    public let toolUses: [ToolUse]
    public let toolResults: [ToolResult]
}

/// Parses Claude Code transcript JSONL into normalized events.
///
/// The transcript format (verified against a live transcript) is the Anthropic message format
/// wrapped per line: top-level `type`/`timestamp`/`cwd`/`gitBranch`/`sessionId`, plus a `message`
/// object whose `content` is either a string (user prompts) or an array of `text` / `thinking` /
/// `tool_use` / `tool_result` blocks. Non-conversation line types (queue-operation, attachment,
/// ai-title, summary, …) are skipped.
public enum TranscriptParser {

    public static func parse(fileAt url: URL) throws -> [TranscriptEvent] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parseValidated(jsonl: raw)
    }

    public static func parse(jsonl: String) -> [TranscriptEvent] {
        (try? parseValidated(jsonl: jsonl)) ?? []
    }

    /// Parsing for ingest. Skip undecodable lines (truncated final line, mid-write noise) so one
    /// bad record cannot discard an otherwise healthy session. Empty transcripts and transcripts
    /// made entirely of recognized bookkeeping are valid-empty. Input with zero recognized records
    /// is invalid: all-corrupt → `.corrupt`, unknown dialect → `.unrecognized`.
    public static func parseValidated(jsonl: String) throws -> [TranscriptEvent] {
        let decoder = JSONDecoder()
        var events: [TranscriptEvent] = []
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        var recognized = 0
        var skippedCorrupt = 0
        for line in lines {
            guard let data = line.data(using: .utf8) else {
                skippedCorrupt += 1
                continue
            }
            let raw: RawLine
            do {
                raw = try decoder.decode(RawLine.self, from: data)
            } catch {
                skippedCorrupt += 1
                continue
            }

            // Antigravity lines carry `step_index`/`source` instead of a role — a separate dialect.
            if raw.stepIndex != nil, raw.source != nil {
                recognized += 1
                if let event = antigravityEvent(from: raw) { events.append(event) }
                continue
            }
            guard let role = raw.role else {
                if raw.isRecognizedBookkeeping { recognized += 1 }
                continue
            }
            recognized += 1

            var texts: [String] = []
            var uses: [ToolUse] = []
            var results: [ToolResult] = []
            var recoveredTimestamp: Date?   // Cursor embeds the time in the user text, not a field

            switch raw.message?.content {
            case .text(let string):
                if !string.isEmpty { append(text: string, role: role, to: &texts, recovering: &recoveredTimestamp) }
            case .blocks(let blocks):
                for block in blocks {
                    switch block.type {
                    case "text":
                        if let t = block.text, !t.isEmpty { append(text: t, role: role, to: &texts, recovering: &recoveredTimestamp) }
                    case "tool_use":
                        let name = block.name ?? "tool"
                        uses.append(ToolUse(id: block.id, name: name,
                                            label: toolLabel(name: name, input: block.input)))
                    case "tool_result":
                        results.append(ToolResult(
                            toolUseID: block.toolUseID,
                            isError: block.isError ?? false,
                            text: block.content?.flattened ?? ""
                        ))
                    default:
                        break // "thinking" and anything else: ignored
                    }
                }
            case nil:
                break
            }

            events.append(TranscriptEvent(
                role: role,
                timestamp: raw.timestamp.flatMap(parseTimestamp) ?? recoveredTimestamp,
                cwd: raw.cwd,
                gitBranch: raw.gitBranch,
                isSidechain: raw.isSidechain ?? false,
                textBlocks: texts,
                toolUses: uses,
                toolResults: results
            ))
        }
        if !lines.isEmpty, recognized == 0 {
            throw skippedCorrupt > 0 ? TranscriptParseError.corrupt : TranscriptParseError.unrecognized
        }
        return events
    }

    // MARK: - Tool labels

    /// Build a compact `Name(arg)` label from a tool's input.
    static func toolLabel(name: String, input: JSONValue?) -> String {
        guard let input else { return name }
        let argKeys = ["file_path", "path", "command", "pattern", "url", "query", "notebook_path", "prompt"]
        for key in argKeys {
            if let value = input[key]?.stringValue, !value.isEmpty {
                let arg = key.hasSuffix("path") || key == "file_path" ? lastPathComponent(value) : value
                return "\(name)(\(truncate(arg, to: 60)))"
            }
        }
        return name
    }

    private static func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    // MARK: - Antigravity dialect

    /// Map one Antigravity `transcript.jsonl` step onto a normalized event (verified against live
    /// transcripts under `~/.gemini/antigravity-cli/brain/`). Steps are flat objects:
    /// `step_index` / `source` (`USER_EXPLICIT`|`MODEL`|`SYSTEM`) / `type` / `created_at` /
    /// optional `content` (plain string) / optional `tool_calls`. `USER_INPUT` is the user turn,
    /// `PLANNER_RESPONSE` the assistant turn; every other MODEL step is a tool result named after
    /// its tool (`RUN_COMMAND`, `VIEW_FILE`, …). SYSTEM bookkeeping (`CHECKPOINT`,
    /// `CONVERSATION_HISTORY`, `SYSTEM_MESSAGE`) is dropped.
    private static func antigravityEvent(from raw: RawLine) -> TranscriptEvent? {
        let timestamp = raw.createdAt.flatMap(parseTimestamp)
        func event(role: TranscriptEvent.Role, texts: [String] = [], uses: [ToolUse] = [],
                   results: [ToolResult] = []) -> TranscriptEvent {
            TranscriptEvent(role: role, timestamp: timestamp, cwd: nil, gitBranch: nil,
                            isSidechain: false, textBlocks: texts, toolUses: uses, toolResults: results)
        }
        switch raw.type {
        case "USER_INPUT":
            let text = sanitizeAntigravityUserText(raw.content ?? "")
            return text.isEmpty ? nil : event(role: .user, texts: [text])
        case "PLANNER_RESPONSE":
            var texts: [String] = []
            if let content = raw.content, !content.isEmpty { texts.append(content) }
            let uses = (raw.toolCalls ?? []).map { call in
                let name = call.name ?? "tool"
                return ToolUse(id: nil, name: name, label: antigravityToolLabel(name: name, args: call.args))
            }
            return texts.isEmpty && uses.isEmpty ? nil : event(role: .assistant, texts: texts, uses: uses)
        case "ERROR_MESSAGE":
            let text = [raw.error, raw.content].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            return text.isEmpty ? nil : event(
                role: .user, results: [ToolResult(toolUseID: nil, isError: true, text: text)])
        default:
            guard raw.source == "MODEL" else { return nil }   // SYSTEM bookkeeping steps
            let isError = !(raw.error ?? "").isEmpty
            let text = [isError ? raw.error : nil, raw.content].compactMap { $0 }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : event(
                role: .user, results: [ToolResult(toolUseID: nil, isError: isError, text: text)])
        }
    }

    /// Antigravity wraps the prompt as `<USER_REQUEST>…</USER_REQUEST>` followed by metadata tags
    /// (`<ADDITIONAL_METADATA>`, `<USER_SETTINGS_CHANGE>`, …); keep only the request itself.
    static func sanitizeAntigravityUserText(_ text: String) -> String {
        guard text.contains("<USER_REQUEST>") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let inner = innerText(ofTag: "USER_REQUEST", in: text) ?? text
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Name(arg)` label for an Antigravity tool call (TitleCase arg keys, unlike Claude's snake_case).
    static func antigravityToolLabel(name: String, args: JSONValue?) -> String {
        guard let args else { return name }
        let argKeys = ["CommandLine", "AbsolutePath", "TargetFile", "DirectoryPath",
                       "SearchDirectory", "SearchPath", "Pattern", "Query", "Url", "Prompt"]
        for key in argKeys {
            if let value = args[key]?.stringValue.map(unquoteAntigravityArg), !value.isEmpty {
                let isPath = key.hasSuffix("Path") || key == "TargetFile" || key == "SearchDirectory"
                return "\(name)(\(truncate(isPath ? lastPathComponent(value) : value, to: 60)))"
            }
        }
        return name
    }

    /// Antigravity double-encodes tool-call arg strings (the JSON string's *value* is itself a
    /// quoted JSON string, e.g. `"\"/Users/x/repo\""`); unwrap one level when present.
    static func unquoteAntigravityArg(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2,
              let unwrapped = try? JSONDecoder().decode(String.self, from: Data(trimmed.utf8))
        else { return value }
        return unwrapped
    }

    // MARK: - Timestamps

    /// Parse an ISO-8601 timestamp, with or without fractional seconds. Uses the value-type
    /// `ISO8601FormatStyle` (Sendable) rather than `ISO8601DateFormatter` (a non-Sendable class).
    static func parseTimestamp(_ s: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    // MARK: - Cursor user-text sanitization

    /// Append a text block, cleaning Cursor's user-prompt wrapper when present. Cursor wraps the
    /// prompt as `<timestamp>…</timestamp>\n<user_query>…</user_query>` (and may add other tags);
    /// we strip the timestamp tag (recovering the date, since Cursor carries no top-level timestamp)
    /// and unwrap the query. No-op for Claude Code text — those tags don't appear there.
    private static func append(
        text: String, role: TranscriptEvent.Role, to texts: inout [String], recovering timestamp: inout Date?
    ) {
        guard role == .user else { texts.append(text); return }
        let (clean, stamp) = sanitizeUserText(text)
        if !clean.isEmpty { texts.append(clean) }
        if timestamp == nil { timestamp = stamp }
    }

    /// Strip Cursor's `<timestamp>` tag (returning the parsed date) and unwrap `<user_query>`.
    /// Gated on the unambiguous `<user_query>` marker (present on 154/155 real Cursor prompts) so a
    /// Claude Code prompt that merely *mentions* one of these tags is never rewritten or truncated.
    static func sanitizeUserText(_ text: String) -> (text: String, timestamp: Date?) {
        guard text.contains("<user_query>") else { return (text, nil) }
        var body = text
        var stamp: Date?
        if let inner = innerText(ofTag: "timestamp", in: body) {
            stamp = parseCursorTimestamp(inner)
            body = removingTag("timestamp", in: body)
        }
        if let query = innerText(ofTag: "user_query", in: body) {
            body = query
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), stamp)
    }

    private static func innerText(ofTag name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func removingTag(_ name: String, in text: String) -> String {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return text }
        var s = text
        s.removeSubrange(open.lowerBound..<close.upperBound)
        return s
    }

    /// Best-effort parse of Cursor's human timestamp, e.g. `Tuesday, Jun 23, 2026, 11:19 AM (UTC-4)`.
    /// The `(UTC±h)` parenthetical is non-standard, so we fall back to dropping it and reading the
    /// date in UTC — close enough for day-granular backfill decay. Returns nil if unparseable.
    static func parseCursorTimestamp(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a (zzz)"
        if let date = formatter.date(from: s) { return date }
        let stripped = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
        return formatter.date(from: stripped)
    }
}

public enum TranscriptParseError: Error, Sendable, Equatable {
    case corrupt
    case unrecognized
}

// MARK: - Raw decoding

private struct RawLine: Decodable {
    let type: String?
    /// Cursor puts the role at the top level (`{"role":…,"message":…}`); Claude Code uses `type`.
    let roleField: String?
    let timestamp: String?
    let cwd: String?
    let gitBranch: String?
    let isSidechain: Bool?
    let message: RawMessage?
    // Antigravity step fields (`{"step_index":…,"source":…,"type":…,"content":…,"tool_calls":…}`).
    let stepIndex: Int?
    let source: String?
    let createdAt: String?
    let content: String?
    let error: String?
    let toolCalls: [RawAntigravityToolCall]?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, cwd, gitBranch, isSidechain, message, source, content, error
        case roleField = "role"
        case stepIndex = "step_index"
        case createdAt = "created_at"
        case toolCalls = "tool_calls"
    }

    /// Field-by-field tolerant decode: one client's field having an unexpected type in another
    /// client's line (e.g. a top-level `content` that isn't a string) must degrade to `nil` for that
    /// field, not silently drop the whole line.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        type = decode(String.self, .type)
        roleField = decode(String.self, .roleField)
        timestamp = decode(String.self, .timestamp)
        cwd = decode(String.self, .cwd)
        gitBranch = decode(String.self, .gitBranch)
        isSidechain = decode(Bool.self, .isSidechain)
        message = decode(RawMessage.self, .message)
        stepIndex = decode(Int.self, .stepIndex)
        source = decode(String.self, .source)
        createdAt = decode(String.self, .createdAt)
        content = decode(String.self, .content)
        error = decode(String.self, .error)
        toolCalls = decode([RawAntigravityToolCall].self, .toolCalls)
    }

    /// Claude lines carry `type: user|assistant`; Cursor lines carry top-level `role`. Marker lines
    /// (Cursor's `type: turn_ended`, Claude's `summary`/`queue-operation`/…) resolve to `nil`.
    var role: TranscriptEvent.Role? {
        switch type ?? roleField {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    /// Records emitted by supported clients that intentionally carry no conversation event.
    var isRecognizedBookkeeping: Bool {
        guard let type else { return false }
        return [
            "queue-operation", "ai-title", "summary", "attachment", "turn_ended",
            "system", "progress", "file-history-snapshot"
        ].contains(type)
    }
}

/// One entry of an Antigravity step's `tool_calls` array.
private struct RawAntigravityToolCall: Decodable {
    let name: String?
    let args: JSONValue?
}

private struct RawMessage: Decodable {
    let role: String?
    let content: RawContent?
}

/// `content` is a string (user prompts) or an array of blocks (assistant turns, tool results).
private enum RawContent: Decodable {
    case text(String)
    case blocks([RawBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else if let blocks = try? container.decode([RawBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .blocks([])
        }
    }

    /// Flatten content to plain text (used for tool-result content, which may be string or blocks).
    var flattened: String {
        switch self {
        case .text(let s): s
        case .blocks(let blocks): blocks.compactMap(\.text).joined(separator: "\n")
        }
    }
}

private struct RawBlock: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let name: String?
    let id: String?
    let input: JSONValue?
    let toolUseID: String?
    let isError: Bool?
    let content: RawContent?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, name, id, input, content
        case toolUseID = "tool_use_id"
        case isError = "is_error"
    }
}
