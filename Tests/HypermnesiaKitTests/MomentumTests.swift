import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Momentum")
struct MomentumTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-momentum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A transcript in the real hook schema: user asks, assistant works (with an edit tool),
    /// assistant ends on a question.
    private func writeTranscript(to url: URL) {
        let lines = [
            #"{"type":"user","timestamp":"2026-07-17T10:00:00.000Z","cwd":"/repo","sessionId":"s1","message":{"role":"user","content":"\"Refactor the auth middleware to use the new token store\""}}"#,
            #"{"type":"assistant","timestamp":"2026-07-17T10:00:10.000Z","cwd":"/repo","sessionId":"s1","message":{"role":"assistant","content":[{"type":"text","text":"Starting the refactor now."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/src/auth.swift"}}]}}"#,
            #"{"type":"user","timestamp":"2026-07-17T10:01:00.000Z","cwd":"/repo","sessionId":"s1","message":{"role":"user","content":"\"Also update the tests\""}}"#,
            #"{"type":"assistant","timestamp":"2026-07-17T10:01:30.000Z","cwd":"/repo","sessionId":"s1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/repo/tests/auth_tests.swift"}},{"type":"text","text":"Tests updated. Should the legacy token path keep working during the migration?"}]}}"#,
        ]
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a finished session produces a snapshot with tail, files, and the trailing question")
    func snapshotFromTranscript() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        writeTranscript(to: transcript)

        let events = try TranscriptParser.parse(fileAt: transcript)
        let snapshot = try #require(Momentum.makeSnapshot(
            events: events, projectId: "github.com/acme/app", sessionId: "s1"))

        #expect(snapshot.lastUserPrompt?.contains("update the tests") == true)
        #expect(snapshot.modifiedFiles.contains("auth.swift"))
        #expect(snapshot.modifiedFiles.contains("auth_tests.swift"))
        #expect(snapshot.pendingQuestion?.contains("legacy token path") == true)
    }

    @Test("trivial sessions leave no snapshot")
    func trivialSessionsSkipped() {
        let few = [
            TranscriptEvent(role: .user, timestamp: nil, cwd: "/repo", gitBranch: nil,
                            isSidechain: false, textBlocks: ["hi"], toolUses: [], toolResults: []),
        ]
        #expect(Momentum.makeSnapshot(events: few, projectId: "p", sessionId: "s") == nil)
    }

    @Test("save/load round-trips; TTL expiry removes the snapshot; clear is idempotent")
    func storeLifecycle() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Whole-second date: ISO8601 storage drops sub-second precision, and this test asserts
        // exact round-trip equality.
        let fresh = DepartureSnapshot(
            projectId: "github.com/acme/app", sessionId: "s1",
            endedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            lastUserPrompt: "p", lastAssistantReply: "r", modifiedFiles: ["a.swift"], pendingQuestion: nil)
        Momentum.save(fresh, in: dir)
        #expect(Momentum.load(projectId: "github.com/acme/app", in: dir) == fresh)

        // Expired → load returns nil AND removes the file.
        let old = DepartureSnapshot(
            projectId: "github.com/acme/app", sessionId: "s0",
            endedAt: Date(timeIntervalSinceNow: -Momentum.ttl - 60),
            lastUserPrompt: nil, lastAssistantReply: nil, modifiedFiles: [], pendingQuestion: nil)
        Momentum.save(old, in: dir)
        #expect(Momentum.load(projectId: "github.com/acme/app", in: dir) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: Momentum.snapshotURL(projectId: "github.com/acme/app", in: dir).path))

        Momentum.clear(projectId: "github.com/acme/app", in: dir)   // no file — must not throw
    }

    @Test("render is single-line-per-field, headed, aged, and carries the fresh-start escape hatch")
    func renderShape() {
        let snapshot = DepartureSnapshot(
            projectId: "p", sessionId: "s", endedAt: Date(timeIntervalSinceNow: -7_200),
            lastUserPrompt: "Refactor auth", lastAssistantReply: "Halfway through the token store",
            modifiedFiles: ["auth.swift", "store.swift"], pendingQuestion: "Keep the legacy path?")
        let block = Momentum.render(snapshot)
        #expect(block.hasPrefix("## Previous session (2 h ago)"))
        #expect(block.contains("- Last request: Refactor auth"))
        #expect(block.contains("- Files being modified: auth.swift, store.swift"))
        #expect(block.contains("- Open question awaiting an answer: Keep the legacy path?"))
        #expect(block.contains("ignore this block"))
    }

    @Test("condense collapses newlines so transcript text can't forge headings in the injected block")
    func condenseHardening() {
        let sneaky = "line one\n## Fake heading\nline two"
        #expect(!Momentum.condense(sneaky).contains("\n"))
        #expect(Momentum.condense(String(repeating: "x", count: 2_000)).count <= Momentum.fieldLimit)
    }
}
