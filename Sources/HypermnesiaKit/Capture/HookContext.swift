import Foundation

/// Which agent client a hook is firing from — selects the input/output dialect. The CLI adds an
/// `ExpressibleByArgument` conformance so it can be a `--client` option.
public enum HookClient: String, Sendable, CaseIterable {
    case claude, cursor, antigravity

    /// The client's own name for each required hook field — drives the per-client
    /// "skipped — missing X" diagnostics so support sees the field the client actually sends.
    var sessionIdField: String {
        switch self {
        case .claude: "session_id"
        case .cursor: "conversation_id"
        case .antigravity: "conversationId"
        }
    }
    var cwdField: String {
        switch self {
        case .claude: "cwd"
        case .cursor: "workspace_roots / CURSOR_PROJECT_DIR"
        case .antigravity: "workspacePaths"
        }
    }
    var transcriptPathField: String {
        switch self {
        case .claude: "transcript_path"
        case .cursor: "transcript_path (reconstruct failed)"
        case .antigravity: "transcriptPath"
        }
    }
}

/// A normalized view of a hook's stdin JSON, abstracting over Claude Code and Cursor field names so
/// the `hydrate`/`capture` commands share one code path.
///
/// Claude carries `session_id` / `cwd` / `hook_event_name` (TitleCase). Cursor carries
/// `conversation_id` / `workspace_roots[]` / `hook_event_name` (camelCase) and may omit
/// `transcript_path` (only emitted when transcript export is on), so we reconstruct it from
/// (cwd, conversation_id).
public struct HookContext: Sendable, Equatable {
    public let sessionId: String?
    public let cwd: String?
    public let transcriptPath: String?
    public let prompt: String?
    /// Normalized event: "SessionStart" | "UserPromptSubmit" | "Stop" | "SessionEnd".
    public let event: String

    public var isFinal: Bool { event == "SessionEnd" }

    /// Client-specific source names of the required `capture` fields that are absent — drives a precise
    /// "skipped — missing X" diagnostic instead of a silent bail.
    public func missingForCapture(client: HookClient) -> [String] {
        var missing: [String] = []
        if (sessionId ?? "").isEmpty { missing.append(client.sessionIdField) }
        if (cwd ?? "").isEmpty { missing.append(client.cwdField) }
        if (transcriptPath ?? "").isEmpty { missing.append(client.transcriptPathField) }
        return missing
    }

    /// Source name of the required `hydrate` field if absent (just `cwd`).
    public func missingForHydrate(client: HookClient) -> [String] {
        (cwd ?? "").isEmpty ? [client.cwdField] : []
    }

    public init(sessionId: String?, cwd: String?, transcriptPath: String?, prompt: String?, event: String) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.prompt = prompt
        self.event = event
    }

    public static func parse(_ input: [String: Any], client: HookClient) -> HookContext {
        switch client {
        case .claude:
            return HookContext(
                sessionId: input["session_id"] as? String,
                cwd: input["cwd"] as? String,
                transcriptPath: input["transcript_path"] as? String,
                prompt: input["prompt"] as? String,
                event: (input["hook_event_name"] as? String) ?? "SessionStart"
            )
        case .cursor:
            let env = ProcessInfo.processInfo.environment
            // Skip empty workspace roots / env vars so we never compose a bogus `path:` project id or
            // a `…/projects//…` transcript path.
            let cwd = (input["workspace_roots"] as? [Any])?
                .compactMap({ $0 as? String }).first(where: { !$0.isEmpty })
                ?? env["CURSOR_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            let sessionId = input["conversation_id"] as? String
            var transcript = input["transcript_path"] as? String
                ?? env["CURSOR_TRANSCRIPT_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            if transcript == nil, let cwd, let sessionId {
                transcript = CursorSessions.transcriptPath(cwd: cwd, sessionId: sessionId).path
            }
            return HookContext(
                sessionId: sessionId,
                cwd: cwd,
                transcriptPath: transcript,
                prompt: input["prompt"] as? String,
                event: normalizeCursorEvent(input["hook_event_name"] as? String)
            )
        case .antigravity:
            // Antigravity payloads are camelCase and carry no event-name field — the event is
            // whichever hook the command was registered under, so it's recovered from the payload
            // shape instead (Stop carries `fullyIdle`/`terminationReason`, PreInvocation carries
            // `invocationNum`). `transcriptPath` arrives `~`-relative in the documented payloads.
            let cwd = (input["workspacePaths"] as? [Any])?
                .compactMap({ $0 as? String }).first(where: { !$0.isEmpty })
            let transcript = (input["transcriptPath"] as? String)
                .flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            return HookContext(
                sessionId: input["conversationId"] as? String,
                cwd: cwd,
                transcriptPath: transcript,
                prompt: nil,   // Antigravity has no per-prompt hook payload
                event: normalizeAntigravityEvent(input)
            )
        }
    }

    /// Map Cursor's camelCase hook events onto the same normalized names the Claude path uses.
    private static func normalizeCursorEvent(_ raw: String?) -> String {
        switch raw {
        case "sessionStart": return "SessionStart"
        case "beforeSubmitPrompt": return "UserPromptSubmit"
        case "stop": return "Stop"
        case "sessionEnd": return "SessionEnd"
        default: return raw ?? "SessionStart"
        }
    }

    /// Infer the normalized event from an Antigravity payload's shape.
    ///
    /// Stop (`fullyIdle`/`terminationReason` present) maps to the final-flush `SessionEnd` when the
    /// agent is fully idle, else to the in-session checkpoint `Stop`. PreInvocation
    /// (`invocationNum` present) fires before *every* model call, so only the very first call of a
    /// fresh conversation (`invocationNum == 0` with an essentially empty trajectory) counts as
    /// `SessionStart`; the rest surface as `PreInvocation` so hydrate can stay silent mid-session.
    private static func normalizeAntigravityEvent(_ input: [String: Any]) -> String {
        if input["fullyIdle"] != nil || input["terminationReason"] != nil {
            return (input["fullyIdle"] as? Bool ?? true) ? "SessionEnd" : "Stop"
        }
        if input["invocationNum"] != nil {
            let isConversationStart = (input["invocationNum"] as? Int ?? 0) == 0
                && (input["initialNumSteps"] as? Int ?? 0) <= 1
            return isConversationStart ? "SessionStart" : "PreInvocation"
        }
        return "SessionStart"
    }
}
