import Foundation

/// A historical session that can be proposed without mutating the capture queue.
public struct BackfillCandidate: Sendable, Hashable {
    public let sessionId: String
    public let transcript: URL
    public let modifiedAt: Date
    public let cwd: String

    public init(sessionId: String, transcript: URL, modifiedAt: Date, cwd: String) {
        self.sessionId = sessionId
        self.transcript = transcript
        self.modifiedAt = modifiedAt
        self.cwd = cwd
    }
}

/// The exact immutable set shown in the app's consent dialog.
public struct BackfillProposal: Sendable, Equatable {
    public let candidates: [BackfillCandidate]
    public var count: Int { candidates.count }

    public init(candidates: [BackfillCandidate]) {
        self.candidates = candidates
    }
}

/// Separates read-only discovery from the user-authorized queue mutation.
public enum BackfillProposalService {
    public static func discover(
        _ candidates: [BackfillCandidate], store: MemoryStore, now: Date = Date()
    ) -> BackfillProposal {
        var seen = Set<String>()
        let eligible = candidates.filter { candidate in
            guard seen.insert(candidate.sessionId).inserted,
                  !ClaudeCodeSessions.isEphemeral(cwd: candidate.cwd),
                  !SessionIngestor.isLikelyLive(modifiedAt: candidate.modifiedAt, now: now),
                  (try? store.isProcessed(sessionId: candidate.sessionId)) != true
            else { return false }
            return true
        }
        return BackfillProposal(candidates: eligible)
    }

    /// Enqueue only after confirmation. Re-check idempotency because a live drain may have completed
    /// a proposed session while the consent dialog was open.
    @discardableResult
    public static func enqueue(
        _ proposal: BackfillProposal,
        store: MemoryStore,
        supportDirectory: URL = StoreLocation.supportDirectory
    ) -> Int {
        var enqueued = 0
        for candidate in proposal.candidates {
            guard (try? store.isProcessed(sessionId: candidate.sessionId)) != true else { continue }
            do {
                let snapshot = try TranscriptSnapshotStore.snapshot(
                    transcript: candidate.transcript,
                    sessionId: candidate.sessionId,
                    in: supportDirectory
                )
                try store.enqueueOrUpdate(
                    sessionId: candidate.sessionId,
                    projectId: ProjectIdentity.resolve(cwd: candidate.cwd),
                    transcriptPath: snapshot.path,
                    cwd: candidate.cwd,
                    gitSha: nil,
                    gitBranch: nil,
                    isFinal: true,
                    source: .backfill
                )
                enqueued += 1
            } catch {
                continue
            }
        }
        return enqueued
    }
}
