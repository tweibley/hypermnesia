import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Transcript")
struct TranscriptTests {

    /// A faithful slice of the Claude Code transcript schema, including noise lines that must be
    /// skipped (queue-operation, ai-title) and a sidechain entry.
    let fixture = """
    {"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-01T10:00:00.000Z","sessionId":"s1","content":"noise"}
    {"type":"user","timestamp":"2026-06-01T10:00:01.000Z","cwd":"/Users/x/proj","gitBranch":"main","sessionId":"s1","isSidechain":false,"message":{"role":"user","content":"Switch the database from MySQL to Postgres and use UUID primary keys."}}
    {"type":"assistant","timestamp":"2026-06-01T10:00:05.500Z","cwd":"/Users/x/proj","gitBranch":"main","sessionId":"s1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal reasoning here","signature":"sig"},{"type":"text","text":"I'll migrate to Postgres and switch primary keys to UUID."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/Users/x/proj/Sources/DB.swift","old_string":"a","new_string":"b"}}]}}
    {"type":"user","timestamp":"2026-06-01T10:00:06.000Z","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"OK"}]}}
    {"type":"assistant","timestamp":"2026-06-01T10:00:09.000Z","sessionId":"s1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter that should be dropped"}]}}
    {"type":"assistant","timestamp":"2026-06-01T10:00:10.000Z","sessionId":"s1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test"}},{"type":"text","text":"Tests pass."}]}}
    {"type":"user","timestamp":"2026-06-01T10:00:11.000Z","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"build failed: missing import"}]}}
    {"type":"ai-title","aiTitle":"DB migration","sessionId":"s1"}
    """

    @Test("parser extracts only user/assistant turns with text and tool labels")
    func parsing() {
        let events = TranscriptParser.parse(jsonl: fixture)
        // 2 user prompts (incl. tool_result) + 3 assistant + 1 sidechain assistant = 6 conversational
        #expect(events.count == 6)

        let first = events[0]
        #expect(first.role == .user)
        #expect(first.cwd == "/Users/x/proj")
        #expect(first.gitBranch == "main")
        #expect(first.textBlocks.first?.contains("Postgres") == true)

        let assistant = events[1]
        #expect(assistant.role == .assistant)
        // thinking dropped; text kept; tool_use captured with a basename label
        #expect(assistant.textBlocks.count == 1)
        #expect(assistant.toolUses.first?.label == "Edit(DB.swift)")
        #expect(assistant.timestamp != nil)
    }

    @Test("builder condenses, drops thinking + sidechain, annotates tools, keeps error results")
    func building() {
        let events = TranscriptParser.parse(jsonl: fixture)
        let convo = ConversationBuilder.build(from: events, sessionId: "s1")

        #expect(convo.cwd == "/Users/x/proj")
        #expect(convo.gitBranch == "main")
        // sidechain message removed
        #expect(!convo.messages.contains { $0.content.contains("subagent chatter") })
        // thinking never appears
        #expect(!convo.messages.contains { $0.content.contains("internal reasoning") })
        // tool use annotated
        #expect(convo.messages.contains { $0.content.contains("→ Edit(DB.swift)") })
        // bash label present
        #expect(convo.messages.contains { $0.content.contains("Bash(swift test)") })
        // error tool result surfaced; success ("OK") suppressed
        #expect(convo.messages.contains { $0.content.contains("tool error: build failed") })
        #expect(!convo.messages.contains { $0.content == "OK" })

        #expect(convo.startedAt == TranscriptParser.parseTimestamp("2026-06-01T10:00:01.000Z"))
    }

    @Test("budget keeps the most recent messages")
    func budget() {
        let events = TranscriptParser.parse(jsonl: fixture)
        var opts = ConversationBuilder.Options()
        opts.maxTotalChars = 30
        let convo = ConversationBuilder.build(from: events, sessionId: "s1", options: opts)
        #expect(!convo.messages.isEmpty)
        // the last message should be retained
        #expect(convo.messages.last?.content.contains("tool error") == true)
    }

    @Test("strict parser distinguishes valid-empty from bad input")
    func strictValidity() throws {
        #expect(try TranscriptParser.parseValidated(jsonl: "").isEmpty)
        #expect(try TranscriptParser.parseValidated(
            jsonl: #"{"type":"summary","summary":"bookkeeping only"}"#
        ).isEmpty)
        #expect(throws: TranscriptParseError.corrupt) {
            try TranscriptParser.parseValidated(jsonl: "{not json")
        }
        #expect(throws: TranscriptParseError.unrecognized) {
            try TranscriptParser.parseValidated(jsonl: #"{"foreign":"format"}"#)
        }
    }
}
