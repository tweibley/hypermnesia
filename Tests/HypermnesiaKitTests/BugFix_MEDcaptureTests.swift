import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression coverage for the MED-capture bug cluster:
///  1. `ClaudeCodeSessions.firstCwd` must scan past a huge early attachment line (was capped at a
///     fixed 200 KB prefix, so a big pasted blob before the cwd line hid the session forever).
///  2. `SessionIngestor.ingestSession` must return a rich `.failed` (and NOT seal the session) on a
///     classifier error or a transient read error — only *genuinely* undecodable input is sealed.
///  3. `reconcile` must not absorb a fresh sighting into a superseded (obsolete) memory.
@Suite("BugFix MED-capture")
struct BugFixMEDCaptureTests {

    // MARK: helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ht-medcap-\(UUID().uuidString).jsonl")
    }

    /// Write `n` alternating user/assistant events carrying `cwd`, faithful to the transcript schema.
    private func writeTranscript(_ n: Int, cwd: String = "/repo", to url: URL) {
        var lines: [String] = []
        for i in 0..<n {
            let role = i % 2 == 0 ? "user" : "assistant"
            let content = role == "user"
                ? "\"message \(i)\""
                : "[{\"type\":\"text\",\"text\":\"reply \(i)\"}]"
            lines.append(#"{"type":"\#(role)","timestamp":"2026-06-18T10:00:\#(String(format: "%02d", i)).000Z","cwd":"\#(cwd)","sessionId":"s","message":{"role":"\#(role)","content":\#(content)}}"#)
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns one usable fact memory (survives the validation gate).
    final class OneFactClassifier: Classifier, @unchecked Sendable {
        private(set) var calls = 0
        func classify(_ conversation: Conversation, recentMemories: [RecentMemoryHint]) async throws -> [ClassifiedMemory] {
            calls += 1
            return [ClassifiedMemory(type: .fact, title: "fact \(calls)", summary: "some durable state",
                                     context: ["category": .string("state"), "key": .string("k"), "value": .string("v")])]
        }
    }

    /// Always throws — simulates a transient classifier failure (bad API key, rate limit, no network).
    struct AlwaysFailingClassifier: Classifier {
        func classify(_ conversation: Conversation, recentMemories: [RecentMemoryHint]) async throws -> [ClassifiedMemory] {
            throw ClassifierError.toolFailed("simulated classifier failure")
        }
    }

    // MARK: - Bug: firstCwd fixed-prefix cap

    @Test("firstCwd finds the cwd even when a huge attachment line precedes it")
    func firstCwdScansPastLargeAttachment() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        // A ~700 KB pasted blob on line 1 (no cwd), then the real cwd-bearing line. The old fixed
        // 200 KB read never reached line 2 and returned nil, silently dropping the whole session.
        let bigBlob = String(repeating: "A", count: 700_000)
        let line1 = #"{"type":"user","message":{"role":"user","content":"\#(bigBlob)"}}"#
        let line2 = #"{"type":"user","cwd":"/Users/me/project","sessionId":"s","message":{"role":"user","content":"hi"}}"#
        try (line1 + "\n" + line2 + "\n").write(to: url, atomically: true, encoding: .utf8)

        #expect(ClaudeCodeSessions.firstCwd(of: url) == "/Users/me/project")
    }

    @Test("firstCwd still reads the cwd from a normal first line")
    func firstCwdNormalCase() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        writeTranscript(2, cwd: "/repo", to: url)
        #expect(ClaudeCodeSessions.firstCwd(of: url) == "/repo")
    }

    // MARK: - Bug: ingest seals on transient errors / hides failures

    @Test("a classifier failure returns .failed and does NOT seal the session (retryable)")
    func classifierFailureIsRetryable() async throws {
        let store = try MemoryStore(location: .inMemory)
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        writeTranscript(6, to: url)

        let outcome = await SessionIngestor.ingestSession(
            transcript: url, sessionId: "s", projectId: "p",
            classifier: AlwaysFailingClassifier(), store: store, source: .backfill)

        #expect(outcome == .failed(reason: "classification failed", terminal: false))
        // Crucially: the session is NOT sealed, so a later backfill retries it.
        #expect((try? store.isProcessed(sessionId: "s")) == false)
    }

    @Test("a missing transcript returns .failed and does NOT seal the session (transient read error)")
    func missingTranscriptIsRetryable() async throws {
        let store = try MemoryStore(location: .inMemory)
        let missing = tempURL()   // never written

        let outcome = await SessionIngestor.ingestSession(
            transcript: missing, sessionId: "s", projectId: "p",
            classifier: OneFactClassifier(), store: store, source: .backfill)

        // File-level error (ENOENT) must be reported, not sealed — the incremental path already
        // distinguishes this; the backfill path must too.
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect((try? store.isProcessed(sessionId: "s")) == false)
    }

    @Test("a successful backfill returns .captured and seals the session")
    func successCapturesAndSeals() async throws {
        let store = try MemoryStore(location: .inMemory)
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        writeTranscript(6, to: url)

        let outcome = await SessionIngestor.ingestSession(
            transcript: url, sessionId: "s", projectId: "p",
            classifier: OneFactClassifier(), store: store, source: .backfill)

        #expect(outcome == .captured(1))
        #expect((try? store.isProcessed(sessionId: "s")) == true)
    }

    // MARK: - Bug: reconcile absorbs a fresh sighting into a superseded memory

    private let project = "github.com/acme/app"

    private func fact(_ title: String, _ summary: String, id: String = UUID().uuidString,
                      status: MemoryStatus = .confirmed, supersededById: String? = nil) -> MemoryNode {
        MemoryNode(id: id, projectId: project, type: .fact, status: status, title: title, summary: summary,
                   data: .fact(.init(category: "state", key: "k", value: "v")),
                   supersededById: supersededById)
    }

    @Test("a re-observed rule is NOT absorbed into the superseded memory it revives")
    func freshSightingNotAbsorbedIntoSupersededNode() throws {
        let store = try MemoryStore(location: .inMemory)

        // `newer` superseded `old`. `old` is obsolete and never surfaced by hydration.
        let newer = fact("Formatter choice", "The project formats with the new bespoke formatter")
        let old = fact("Indentation rule", "The project indents with tabs, never spaces",
                       supersededById: newer.id)
        try store.upsert([newer, old])
        #expect(try #require(try store.node(id: old.id)).isSuperseded == true)

        // A fresh capture that re-establishes the OLD rule (identical title+summary → a dedup match
        // against `old`). It must NOT be routed into the superseded node.
        let candidate = fact("Indentation rule", "The project indents with tabs, never spaces",
                             status: .draft)
        let fresh = SessionIngestor.reconcile([candidate], projectId: project, store: store, autoConfirm: 3)

        // The candidate survives as a genuinely new node instead of vanishing into `old`.
        #expect(fresh.count == 1)
        // The obsolete node was NOT reinforced (no phantom sighting).
        let oldAfter = try #require(try store.node(id: old.id))
        #expect(oldAfter.timesSighted == 0)
        #expect(oldAfter.timesApplied == 0)
    }
}
