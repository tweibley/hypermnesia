import Foundation

/// Turns one session transcript into stored memories: classify → backdated draft nodes → persist,
/// recording the session as processed (idempotent). Shared by live capture (`drain`) and `backfill`.
public enum SessionIngestor {

    /// Result of an incremental ingest pass.
    public enum Outcome: Sendable, Equatable {
        case captured(Int)   // succeeded (cursor advanced); N memories created
        case waiting         // nothing new yet (cursor unchanged)
        /// Classifier/parse/persist error — cursor NOT advanced. `terminal` means retry cannot help
        /// (e.g. the transcript file is gone), so the queue should mark the row `.error` immediately.
        case failed(reason: String, terminal: Bool)
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
    ///
    /// Thin wrapper over `ingestSession` that flattens the outcome to a count for legacy callers.
    /// A `.failed` outcome collapses to `0` here, which cannot be told apart from a genuinely
    /// memory-less session — new callers should prefer `ingestSession` and report `.failed`.
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
        switch await ingestSession(
            transcript: transcript, sessionId: sessionId, projectId: projectId,
            classifier: classifier, store: store, source: source, status: status, commitSha: commitSha
        ) {
        case .captured(let count): return count
        case .waiting: return 0
        case .failed: return 0
        }
    }

    /// Ingest a whole session (used by backfill), returning a rich `Outcome` so callers can tell a
    /// genuinely memory-less session (`.captured(0)`) apart from a classifier / persistence / read
    /// failure (`.failed`) — mirroring `ingestIncremental`. Only *genuinely* undecodable input is
    /// sealed; transient (file-level) read errors stay retryable.
    public static func ingestSession(
        transcript: URL,
        sessionId: String,
        projectId: String,
        classifier: Classifier,
        store: MemoryStore,
        source: CaptureSource,
        status: MemoryStatus = .draft,
        commitSha: String? = nil
    ) async -> Outcome {
        guard !((try? store.isProcessed(sessionId: sessionId)) ?? false) else { return .captured(0) }

        // Respect a live-capture cursor: if hooks already classified events 0..cursor, only classify
        // the remaining slice so backfill doesn't re-extract (and re-dedup / spuriously re-confirm)
        // memories already captured live. A session with no cursor is backfilled whole, as before.
        let cursor = (try? store.cursor(sessionId: sessionId)) ?? 0
        let parsedEvents: [TranscriptEvent]
        do {
            parsedEvents = try TranscriptParser.parse(fileAt: transcript)
        } catch is TranscriptParseError {
            // Genuinely undecodable/unrecognized input (`.corrupt` / `.unrecognized`) will never grow
            // memories — seal it so consented backfill does not re-propose the same session forever.
            try? store.markProcessed(.init(
                sessionId: sessionId, projectId: projectId, source: source, memoryCount: 0
            ))
            return .captured(0)
        } catch {
            // A file-level error (missing / permission / IO / non-UTF8) is transient or externally
            // fixable — do NOT seal, or a re-run would never retry the session. Mirror
            // `ingestIncremental`: only a missing *managed* snapshot is terminal.
            if !FileManager.default.fileExists(atPath: transcript.path) {
                let terminal = TranscriptSnapshotStore.isManaged(transcript.path)
                return .failed(reason: "transcript missing", terminal: terminal)
            }
            return .failed(reason: "transcript unreadable", terminal: false)
        }
        let convo: Conversation?
        if cursor > 0 {
            guard parsedEvents.count > cursor else {
                // Already fully captured live — just seal it, don't reclassify anything.
                try? store.markProcessed(.init(sessionId: sessionId, projectId: projectId, source: source, memoryCount: 0))
                return .captured(0)
            }
            convo = ConversationBuilder.build(from: Array(parsedEvents[cursor...]), sessionId: sessionId)
        } else {
            convo = ConversationBuilder.build(from: parsedEvents, sessionId: sessionId)
        }
        guard let convo, !convo.isEmpty else {
            try? store.markProcessed(.init(sessionId: sessionId, projectId: projectId, source: source, memoryCount: 0))
            return .captured(0)
        }

        let recent = ((try? store.nodes(projectId: projectId, limit: 40)) ?? [])
            .map { RecentMemoryHint(type: $0.type, title: $0.title) }

        let rawMemories: [ClassifiedMemory]
        do {
            rawMemories = try await classifier.classify(convo, recentMemories: recent)
        } catch {
            // Don't seal a session that failed to classify — a re-run retries it. Surface the failure
            // so backfill can report it instead of an indistinguishable "0 memories".
            return .failed(reason: "classification failed", terminal: false)
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
        let nodes = normalizedRelatedFiles(memories.map { memory in
            DecayEngine.decayed(   // age confidence so old sessions land Aging/Stale/Dormant
                memory.toDraftNode(
                    projectId: projectId, sessionId: sessionId, createdAt: when,
                    commitSha: commitSha, branch: convo.gitBranch, status: status
                )
            )
        }, projectId: projectId, events: parsedEvents)
        // Deterministic codeRefs from the same event slice the classifier saw (cursor-respecting).
        // Runs even when classification produced nothing — edits are observed facts, not inferences.
        let eventSlice = cursor > 0 ? Array(parsedEvents[cursor...]) : parsedEvents
        let config = AppConfigStore.loadBestEffort()
        let codeRefs = codeRefNodes(
            from: eventSlice, projectId: projectId, sessionId: sessionId,
            createdAt: when, commitSha: commitSha, branch: convo.gitBranch, config: config
        )
        let fresh = reconcile(nodes + codeRefs, projectId: projectId, store: store,
                              autoConfirm: config.autoConfirmAfterSightings,
                              confirmConfident: config.autoConfirmConfidentCaptures,
                              observationAt: when)
        do {
            // Persist BEFORE sealing. If the write fails (locked DB, full disk), the session must
            // stay unprocessed so a re-run retries it — sealing anyway would silently discard the
            // classified memories forever.
            try store.upsert(fresh)
        } catch {
            // Report the failure (the LLM call was already paid for) so it isn't dropped silently.
            return .failed(reason: "persist failed", terminal: false)
        }
        // Advance the cursor to the full transcript so a later live/incremental drain sees nothing new.
        try? store.setCursor(sessionId: sessionId, projectId: projectId, count: parsedEvents.count)
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
        return .captured(fresh.count)
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
        commitSha: String? = nil,
        source: CaptureSource = .live
    ) async -> Outcome {
        let events: [TranscriptEvent]
        do {
            events = try TranscriptParser.parse(fileAt: transcript)
        } catch {
            if !FileManager.default.fileExists(atPath: transcript.path) {
                // Managed snapshots are durable; if one is gone, retrying won't help. A host path
                // that vanished mid-hook may reappear (or a later Stop may re-snapshot) — keep it
                // retryable.
                let terminal = TranscriptSnapshotStore.isManaged(transcript.path)
                return .failed(reason: "transcript missing", terminal: terminal)
            }
            return .failed(reason: "transcript unreadable", terminal: false)
        }
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
            // do NOT advance the cursor — these events will be retried
            return .failed(reason: "classification failed", terminal: false)
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
        let observationAt = source == .backfill ? when : Date()
        let nodes = normalizedRelatedFiles(memories.map {
            DecayEngine.decayed($0.toDraftNode(
                projectId: projectId, sessionId: sessionId, createdAt: when,
                commitSha: commitSha, branch: convo.gitBranch, status: .draft
            ))
        }, projectId: projectId, events: events)
        let config = AppConfigStore.loadBestEffort()
        let codeRefs = codeRefNodes(
            from: newEvents, projectId: projectId, sessionId: sessionId,
            createdAt: when, commitSha: commitSha, branch: convo.gitBranch, config: config
        )
        let fresh = reconcile(nodes + codeRefs, projectId: projectId, store: store,
                              autoConfirm: config.autoConfirmAfterSightings,
                              confirmConfident: config.autoConfirmConfidentCaptures,
                              observationAt: observationAt)
        do {
            // Persist BEFORE advancing the cursor: a failed write must leave the slice retryable
            // (.failed), not silently skipped. If the cursor write fails after a successful upsert,
            // the retry re-classifies the slice and reconcile reinforces the duplicates — wasteful
            // but lossless.
            try store.upsert(fresh)
            try store.setCursor(sessionId: sessionId, projectId: projectId, count: events.count)
        } catch {
            return .failed(reason: "persist failed", terminal: false)
        }
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
        return .captured(fresh.count)
    }

    /// What a drain pass accomplished — `failures` are sessions whose classification failed this
    /// pass (left pending/errored), so callers can report a truthful status instead of "up to date".
    public struct DrainReport: Sendable, Equatable {
        public let added: Int
        public let failures: Int
        /// How many of `failures` were classifier errors (vs missing/unreadable transcripts or
        /// persistence failures) — a "check your classifier settings" hint is only apt for these.
        public let classifierFailures: Int
        public static let idle = DrainReport(added: 0, failures: 0, classifierFailures: 0)
    }

    /// Drain the capture queue: classify each pending session (incrementally) into memories.
    /// Coordinated by an advisory file lock so the app and the CLI never drain at the same time —
    /// returns `.idle` immediately if another drainer holds the lock. `lockDirectory` is a test
    /// seam: tests must pass their own directory so a drain running on the real support dir
    /// (the installed app) can't turn their drain into a no-op.
    @discardableResult
    public static func drainQueue(
        store: MemoryStore,
        classifier: Classifier,
        limit: Int = 100,
        lockDirectory: URL = StoreLocation.supportDirectory,
        progress: (@Sendable (_ processed: Int, _ total: Int, _ addedSoFar: Int) -> Void)? = nil
    ) async -> DrainReport {
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockPath = lockDirectory.appendingPathComponent("drain.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; return .idle }
        defer { flock(fd, LOCK_UN); close(fd) }

        // We hold the drain lock, so any `.processing` row is orphaned from a drain that died
        // mid-classification — recover it to `.pending` instead of leaving it stuck forever.
        _ = try? store.resetOrphanedProcessing()
        // Housekeeping while we're the sole drainer: drop long-finished queue rows so the table
        // doesn't grow one row per session forever.
        _ = try? store.pruneFinishedCaptures()
        // Empty sessions (a window opened and closed with no prompt, so no transcript was ever
        // written) that slipped into the queue before the enqueue-time guard existed — or via an
        // older hook binary — end up as unfixable "transcript missing" errors. Sweep them so the
        // health banner only ever shows failures a user could act on.
        _ = try? store.sweepEmptySessionFailures()

        var total = 0
        var failures = 0
        var classifierFailures = 0
        var touchedProjects = Set<String>()
        let threshold = AppConfigStore.loadBestEffort().captureThreshold
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
                isFinal: item.isFinal, commitSha: item.gitSha, source: item.source
            )

            switch outcome {
            case .captured(let count):
                // Only seal the session if our completion actually landed (the row was still
                // .processing — no concurrent re-enqueue of a newer final slice) and this was final.
                let landed = (try? store.finishProcessing(id: item.id, status: .done)) ?? false
                if landed {
                    releaseManagedTranscriptIfSafe(item, store: store)
                }
                if landed && item.isFinal {
                    try? store.markProcessed(.init(
                        sessionId: item.sessionId, projectId: item.projectId, source: item.source, memoryCount: count
                    ))
                }
                total += count
                if count > 0 { touchedProjects.insert(item.projectId) }
            case .waiting:
                let landed = (try? store.finishProcessing(id: item.id, status: .done)) ?? false
                if landed {
                    releaseManagedTranscriptIfSafe(item, store: store)
                }
                // Nothing new to capture. If this was the *final* flush, the session is fully
                // captured — seal it so backfill / "Process previous sessions" don't rediscover and
                // re-classify it forever. A non-final Stop just waits for a later re-enqueue.
                if landed && item.isFinal {
                    try? store.markProcessed(.init(
                        sessionId: item.sessionId, projectId: item.projectId, source: item.source, memoryCount: 0
                    ))
                }
            case .failed(let reason, let terminal):
                failures += 1
                if reason == "classification failed" { classifierFailures += 1 }
                // Missing transcripts (and other terminal failures) won't recover on retry — mark
                // them error immediately. Transient classifier failures stay pending until the attempt
                // budget is exhausted.
                if terminal || attempts >= maxAttempts {
                    let message = terminal
                        ? reason
                        : "\(reason) \(attempts)×"
                    _ = try? store.finishProcessing(id: item.id, status: .error, lastError: message)
                } else {
                    _ = try? store.finishProcessing(
                        id: item.id, status: .pending,
                        lastError: "\(reason) (attempt \(attempts) of \(maxAttempts))")
                }
            }
        }
        // Re-triage the draft backlog through the auto-confirm policy (drafts predating the policy
        // settle on the first pass), then reconcile conflicts among the confirmed set — newly
        // confirmed memories may contradict older ones.
        let confirmConfident = AppConfigStore.loadBestEffort().autoConfirmConfidentCaptures
        for projectId in (try? store.allProjects()) ?? [] {
            if retriageDrafts(store: store, projectId: projectId, confirmConfident: confirmConfident) > 0 {
                touchedProjects.insert(projectId)
            }
        }
        for projectId in touchedProjects {
            ConflictEngine.sweep(store: store, projectId: projectId)
        }
        return DrainReport(added: total, failures: failures, classifierFailures: classifierFailures)
    }

    /// Drop a managed snapshot only when no other queue row still needs it, and only when a
    /// concurrent re-snapshot has not refreshed the file past this row's `enqueuedAt`.
    private static func releaseManagedTranscriptIfSafe(_ item: CaptureQueueItem, store: MemoryStore) {
        let shared = (try? store.isTranscriptPathReferenced(item.transcriptPath, excludingId: item.id)) ?? true
        guard !shared else { return }
        TranscriptSnapshotStore.removeIfManaged(item.transcriptPath, enqueuedAt: item.enqueuedAt)
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
        let drafts = (try? store.allNodes(projectId: projectId, status: .draft)) ?? []
        var confirmed = 0
        for draft in drafts {
            guard !draft.type.confirmsBySightingOnly,
                  draft.conversationId != nil,
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

    /// Deterministic codeRefs from edit tools in a transcript slice. Empty when the Capture
    /// setting (or its env override) is off.
    /// Always drafts — even `backfill --confirm` must not confirm a first-sight codeRef; they are
    /// elevated by sighting accrual (or a human) only.
    static func codeRefNodes(
        from events: [TranscriptEvent],
        projectId: String,
        sessionId: String?,
        createdAt: Date,
        commitSha: String?,
        branch: String?,
        config: AppConfig
    ) -> [MemoryNode] {
        guard CodeRefExtractor.isEnabled(config: config) else { return [] }
        return CodeRefExtractor.extract(
            from: events,
            projectId: projectId,
            sessionId: sessionId,
            createdAt: createdAt,
            commitSha: commitSha,
            branch: branch
        )
    }

    /// Classifier `relatedFiles` may arrive absolute (the model echoes tool paths verbatim);
    /// store them repo-relative — the contract codeRefs already follow — so graph grouping,
    /// dedup, and audit all key on one form instead of compensating downstream. Paths outside
    /// the repo root (or when no root resolves) are kept as-is rather than dropped.
    static func normalizedRelatedFiles(
        _ nodes: [MemoryNode], projectId: String, events: [TranscriptEvent]
    ) -> [MemoryNode] {
        guard let root = CodeRefExtractor.resolveRoot(projectRoot: nil, projectId: projectId, events: events)
        else { return nodes }
        return nodes.map { node in
            var node = node
            node.data = node.data.mappingRelatedFiles { path in
                guard path.hasPrefix("/") else { return path }
                return CodeRefExtractor.relativeIfInside(absolute: path, root: root) ?? path
            }
            return node
        }
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
        confirmConfident: Bool = false, observationAt: Date = Date()
    ) -> [MemoryNode] {
        var pools: [MemoryType: [MemoryNode]] = [:]
        for type in Set(nodes.map(\.type)) {
            // Exclude superseded (obsolete) nodes from the dedup/conflict pool. A superseded memory
            // is never surfaced by hydration, so absorbing a fresh sighting into it silently loses the
            // re-observed knowledge. Letting the candidate fall through lets ConflictEngine link it as
            // a revision of the *superseding* node — the correct home for a re-established rule.
            pools[type] = ((try? store.allNodes(projectId: projectId, type: type)) ?? [])
                .filter { !$0.isSuperseded }
        }
        var fresh: [MemoryNode] = []
        for node in nodes {
            var pool = pools[node.type] ?? []
            guard let dup = DedupEngine.duplicate(of: node, in: pool) else {
                // Genuinely new — but it may *contradict* an existing memory (a revised decision,
                // a fact whose value changed). Link the revision on the draft; the old memory is
                // only marked superseded when this draft is confirmed.
                var node = node
                if let conflicting = ConflictEngine.conflict(of: node, in: pool) {
                    // Revisions ALWAYS stay drafts: confirming one retires a memory a human
                    // (or an earlier auto-confirm) already accepted — that call needs a human.
                    node.supersedesId = conflicting.id
                } else if confirmConfident, !node.type.confirmsBySightingOnly, node.status == .draft,
                          node.confidence >= Self.confidentCaptureFloor {
                    // Human-in-the-loop only as needed: a clean, fresh, high-confidence capture
                    // goes live immediately instead of waiting in the inbox.
                    node.status = .confirmed
                }
                fresh.append(node)
                pool.append(node)
                pools[node.type] = pool
                continue
            }
            guard var existing = try? store.node(id: dup.id) else { continue }
            existing.timesApplied += 1                 // legacy counter (auto-confirm + legacy decay)
            existing.timesSighted += 1                 // explicit: a repeat *sighting*, not an application
            existing.lastValidatedAt = observationAt
            existing.updatedAt = observationAt
            // CodeRef re-sightings refresh provenance + latest snippet (still one node per path).
            if node.type == .codeRef {
                if let sha = node.commitSha { existing.commitSha = sha }
                if let branch = node.branch { existing.branch = branch }
                if case .codeRef(let incoming) = node.data,
                   case .codeRef(var stored) = existing.data,
                   let snippet = incoming.snippet, !snippet.isEmpty {
                    stored.snippet = snippet
                    existing.data = .codeRef(stored)
                }
            }
            // Deliberately do NOT reset confidence — that would silently undo an audit penalty. A
            // repeat sighting auto-confirms a draft after `autoConfirm` reinforcements.
            if existing.status == .draft, autoConfirm > 0, existing.timesApplied >= autoConfirm {
                existing.status = .confirmed
            }
            try? store.upsert(existing)
            // Auto-confirm is a confirm path: a draft that carried a revision link now supersedes.
            ConflictEngine.applySupersede(for: existing, store: store)
            if let index = pool.firstIndex(where: { $0.id == existing.id }) { pool[index] = existing }
            pools[node.type] = pool
        }
        return fresh
    }
}
