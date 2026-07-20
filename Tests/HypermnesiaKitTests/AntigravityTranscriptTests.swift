import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("AntigravityTranscript")
struct AntigravityTranscriptTests {

    /// A faithful slice of Antigravity's `transcript.jsonl` schema (verified against live
    /// transcripts): flat steps with `step_index`/`source`/`type`/`created_at`, the
    /// `<USER_REQUEST>` prompt wrapper, double-encoded `tool_calls` arg strings, tool results as
    /// steps named after the tool, and SYSTEM bookkeeping (`CONVERSATION_HISTORY`, `CHECKPOINT`)
    /// that must be skipped.
    let fixture = #"""
    {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-24T02:15:46Z","content":"<USER_REQUEST>\nSwitch the database to Postgres.\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-05-23T22:15:46-04:00.\n</ADDITIONAL_METADATA>"}
    {"step_index":1,"source":"SYSTEM","type":"CONVERSATION_HISTORY","status":"DONE","created_at":"2026-05-24T02:15:47Z"}
    {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-24T02:15:47Z","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"npm test\"","Cwd":"\"/Users/x/proj\""}}]}
    {"step_index":3,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-05-24T02:15:48Z","content":"1 test failed","error":"exit status 1"}
    {"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-24T02:15:49Z","tool_calls":[{"name":"write_to_file","args":{"TargetFile":"\"/Users/x/proj/Sources/DB.swift\""}},{"name":"multi_replace_file_content","args":{"TargetFile":"\"/Users/x/proj/Sources/Schema.swift\""}}]}
    {"step_index":5,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-05-24T02:15:50Z","content":"{{ CHECKPOINT 0 }}"}
    {"step_index":6,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-24T02:15:51Z","content":"Done — migrated to Postgres."}
    """#

    @Test("parser maps Antigravity steps: roles, wrapper stripping, tool labels, skipped bookkeeping")
    func parsing() {
        let events = TranscriptParser.parse(jsonl: fixture)
        // USER_INPUT + 3 PLANNER_RESPONSEs + 1 tool result; CONVERSATION_HISTORY/CHECKPOINT dropped.
        #expect(events.count == 5)

        let user = events[0]
        #expect(user.role == .user)
        // Wrapper + metadata tags stripped, timestamp read from created_at.
        #expect(user.textBlocks == ["Switch the database to Postgres."])
        #expect(user.timestamp != nil)

        // Tool-call args are double-encoded strings; labels unwrap them.
        let runner = events[1]
        #expect(runner.role == .assistant)
        #expect(runner.toolUses.first?.label == "run_command(npm test)")

        // A failed tool step surfaces as an error tool result (feeds the classifier's error view).
        let result = events[2]
        #expect(result.toolResults.first?.isError == true)
        #expect(result.toolResults.first?.text.contains("exit status 1") == true)

        let editor = events[3]
        #expect(editor.toolUses.map(\.label) == ["write_to_file(DB.swift)", "multi_replace_file_content(Schema.swift)"])
        // Double-encoded AbsolutePath/TargetFile unwrapped to full paths for codeRef extraction.
        #expect(editor.toolUses.map(\.editedFilePath) == [
            "/Users/x/proj/Sources/DB.swift",
            "/Users/x/proj/Sources/Schema.swift",
        ])

        let final = events[4]
        #expect(final.role == .assistant)
        #expect(final.textBlocks == ["Done — migrated to Postgres."])
    }

    @Test("builder renders Antigravity tools and flags edit-heavy sessions without double-counting multi_replace")
    func building() {
        let events = TranscriptParser.parse(jsonl: fixture)
        let convo = ConversationBuilder.build(from: events, sessionId: "agy1")

        #expect(convo.messages.contains { $0.content.contains("→ run_command(npm test)") })
        #expect(convo.messages.contains { $0.content.contains("⚠️ tool error:") })
        // write_to_file + multi_replace_file_content → exactly 2 edits (multi_replace counts once,
        // via its replace_file_content substring), which makes the session edit-heavy.
        #expect(convo.editToolUseCount == 2)
        #expect(convo.isEditHeavy)
        #expect(convo.endedAt != nil)
    }

    @Test("sanitizeAntigravityUserText keeps only the request; unquoteAntigravityArg unwraps one level")
    func sanitize() {
        let wrapped = "<USER_REQUEST>\nDo the thing.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nModel changed.\n</USER_SETTINGS_CHANGE>"
        #expect(TranscriptParser.sanitizeAntigravityUserText(wrapped) == "Do the thing.")
        // Unwrapped text passes through trimmed.
        #expect(TranscriptParser.sanitizeAntigravityUserText("  plain prompt \n") == "plain prompt")

        #expect(TranscriptParser.unquoteAntigravityArg(#""/Users/x/proj""#) == "/Users/x/proj")
        #expect(TranscriptParser.unquoteAntigravityArg("/Users/x/proj") == "/Users/x/proj")
        #expect(TranscriptParser.unquoteAntigravityArg(#""with \"inner\" quotes""#) == #"with "inner" quotes"#)
    }

    @Test("Claude- and Cursor-format lines still parse unchanged (dialect tolerance is additive)")
    func otherDialectsStillWork() {
        let claude = #"{"type":"user","timestamp":"2026-06-01T10:00:01.000Z","cwd":"/Users/x/proj","message":{"role":"user","content":"Use SQLite."}}"#
        let events = TranscriptParser.parse(jsonl: claude)
        #expect(events.count == 1)
        #expect(events[0].role == .user)
        #expect(events[0].textBlocks.first == "Use SQLite.")

        let cursor = #"{"role":"assistant","message":{"content":[{"type":"text","text":"Hi."}]}}"#
        #expect(TranscriptParser.parse(jsonl: cursor).first?.role == .assistant)
    }

    @Test("session discovery finds transcripts under brain/<id>/.system_generated/logs")
    func sessionDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-agy-brain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversation = root.appendingPathComponent("ec33ebf9-0cba-4100-8142-c61503f6c587", isDirectory: true)
        let transcript = AntigravitySessions.transcriptURL(inConversationDir: conversation)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: transcript)
        // A non-conversation dir (Antigravity keeps e.g. tempmediaStorage/ alongside) is skipped.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tempmediaStorage"), withIntermediateDirectories: true)

        let found = AntigravitySessions.allTranscripts(in: [root])
        #expect(found.count == 1)
        #expect(found.first?.sessionId == "ec33ebf9-0cba-4100-8142-c61503f6c587")
        // contentsOfDirectory may hand back the /private/var form of the /var temp dir — compare
        // canonical paths, not URLs.
        #expect(found.first.map { CanonicalPath.resolve($0.url.path) } == CanonicalPath.resolve(transcript.path))

        // When the untruncated transcript_full.jsonl exists (what live hooks deliver), discovery
        // prefers it over the checkpoint-truncated transcript.jsonl.
        let full = transcript.deletingLastPathComponent().appendingPathComponent("transcript_full.jsonl")
        try Data(fixture.utf8).write(to: full)
        #expect(AntigravitySessions.transcriptURL(inConversationDir: conversation).lastPathComponent == "transcript_full.jsonl")
        #expect(AntigravitySessions.allTranscripts(in: [root]).first?.url.lastPathComponent == "transcript_full.jsonl")

        // The workspace is recovered from the first directory-carrying tool call (`Cwd`), unquoted.
        #expect(AntigravitySessions.firstCwd(of: transcript) == "/Users/x/proj")
    }
}

@Suite("AntigravityHookContext")
struct AntigravityHookContextTests {

    @Test("PreInvocation at conversation start normalizes to SessionStart and expands the transcript tilde")
    func preInvocationStart() {
        let input: [String: Any] = [
            "invocationNum": 0,
            "initialNumSteps": 1,
            "conversationId": "c1",
            "workspacePaths": ["/Users/x/proj"],
            "transcriptPath": "~/.gemini/antigravity/brain/c1/.system_generated/logs/transcript.jsonl",
        ]
        let ctx = HookContext.parse(input, client: .antigravity)
        #expect(ctx.event == "SessionStart")
        #expect(ctx.sessionId == "c1")
        #expect(ctx.cwd == "/Users/x/proj")
        #expect(ctx.transcriptPath?.hasPrefix("/") == true)   // `~` expanded
        #expect(ctx.transcriptPath?.hasSuffix("/brain/c1/.system_generated/logs/transcript.jsonl") == true)
        #expect(!ctx.isFinal)
    }

    @Test("mid-session PreInvocations stay PreInvocation so hydrate never re-injects")
    func preInvocationMidSession() {
        let later: [String: Any] = ["invocationNum": 3, "initialNumSteps": 10, "conversationId": "c1"]
        #expect(HookContext.parse(later, client: .antigravity).event == "PreInvocation")
        // A fresh execution in an ongoing conversation restarts invocationNum but not the trajectory.
        let newTurn: [String: Any] = ["invocationNum": 0, "initialNumSteps": 12, "conversationId": "c1"]
        #expect(HookContext.parse(newTurn, client: .antigravity).event == "PreInvocation")
    }

    @Test("Stop maps to SessionEnd when fully idle, to the Stop checkpoint otherwise")
    func stopEvents() {
        let idle: [String: Any] = [
            "terminationReason": "model_stop", "fullyIdle": true,
            "conversationId": "c1", "workspacePaths": ["/Users/x/proj"],
            "transcriptPath": "/tmp/t.jsonl",
        ]
        let final = HookContext.parse(idle, client: .antigravity)
        #expect(final.event == "SessionEnd")
        #expect(final.isFinal)

        var busy = idle
        busy["fullyIdle"] = false
        let checkpoint = HookContext.parse(busy, client: .antigravity)
        #expect(checkpoint.event == "Stop")
        #expect(!checkpoint.isFinal)
    }

    @Test("missing-field helpers name Antigravity's camelCase fields; empty workspacePaths fall through")
    func missingFields() {
        let bare = HookContext.parse(["invocationNum": 0], client: .antigravity)
        #expect(bare.missingForCapture(client: .antigravity) == ["conversationId", "workspacePaths", "transcriptPath"])
        #expect(bare.missingForHydrate(client: .antigravity) == ["workspacePaths"])

        let empty = HookContext.parse(["workspacePaths": ["", ""], "conversationId": "c1"], client: .antigravity)
        #expect(empty.cwd == nil)   // present-but-empty entries must not become cwd:""
    }
}
