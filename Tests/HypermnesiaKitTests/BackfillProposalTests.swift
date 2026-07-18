import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("BackfillProposal")
struct BackfillProposalTests {
    @Test("cancel discards a read-only proposal while confirmation enqueues")
    func consentBoundary() throws {
        let store = try MemoryStore(location: .inMemory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-backfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let transcript = support.appendingPathComponent("historical.jsonl")
        try #"{"type":"summary","summary":"historical"}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let candidate = BackfillCandidate(
            sessionId: "historical",
            transcript: transcript,
            modifiedAt: now.addingTimeInterval(-3_600),
            cwd: "/repo"
        )

        do {
            let canceledProposal = BackfillProposalService.discover([candidate], store: store, now: now)
            #expect(canceledProposal.count == 1)
            // Leaving this scope models the app clearing `backfillProposal` on Cancel.
        }
        #expect(try store.pendingCaptures(limit: 10).isEmpty)

        let confirmedProposal = BackfillProposalService.discover([candidate], store: store, now: now)
        #expect(BackfillProposalService.enqueue(
            confirmedProposal, store: store, supportDirectory: support) == 1)
        let queued = try #require(try store.pendingCaptures(limit: 10).first)
        #expect(queued.sessionId == "historical")
        #expect(queued.source == .backfill)
        #expect(queued.transcriptPath != transcript.path)
        #expect(FileManager.default.fileExists(atPath: queued.transcriptPath))
    }

    @Test("discovery excludes live and processed sessions without writing")
    func eligibility() throws {
        let store = try MemoryStore(location: .inMemory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.markProcessed(.init(
            sessionId: "done", projectId: "p", source: .backfill, memoryCount: 0))
        let candidates = [
            BackfillCandidate(
                sessionId: "done", transcript: URL(fileURLWithPath: "/repo/done.jsonl"),
                modifiedAt: now.addingTimeInterval(-3_600), cwd: "/repo"),
            BackfillCandidate(
                sessionId: "live", transcript: URL(fileURLWithPath: "/repo/live.jsonl"),
                modifiedAt: now, cwd: "/repo"),
        ]

        let proposal = BackfillProposalService.discover(candidates, store: store, now: now)

        #expect(proposal.count == 0)
        #expect(try store.pendingCaptures(limit: 10).isEmpty)
    }
}
