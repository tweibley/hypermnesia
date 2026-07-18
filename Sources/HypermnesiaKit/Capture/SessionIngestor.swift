import Foundation

/// Turns one session transcript into stored memories: classify → backdated draft nodes → persist,
/// recording the session as processed (idempotent). Shared by live capture (`drain`) and `backfill`.
public enum SessionIngestor {

    /// Result of an incremental ingest pass.
    public enum Outcome: Sendable, Equatable {
        case captured(Int)   // succeeded (cursor advanced); N memories created
        case waiting         // nothing new yet (cursor unchanged)
        case failed          // classifier/parse error — cursor NOT advanced, safe to retry
    }

    static let maxAttempts = 5

    /// A transcript touched within this window may belong to an in-flight session.
    public static let liveWindow: TimeInterval = 120

    /// Whether a transcript is likely still being written (an active session). Bulk backfill skips
    /// these so it can't seal a session mid-flight — the live capture hooks (or a later backfill,
    /// once the session goes quiet) finish it. Does not affect the live hook path or single-session
    /// backfill of an explicitly chosen transcript.
    public static func isLikelyLive(modifiedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(modifiedAt) < liveWindow
    }

    /// Ingest a whole session (used by backfill). Returns the number of memories created.
    /// On a classifier error the session is *not* marked processed, so a re-run retries it.
    @discardableResult
    public static func ingest(
        transcript: URL,
        sessionId: String,
        projectId: String,
        classifier: Classifier,
        store: MemoryStore,
        source: CaptureSource,
        status: MemoryStatus = .draft,
        commitSha: String? = nil
    ) async -> Int {
        guard !((try? store.isProcessed(sessionId: sessionId)) ?? false) else { return 0 }

        // Respect a live-capture cursor: if hooks already classified events 0..cursor, only classify
        // the remaining slice so backfill doesn't re-extract (and re-dedup / spuriously re-confirm)
        // memories already captured live. A session with no cursor is backfilled whole, as before.
        let cursor = (try? store.cursor(sessionId: sessionId)) ?? 0
        let parsedEvents = try? TranscriptParser.parse(fileAt: transcript)
        let convo: Conversation?
        if cursor > 0, let events = parsedEvents {
            guard events.count > cursor else {
                // Already fully captured live — just seal it, don't reclassify anything.
                try? store.markProcessed(.init(sessionId: sessionId, projectId: projectId, source: source, memoryCount: 0))
                return 0
            }
            convo = ConversationBuilder.build(from: Array(events[cursor...]), sessionId: sessionId)
        } else {
            convo = try? ConversationBuilder.build(transcriptAt: transcript, sessionId: sessionId)
        }
        guard let convo, !convo.isEmpty else {
            try? store.markProcessed(.init(sessionId: sessionId, projectId: projectId, source: source, memoryCount: 0))
            return 0
        }

        let recent = ((try? store.nodes(projectId: projectId, limit: 40)) ?? [])
            .map { RecentMemoryHint(type: $0.type, title: $0.title) }

        let rawMemories: [ClassifiedMemory]
        do {
            rawMemories = try await classifier.classify(convo, recentMemories: recent)
        } catch {
            return 0   // don't seal a session that failed to classify — re-running backfill retries it
        }

        // ── Validation gate: filter degenerate captures, cap confidence on weak ones ──────────
        var memories = validated(rawMemories)

        // ── Fallback re-extraction: retry ONCE when the first pass yielded nothing usable AND
        // something was plausibly missed — either the classifier produced only rejected output, or it
        // returned nothing at all on a session that clearly edited code (the dominant capture leak).
        // The retry is FOCUSED (a targeted directive), not an identical re-run; we skip it for
        // low-activity empty sessions so genuinely memory-less sessions don't pay double cost.
        if shouldRetryExtraction(producedNothing: memories.isEmpty,
                                 firstPassWasNonEmpty: !rawMemories.isEmpty,
                                 editHeavy: convo.isEditHeavy) {
            if let retried = try? await classifier.classify(
                convo, recentMemories: recent, focus: ClassifierPrompts.focusedRetryNote) {
                memories = validated(retried)
            }
        }

        let when = convo.endedAt ?? Date()
        let nodes = memories.map { memory in
            DecayEngine.decayed(   // age confidence so old sessions land Aging/Stale/Dormant
                memory.toDraftNode(
                    projectId: projectId, sessionId: sessionId, createdAt: when,
                    commitSha: commitSha, branch: convo.gitBranch, status: status
                )
            )
        }
        let config = AppConfigStore.load()
        let fresh = reconcile(nodes, projectId: projectId, store: store,
                              autoConfirm: config.autoConfirmAfterSightings,
                              confirmConfident: config.autoConfirmConfidentCaptures)
        do {
            // Persist BEFORE sealing. If the write fails (locked DB, full disk), the session must
            // stay unprocessed so a re-run retries it — sealing anyway would silently discard the
            // classified memories forever.
            try store.upsert(fresh)
        } catch {
            return 0
        }
        // Advance the cursor to the full transcript so a later live/incremental drain sees nothing new.
        if let events = parsedEvents { try? store.setCursor(sessionId: sessionId, projectId: projectId, count: events.count) }
        try? store.markProcessed(.init(sessionId: sessionId, projectId: projectId, source: source, memoryCount: fresh.count))
        if !fresh.isEmpty {
            MemoryActivityLog.append(.init(
                projectId: projectId,
                sessionId: sessionId,
                eventType: .capture,
                memoryIds: fresh.map(\.id),
                count: fresh.count,
                metadata: ["source": source.rawValue]
            ))
        }
        return fresh.count
    }

    /// Incrementally ingest a *live* session: classify only the transcript events past the cursor,
    /// once at least `minNewEvents` have accumulated (or `isFinal`). The cursor advances **only on
    /// success**, so a transient classifier failure never silently skips events.
    public static func ingestIncremental(
        transcript: URL,
        sessionId: String,
        projectId: String,
        classifier: Classifier,
        store: MemoryStore,
        minNewEvents: Int = 6,
        isFinal: Bool = false,
        commitSha: String? = nil
    ) async -> Outcome {
        guard let events = try? TranscriptParser.parse(fileAt: transcript) else { return .failed }
        let cursor = (try? store.cursor(sessionId: sessionId)) ?? 0
        guard events.count > cursor else { return .waiting }

        let newEvents = Array(events[cursor...])
        guard isFinal || newEvents.count >= minNewEvents else { return .waiting }

        let convo = ConversationBuilder.build(from: newEvents, sessionId: sessionId)
        guard !convo.isEmpty else {
            try? store.setCursor(sessionId: sessionId, projectId: projectId, count: events.count)
            return .captured(0)
        }

        let recent = ((try? store.nodes(projectId: projectId, limit: 60)) ?? [])
            .map { RecentMemoryHint(type: $0.type, title: $0.title) }

        let rawMemories: [ClassifiedMemory]
        do {
            rawMemories = try await classifier.classify(convo, recentMemories: recent)
        } catch {
            return .failed   // do NOT advance the cursor — these events will be retried
        }

        // ── Validation gate: filter degenerate captures, cap confidence on weak ones ──────────
        var memories = validated(rawMemories)

        // ── Fallback re-extraction: retry ONCE when the first pass yielded nothing usable AND
        // something was plausibly missed — either the classifier produced only rejected output, or it
        // returned nothing at all on a session that clearly edited code (the dominant capture leak).
        // The retry is FOCUSED (a targeted directive), not an identical re-run; we skip it for
        // low-activity empty sessions so genuinely memory-less sessions don't pay double cost.
        if shouldRetryExtraction(producedNothing: memories.isEmpty,
                                 firstPassWasNonEmpty: !rawMemories.isEmpty,
                                 editHeavy: convo.isEditHeavy) {
            if let retried = try? await classifier.classify(
                convo, recentMemories: recent, focus: ClassifierPrompts.focusedRetryNote) {
                memories = validated(retried)
            }
        }

        let when = convo.endedAt ?? Date()
        let nodes = memories.map {
            DecayEngine.decayed($0.toDraftNode(
                projectId: projectId, sessionId: sessionId, createdAt: when,
                commitSha: commitSha, branch: convo.gitBranch, status: .draft
            ))
        }
        let config = AppConfigStore.load()
        let fresh = reconcile(nodes, projectId: projectId, store: store,
                              autoConfirm: config.autoConfirmAfterSightings,
                              confirmConfident: config.autoConfirmConfidentCaptures)
        do {
            // Persist BEFORE advancing the cursor: a failed write must leave the slice retryable
            // (.failed), not silently skipped. If the cursor write fails after a successful upsert,
            // the retry re-classifies the slice and reconcile reinforces the duplicates — wasteful
            // but lossless.
            try store.upsert(fresh)
            try store.setCursor(sessionId: sessionId, projectId: projectId, count: events.count)
        } catch {
            return .failed
        }
        if !fresh.isEmpty {
            MemoryActivityLog.append(.init(
                projectId: projectId,
                sessionId: sessionId,
                eventType: .capture,
                memoryIds: fresh.map(\.id),
                count: fresh.count,
                metadata: ["source": CaptureSource.live.rawValue]
            ))
        }
        return .captured(fresh.count)
    }

    /// What a drain pass accomplished — `failures` are sessions whose classification failed this
    /// pass (left pending/errored), so callers can report a truthful status instead of "up to date".
    public struct DrainReport: Sendable, Equatable {
        public let added: Int
        public let failures: Int
        public static let idle = DrainReport(added: 0, failures: 0)
    }

    /// Drain the capture queue: classify each pending session (incrementally) into memories.
    /// Coordinated by an advisory file lock so the app and the CLI never drain at the same time —
    /// returns `.idle` immediately if another drainer holds the lock.
    @discardableResult
    public static func drainQueue(
        store: MemoryStore,
        classifier: Classifier,
        limit: Int = 100,
        progress: (@Sendable (_ processed: Int, _ total: Int, _ addedSoFar: Int) -> Void)? = nil
    ) async -> DrainReport {
        try? FileManager.default.createDirectory(at: StoreLocation.supportDirectory, withIntermediateDirectories: true)
        let lockPath = StoreLocation.supportDirectory.appendingPathComponent("drain.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; return .idle }
        defer { flock(fd, LOCK_UN); close(fd) }

        // We hold the drain lock, so any `.processing` row is orphaned from a drain that died
        // mid-classification — recover it to `.pending` instead of leaving it stuck forever.
        _ = try? store.resetOrphanedProcessing()
        // Housekeeping while we're the sole drainer: drop long-finished queue rows so the table
        // doesn't grow one row per session forever.
        _ = try? store.pruneFinishedCaptures()

        var total = 0
        var failures = 0
        var touchedProjects = Set<String>()
        let threshold = AppConfigStore.load().captureThreshold
        let pending = (try? store.pendingCaptures(limit: max(0, limit))) ?? []
        var processed = 0
        for stale in pending {
            defer {
                processed += 1
                progress?(processed, pending.count, total)
            }
            // Re-read fresh and atomically claim it: a concurrent capture hook may have updated this
            // row (new final slice) since the batch fetch. If we can't claim it as pending, skip.
            guard let item = (try? store.captureItem(id: stale.id)),
                  ((try? store.beginProcessing(id: item.id)) ?? false) else { continue }
            let attempts = item.attempts + 1   // beginProcessing incremented it

            let outcome = await ingestIncremental(
                transcript: URL(fileURLWithPath: item.transcriptPath),
                sessionId: item.sessionId, projectId: item.projectId,
                classifier: classifier, store: store, minNewEvents: threshold,
                isFinal: item.isFinal, commitSha: item.gitSha
            )

            switch outcome {
            case .captured(let count):
                // Only seal the session if our completion actually landed (the row was still
                // .processing — no concurrent re-enqueue of a newer final slice) and this was final.
                let landed = (try? store.finishProcessing(id: item.id, status: .done)) ?? false
                if landed && item.isFinal {
                    try? store.markProcessed(.init(
                        sessionId: item.sessionId, projectId: item.projectId, source: .live, memoryCount: count
                    ))
                }
                total += count
                if count > 0 { touchedProjects.insert(item.projectId) }
            case .waiting:
                let landed = (try? store.finishProcessing(id: item.id, status: .done)) ?? false
                // Nothing new to capture. If this was the *final* flush, the session is fully
                // captured — seal it so backfill / "Process previous sessions" don't rediscover and
                // re-classify it forever. A non-final Stop just waits for a later re-enqueue.
                if landed && item.isFinal {
                    try? store.markProcessed(.init(
                        sessionId: item.sessionId, projectId: item.projectId, source: .live, memoryCount: 0
                    ))
                }
            case .failed:
                failures += 1
                // Leave pending to retry next drain; give up after a few attempts so it can't loop forever.
                if attempts >= maxAttempts {
                    _ = try? store.finishProcessing(id: item.id, status: .error, lastError: "classification failed \(attempts)×")
                } else {
                    _ = try? store.finishProcessing(id: item.id, status: .pending)
                }
            }
        }
        // Re-triage the draft backlog through the auto-confirm policy (drafts predating the policy
        // settle on the first pass), then reconcile conflicts among the confirmed set — newly
        // confirmed memories may contradict older ones.
        let confirmConfident = AppConfigStore.load().autoConfirmConfidentCaptures
        for projectId in (try? store.projects()) ?? [] {
            if retriageDrafts(store: store, projectId: projectId, confirmConfident: confirmConfident) > 0 {
                touchedProjects.insert(projectId)
            }
        }
        for projectId in touchedProjects {
            ConflictEngine.sweep(store: store, projectId: projectId)
        }
        return DrainReport(added: total, failures: failures)
    }

    /// Re-triage existing drafts through the current auto-confirm policy — drafts that piled up
    /// before the policy existed (or while it was off) get the same treatment new captures do.
    /// Confirms capture-sourced drafts whose decayed confidence clears the floor; everything the
    /// gate exists for stays put: revisions (supersedesId set), MCP `remember` drafts (no
    /// conversationId), and weak/aged captures (under the floor). Idempotent — one pass settles
    /// the backlog, later passes find nothing.
    @discardableResult
    public static func retriageDrafts(store: MemoryStore, projectId: String, confirmConfident: Bool) -> Int {
        guard confirmConfident else { return 0 }
        let drafts = (try? store.nodes(projectId: projectId, status: .draft, limit: 2000)) ?? []
        var confirmed = 0
        for draft in drafts {
            guard draft.conversationId != nil,
                  draft.supersedesId == nil,
                  !draft.isSuperseded, !draft.isDeleted,
                  DecayEngine.decayed(draft).confidence >= confidentCaptureFloor else { continue }
            var node = draft
            node.status = .confirmed
            node.updatedAt = Date()
            guard (try? store.upsert(node)) != nil else { continue }
            confirmed += 1
        }
        return confirmed
    }

    /// Whether a fruitless first classification pass warrants one focused retry: only when it produced
    /// nothing usable AND something was plausibly missed — the raw pass had content that was all
    /// rejected, or the session edited code. Pure, for testability.
    static func shouldRetryExtraction(producedNothing: Bool, firstPassWasNonEmpty: Bool, editHeavy: Bool) -> Bool {
        producedNothing && (firstPassWasNonEmpty || editHeavy)
    }

    /// Run every classifier output through `CaptureValidator`:
    ///   - `.reject` → drop entirely.
    ///   - `.weak`   → keep, but cap confidence so the UI surfaces it for review.
    ///   - `.ok`     → pass through unchanged.
    static func validated(_ memories: [ClassifiedMemory]) -> [ClassifiedMemory] {
        memories.compactMap { m in
            switch CaptureValidator.assess(m) {
            case .ok:
                return m
            case .weak:
                // Rebuild with a capped confidence; all other fields are preserved unchanged.
                let capped = min(m.confidence, CaptureValidator.weakConfidenceCeiling)
                return ClassifiedMemory(
                    type: m.type, confidence: capped, title: m.title, summary: m.summary,
                    context: m.context, relatedFiles: m.relatedFiles, sourceQuote: m.sourceQuote
                )
            case .reject:
                return nil
            }
        }
    }

    /// Reconcile new candidate memories against the project: insert genuinely new ones; for
    /// duplicates of an existing memory, *reinforce* it instead (a repeated sighting revalidates it,
    /// and auto-confirms a draft once it's been seen `autoConfirmAfterSightings` times). Returns the
    /// fresh nodes to insert.
    /// Stored confidence at or above this auto-confirms a fresh capture (when enabled). Weak
    /// validator verdicts are capped well below it, and decay pulls old backfilled sessions under
    /// it — so only fresh, clean, high-confidence captures skip the draft gate.
    static let confidentCaptureFloor = 0.85

    static func reconcile(
        _ nodes: [MemoryNode], projectId: String, store: MemoryStore, autoConfirm: Int,
        confirmConfident: Bool = false
    ) -> [MemoryNode] {
        var pool = (try? store.nodes(projectId: projectId, limit: 500)) ?? []
        var fresh: [MemoryNode] = []
        for node in nodes {
            guard let dup = DedupEngine.duplicate(of: node, in: pool) else {
                // Genuinely new — but it may *contradict* an existing memory (a revised decision,
                // a fact whose value changed). Link the revision on the draft; the old memory is
                // only marked superseded when this draft is confirmed.
                var node = node
                if let conflicting = ConflictEngine.conflict(of: node, in: pool) {
                    // Revisions ALWAYS stay drafts: confirming one retires a memory a human
                    // (or an earlier auto-confirm) already accepted — that call needs a human.
                    node.supersedesId = conflicting.id
                } else if confirmConfident, node.status == .draft,
                          node.confidence >= Self.confidentCaptureFloor {
                    // Human-in-the-loop only as needed: a clean, fresh, high-confidence capture
                    // goes live immediately instead of waiting in the inbox.
                    node.status = .confirmed
                }
                fresh.append(node)
                pool.append(node)
                continue
            }
            guard var existing = try? store.node(id: dup.id) else { continue }
            existing.timesApplied += 1                 // legacy counter (auto-confirm + legacy decay)
            existing.timesSighted += 1                 // explicit: a repeat *sighting*, not an application
            existing.lastValidatedAt = Date()
            existing.updatedAt = Date()
            // Deliberately do NOT reset confidence — that would silently undo an audit penalty. A
            // repeat sighting auto-confirms a draft after `autoConfirm` reinforcements.
            if existing.status == .draft, autoConfirm > 0, existing.timesApplied >= autoConfirm {
                existing.status = .confirmed
            }
            try? store.upsert(existing)
            // Auto-confirm is a confirm path: a draft that carried a revision link now supersedes.
            ConflictEngine.applySupersede(for: existing, store: store)
            if let index = pool.firstIndex(where: { $0.id == existing.id }) { pool[index] = existing }
        }
        return fresh
    }
}
