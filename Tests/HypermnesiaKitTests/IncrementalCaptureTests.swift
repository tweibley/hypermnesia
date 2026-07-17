import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("IncrementalCapture")
struct IncrementalCaptureTests {

    /// Records the conversation it was asked to classify, returns a fixed memory.
    final class MockClassifier: Classifier, @unchecked Sendable {
        private(set) var lastMessageCount = 0
        private(set) var calls = 0
        func classify(_ conversation: Conversation, recentMemories: [RecentMemoryHint]) async throws -> [ClassifiedMemory] {
            lastMessageCount = conversation.messages.count
            calls += 1
            return [ClassifiedMemory(type: .fact, title: "fact \(calls)", summary: "s",
                                     context: ["category": .string("state"), "key": .string("k"), "value": .string("v")])]
        }
    }

    /// Write `n` alternating user/assistant events to `url` (faithful to the transcript schema).
    private func writeTranscript(_ n: Int, to url: URL) {
        var lines: [String] = []
        for i in 0..<n {
            let role = i % 2 == 0 ? "user" : "assistant"
            let content = role == "user"
                ? "\"message \(i)\""
                : "[{\"type\":\"text\",\"text\":\"reply \(i)\"}]"
            lines.append(#"{"type":"\#(role)","timestamp":"2026-06-18T10:00:\#(String(format: "%02d", i)).000Z","cwd":"/repo","sessionId":"s","message":{"role":"\#(role)","content":\#(content)}}"#)
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ht-incr-\(UUID().uuidString).jsonl")
    }

    /// A classifier that always throws (simulates a transient API failure).
    struct FailingClassifier: Classifier {
        func classify(_ conversation: Conversation, recentMemories: [RecentMemoryHint]) async throws -> [ClassifiedMemory] {
            throw ClassifierError.toolFailed("simulated failure")
        }
    }

    @Test("classifies only the new slice and advances the cursor")
    func sliceAndCursor() async throws {
        let store = try MemoryStore(location: .inMemory)
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let mock = MockClassifier()

        // 6 events → meets threshold → classify all 6, cursor → 6.
        writeTranscript(6, to: url)
        let o1 = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                         classifier: mock, store: store, minNewEvents: 6)
        #expect(o1 == .captured(1))
        #expect(mock.lastMessageCount == 6)
        #expect(try store.cursor(sessionId: "s") == 6)

        // Grow to 12 → only the 6 new events are classified, cursor → 12.
        writeTranscript(12, to: url)
        let o2 = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                         classifier: mock, store: store, minNewEvents: 6)
        #expect(o2 == .captured(1))
        #expect(mock.lastMessageCount == 6)   // the SLICE, not all 12
        #expect(try store.cursor(sessionId: "s") == 12)

        // No new events → waiting, no classification.
        let o3 = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                         classifier: mock, store: store, minNewEvents: 6)
        #expect(o3 == .waiting)
        #expect(mock.calls == 2)
    }

    @Test("waits for the threshold unless it's the final flush")
    func thresholdAndFinalFlush() async throws {
        let store = try MemoryStore(location: .inMemory)
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let mock = MockClassifier()

        writeTranscript(3, to: url)   // below threshold
        let o1 = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                         classifier: mock, store: store, minNewEvents: 6)
        #expect(o1 == .waiting)
        #expect(try store.cursor(sessionId: "s") == 0)

        // Final flush captures the remainder regardless of threshold.
        let o2 = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                         classifier: mock, store: store, minNewEvents: 6, isFinal: true)
        #expect(o2 == .captured(1))
        #expect(try store.cursor(sessionId: "s") == 3)
    }

    @Test("a classifier failure does NOT advance the cursor (so events are retried, not lost)")
    func failureDoesNotAdvanceCursor() async throws {
        let store = try MemoryStore(location: .inMemory)
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        writeTranscript(8, to: url)

        let failed = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                             classifier: FailingClassifier(), store: store, minNewEvents: 6)
        #expect(failed == .failed)
        #expect(try store.cursor(sessionId: "s") == 0)   // cursor untouched — events not skipped

        // A later successful pass over the same events still captures them.
        let ok = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                         classifier: MockClassifier(), store: store, minNewEvents: 6)
        #expect(ok == .captured(1))
        #expect(try store.cursor(sessionId: "s") == 8)
    }

    @Test("a persist failure does NOT advance the cursor (incremental slice stays retryable)")
    func persistFailureDoesNotAdvanceCursor() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-persist-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        writeTranscript(8, to: url)

        // Classification succeeds, but every store write throws (closed connection) — the old
        // `try? upsert` behavior would still have advanced the cursor and dropped the memory.
        let broken = try MemoryStore(location: .file(dbURL))
        try broken.closeForTesting()
        let outcome = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                              classifier: MockClassifier(), store: broken, minNewEvents: 6)
        #expect(outcome == .failed)

        // A fresh handle on the same DB sees no advanced cursor: the slice is still retryable.
        let reopened = try MemoryStore(location: .file(dbURL))
        #expect(try reopened.cursor(sessionId: "s") == 0)
        let retried = await SessionIngestor.ingestIncremental(transcript: url, sessionId: "s", projectId: "p",
                                                              classifier: MockClassifier(), store: reopened, minNewEvents: 6)
        #expect(retried == .captured(1))
    }

    @Test("a persist failure does NOT seal a whole-session backfill ingest")
    func persistFailureDoesNotSealBackfill() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-persist-bf-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        writeTranscript(8, to: url)

        let broken = try MemoryStore(location: .file(dbURL))
        try broken.closeForTesting()
        let count = await SessionIngestor.ingest(transcript: url, sessionId: "s", projectId: "p",
                                                 classifier: MockClassifier(), store: broken, source: .backfill)
        #expect(count == 0)

        // Session must NOT be marked processed: a re-run retries and captures the memory.
        let reopened = try MemoryStore(location: .file(dbURL))
        #expect(try reopened.isProcessed(sessionId: "s") == false)
        let retried = await SessionIngestor.ingest(transcript: url, sessionId: "s", projectId: "p",
                                                   classifier: MockClassifier(), store: reopened, source: .backfill)
        #expect(retried == 1)
        #expect(try reopened.isProcessed(sessionId: "s") == true)
    }

    @Test("pruneFinishedCaptures drops old done/error rows but never pending ones")
    func pruneFinishedCaptures() throws {
        let store = try MemoryStore(location: .inMemory)
        for (i, terminal) in [CaptureStatus.done, .error].enumerated() {
            try store.enqueueOrUpdate(sessionId: "s\(i)", projectId: "p", transcriptPath: "/t\(i)",
                                      cwd: "/c", gitSha: nil, gitBranch: nil, isFinal: true)
            let id = try #require(try store.pendingCaptures(limit: 10).first).id
            #expect(try store.beginProcessing(id: id))
            #expect(try store.finishProcessing(id: id, status: terminal))
        }
        try store.enqueueOrUpdate(sessionId: "s-live", projectId: "p", transcriptPath: "/t",
                                  cwd: "/c", gitSha: nil, gitBranch: nil, isFinal: false)

        // Within the retention window nothing is pruned; past it, only the terminal rows go.
        #expect(try store.pruneFinishedCaptures(olderThanDays: 30) == 0)
        let later = Date().addingTimeInterval(31 * 86_400)
        #expect(try store.pruneFinishedCaptures(olderThanDays: 30, now: later) == 2)
        #expect(try store.pendingCaptures(limit: 10).count == 1)   // the pending row survives
    }

    @Test("a re-enqueue during processing is not clobbered by the drain's completion (compare-and-set)")
    func reenqueueDuringProcessingSurvives() throws {
        let store = try MemoryStore(location: .inMemory)
        try store.enqueueOrUpdate(sessionId: "s", projectId: "p", transcriptPath: "/t",
                                  cwd: "/c", gitSha: nil, gitBranch: nil, isFinal: false)
        let id = try #require(try store.pendingCaptures(limit: 10).first).id

        // Drain claims the row (pending → processing).
        #expect(try store.beginProcessing(id: id) == true)

        // SessionEnd arrives mid-classify: re-enqueue flips the row back to pending + isFinal.
        try store.enqueueOrUpdate(sessionId: "s", projectId: "p", transcriptPath: "/t2",
                                  cwd: "/c", gitSha: nil, gitBranch: nil, isFinal: true)

        // The drain now tries to seal it .done — but the compare-and-set must NOT land, because the
        // row is no longer .processing. The re-enqueued final slice survives for the next drain.
        #expect(try store.finishProcessing(id: id, status: .done) == false)
        let row = try #require(try store.captureItem(id: id))
        #expect(row.status == .pending)
        #expect(row.isFinal == true)
        #expect(row.transcriptPath == "/t2")
        #expect(try store.pendingCaptures(limit: 10).count == 1)
    }
}
