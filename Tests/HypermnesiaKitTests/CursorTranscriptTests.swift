import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("CursorTranscript")
struct CursorTranscriptTests {

    /// A faithful slice of Cursor's transcript schema: top-level `role` (no `type`), `message.content`
    /// blocks of `text`/`tool_use` (tool_use has no `id`), the `<timestamp>`/`<user_query>` user
    /// wrapper, and a `turn_ended` marker line that must be skipped.
    let fixture = """
    {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Tuesday, Jun 23, 2026, 11:19 AM (UTC-4)</timestamp>\\n<user_query>\\nSwitch the database to Postgres and use UUID primary keys.\\n</user_query>"}]}}
    {"role":"assistant","message":{"content":[{"type":"text","text":"I'll migrate to Postgres and switch to UUID keys."},{"type":"tool_use","name":"ApplyPatch","input":{"path":"/Users/x/proj/Sources/DB.swift"}}]}}
    {"role":"assistant","message":{"content":[{"type":"tool_use","name":"ReadFile","input":{"path":"/Users/x/proj/Sources/DB.swift"}},{"type":"tool_use","name":"ApplyPatch","input":{"path":"/Users/x/proj/Sources/Schema.swift"}}]}}
    {"type":"turn_ended","status":"success"}
    """

    @Test("parser reads Cursor's role-keyed lines, skips turn_ended, unwraps the user query")
    func parsing() {
        let events = TranscriptParser.parse(jsonl: fixture)
        // 1 user + 2 assistant; turn_ended dropped.
        #expect(events.count == 3)

        let user = events[0]
        #expect(user.role == .user)
        let prompt = user.textBlocks.first ?? ""
        #expect(prompt.contains("Postgres"))
        // Wrapper tags stripped.
        #expect(!prompt.contains("<timestamp>"))
        #expect(!prompt.contains("<user_query>"))
        // Timestamp recovered from the <timestamp> tag (Cursor carries no top-level timestamp).
        #expect(user.timestamp != nil)

        let assistant = events[1]
        #expect(assistant.role == .assistant)
        #expect(assistant.textBlocks.count == 1)
        #expect(assistant.toolUses.first?.label == "ApplyPatch(DB.swift)")
        #expect(assistant.toolUses.first?.editedFilePath == "/Users/x/proj/Sources/DB.swift")
        // tool_use without an `id` still parses.
        #expect(assistant.toolUses.first?.id == nil)

        let reads = events[2].toolUses
        #expect(reads.first { $0.name == "ReadFile" }?.editedFilePath == nil)
        #expect(reads.first { $0.name == "ApplyPatch" }?.editedFilePath == "/Users/x/proj/Sources/Schema.swift")
    }

    @Test("builder annotates Cursor tools and flags edit-heavy sessions via ApplyPatch")
    func building() {
        let events = TranscriptParser.parse(jsonl: fixture)
        let convo = ConversationBuilder.build(from: events, sessionId: "c1")

        #expect(convo.messages.contains { $0.content.contains("→ ApplyPatch(DB.swift)") })
        #expect(convo.messages.contains { $0.content.contains("ReadFile(DB.swift)") })
        // Two ApplyPatch uses → edit-heavy (drives the focused-retry heuristic).
        #expect(convo.editToolUseCount == 2)
        #expect(convo.isEditHeavy)
        // endedAt comes from the recovered user timestamp (no other line carries one).
        #expect(convo.endedAt != nil)
    }

    @Test("sanitizeUserText strips the timestamp + unwraps the query; parseCursorTimestamp reads the date")
    func sanitize() {
        let raw = "<timestamp>Tuesday, Jun 23, 2026, 11:19 AM (UTC-4)</timestamp>\n<user_query>\nDo the thing.\n</user_query>"
        let (clean, stamp) = TranscriptParser.sanitizeUserText(raw)
        #expect(clean == "Do the thing.")
        #expect(stamp != nil)

        // Non-Cursor text is returned unchanged.
        let plain = TranscriptParser.sanitizeUserText("just a normal prompt")
        #expect(plain.text == "just a normal prompt")
        #expect(plain.timestamp == nil)

        // A Claude prompt that merely *mentions* these tags must NOT be rewritten or truncated:
        // without a `<user_query>` wrapper the text is returned verbatim.
        let mentionsTimestamp = "Use the <timestamp>X</timestamp> placeholder, then continue."
        #expect(TranscriptParser.sanitizeUserText(mentionsTimestamp).text == mentionsTimestamp)

        #expect(TranscriptParser.parseCursorTimestamp("Tuesday, Jun 23, 2026, 11:19 AM (UTC-4)") != nil)
        #expect(TranscriptParser.parseCursorTimestamp("not a date") == nil)
    }

    @Test("decode(encodedDir:) inverts the lossy encoding for paths that exist on disk")
    func decodeInvertsEncoding() throws {
        // Real directories with the characters the encoding collapses: '/', '-', '.', '_'.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-dec-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("my-app.v2/sub_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = nested.path                       // …/ht-dec-…/my-app.v2/sub_dir
        let encoded = CursorSessions.encode(path: original)
        #expect(CursorSessions.decode(encodedDir: encoded) == original)

        // A directory that never existed can't be recovered — decode must say so, not guess.
        #expect(CursorSessions.decode(encodedDir: "Users-nobody-not-a-real-dir-\(UUID().uuidString)") == nil)
    }

    @Test("Claude-format lines still parse unchanged (dialect tolerance is additive)")
    func claudeStillWorks() {
        let claude = #"{"type":"user","timestamp":"2026-06-01T10:00:01.000Z","cwd":"/Users/x/proj","message":{"role":"user","content":"Use SQLite."}}"#
        let events = TranscriptParser.parse(jsonl: claude)
        #expect(events.count == 1)
        #expect(events[0].role == .user)
        #expect(events[0].cwd == "/Users/x/proj")
        #expect(events[0].textBlocks.first == "Use SQLite.")
    }
}

@Suite("HookContext")
struct HookContextTests {

    @Test("Cursor hook input maps onto the normalized context")
    func cursorDialect() {
        let input: [String: Any] = [
            "conversation_id": "conv-123",
            "workspace_roots": ["/Users/x/proj", "/Users/x/other"],
            "transcript_path": "/tmp/t.jsonl",
            "hook_event_name": "sessionEnd",
        ]
        let ctx = HookContext.parse(input, client: .cursor)
        #expect(ctx.sessionId == "conv-123")
        #expect(ctx.cwd == "/Users/x/proj")        // first workspace root
        #expect(ctx.transcriptPath == "/tmp/t.jsonl")
        #expect(ctx.event == "SessionEnd")
        #expect(ctx.isFinal)
    }

    @Test("Cursor reconstructs the transcript path when the hook omits it")
    func cursorTranscriptFallback() {
        let input: [String: Any] = [
            "conversation_id": "abc",
            "workspace_roots": ["/Users/x/proj"],
            "hook_event_name": "stop",
        ]
        let ctx = HookContext.parse(input, client: .cursor)
        #expect(ctx.event == "Stop")
        #expect(!ctx.isFinal)
        #expect(ctx.transcriptPath == CursorSessions.transcriptPath(cwd: "/Users/x/proj", sessionId: "abc").path)
    }

    @Test("empty workspace roots fall through rather than yielding an empty cwd")
    func cursorEmptyWorkspaceRoot() {
        let input: [String: Any] = [
            "conversation_id": "abc",
            "workspace_roots": ["", ""],   // present but empty — must not become cwd:""
            "hook_event_name": "stop",
        ]
        let ctx = HookContext.parse(input, client: .cursor)
        // No usable cwd and no CURSOR_PROJECT_DIR in the test env → nil, so capture/hydrate bail out
        // rather than composing a `…/projects//…` path.
        #expect(ctx.cwd == nil)
        #expect(ctx.transcriptPath == nil)
    }

    @Test("Claude hook input maps onto the normalized context")
    func claudeDialect() {
        let input: [String: Any] = [
            "session_id": "s1",
            "cwd": "/Users/x/proj",
            "transcript_path": "/tmp/c.jsonl",
            "hook_event_name": "SessionEnd",
        ]
        let ctx = HookContext.parse(input, client: .claude)
        #expect(ctx.sessionId == "s1")
        #expect(ctx.cwd == "/Users/x/proj")
        #expect(ctx.isFinal)
    }

    @Test("missing-field helpers name the absent fields per client (for diagnostics)")
    func missingFields() {
        // A complete Cursor capture payload → nothing missing.
        let ok = HookContext.parse([
            "conversation_id": "c", "workspace_roots": ["/p"], "transcript_path": "/t.jsonl", "hook_event_name": "stop",
        ], client: .cursor)
        #expect(ok.missingForCapture(client: .cursor).isEmpty)
        #expect(ok.missingForHydrate(client: .cursor).isEmpty)

        // No workspace root and no conversation_id → both named with Cursor's field names. (transcript_path
        // can't be reconstructed without a cwd/sessionId, so it's missing too.)
        let bare = HookContext.parse(["hook_event_name": "sessionStart"], client: .cursor)
        #expect(bare.missingForCapture(client: .cursor) == ["conversation_id", "workspace_roots / CURSOR_PROJECT_DIR", "transcript_path (reconstruct failed)"])
        #expect(bare.missingForHydrate(client: .cursor) == ["workspace_roots / CURSOR_PROJECT_DIR"])

        // Claude uses its own field names.
        let claudeBare = HookContext.parse(["hook_event_name": "Stop"], client: .claude)
        #expect(claudeBare.missingForCapture(client: .claude) == ["session_id", "cwd", "transcript_path"])
    }
}
