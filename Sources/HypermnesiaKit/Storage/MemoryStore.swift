import Foundation
import GRDB

/// The local, on-device memory database. Thread-safe; safe to open from both the CLI and the app
/// (WAL + busy timeout handle cross-process access). All methods are synchronous and throwing.
public final class MemoryStore: Sendable {
    let dbQueue: DatabaseQueue   // internal: same-module extensions (DreamStore) add table access

    public init(location: StoreLocation = .default) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        switch location.kind {
        case .file(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
            // The db holds transcript-derived content — keep it (and the WAL/SHM sidecars)
            // user-only, matching config.json's 0600, so protection doesn't depend on the
            // enclosing directory (HYPERMNESIA_SUPPORT_DIR can point anywhere).
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
            }
        case .inMemory:
            dbQueue = try DatabaseQueue(path: ":memory:", configuration: config)
        }

        try Schema.migrator.migrate(dbQueue)
    }

    /// Test-only: close the underlying connection so every subsequent read/write throws,
    /// letting tests exercise persist-failure paths deterministically.
    func closeForTesting() throws { try dbQueue.close() }

    // MARK: - Nodes

    /// Insert or update a node, keeping the search index in sync.
    public func upsert(_ node: MemoryNode) throws {
        try dbQueue.write { db in
            try node.save(db)
            try Self.reindex(node, in: db)
        }
    }

    /// Insert/update many nodes in one transaction.
    public func upsert(_ nodes: [MemoryNode]) throws {
        try dbQueue.write { db in
            for node in nodes {
                try node.save(db)
                try Self.reindex(node, in: db)
            }
        }
    }

    public func node(id: String) throws -> MemoryNode? {
        try dbQueue.read { db in try MemoryNode.fetchOne(db, key: id) }
    }

    /// Fetch nodes for a project with optional type/status filters, newest first.
    public func nodes(
        projectId: String,
        type: MemoryType? = nil,
        status: MemoryStatus? = nil,
        includeDeleted: Bool = false,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [MemoryNode] {
        try dbQueue.read { db in
            var request = MemoryNode.filter(Column("projectId") == projectId)
            if let type { request = request.filter(Column("type") == type) }
            if let status { request = request.filter(Column("status") == status) }
            if !includeDeleted { request = request.filter(Column("deletedAt") == nil) }
            return try request
                .order(Column("updatedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Fetch the complete matching corpus. Engine paths whose correctness depends on considering
    /// every candidate (hydration ranking, dedup, conflicts, audit, triage) must opt into this
    /// explicitly instead of inheriting the UI-oriented bounded `nodes` query.
    public func allNodes(
        projectId: String,
        type: MemoryType? = nil,
        status: MemoryStatus? = nil,
        includeDeleted: Bool = false
    ) throws -> [MemoryNode] {
        try dbQueue.read { db in
            var request = MemoryNode.filter(Column("projectId") == projectId)
            if let type { request = request.filter(Column("type") == type) }
            if let status { request = request.filter(Column("status") == status) }
            if !includeDeleted { request = request.filter(Column("deletedAt") == nil) }
            return try request.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    /// Soft-delete a node (sets `deletedAt`, removes it from search).
    public func softDeleteNode(id: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard var node = try MemoryNode.fetchOne(db, key: id) else { return }
            node.deletedAt = date
            node.updatedAt = date
            try node.update(db)
            try Self.reindex(node, in: db)
        }
    }

    public func hardDeleteNode(id: String) throws {
        _ = try dbQueue.write { db -> Bool in
            try db.execute(sql: "DELETE FROM memory_fts WHERE node_id = ?", arguments: [id])
            return try MemoryNode.deleteOne(db, key: id)
        }
    }

    /// Permanently removes every memory artifact for a project (nodes, search index, embeddings,
    /// edges, queue/progress state). Returns the number of memory nodes deleted.
    @discardableResult
    public func hardDeleteProject(projectId: String) throws -> Int {
        try dbQueue.write { db in
            let deleted = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_node WHERE projectId = ?",
                arguments: [projectId]
            ) ?? 0
            try db.execute(
                sql: "DELETE FROM memory_embedding WHERE nodeId IN (SELECT id FROM memory_node WHERE projectId = ?)",
                arguments: [projectId]
            )
            try db.execute(
                sql: "DELETE FROM memory_fts WHERE node_id IN (SELECT id FROM memory_node WHERE projectId = ?)",
                arguments: [projectId]
            )
            try db.execute(sql: "DELETE FROM memory_edge WHERE projectId = ?", arguments: [projectId])
            try db.execute(sql: "DELETE FROM capture_queue WHERE projectId = ?", arguments: [projectId])
            try db.execute(sql: "DELETE FROM session_progress WHERE projectId = ?", arguments: [projectId])
            try db.execute(sql: "DELETE FROM processed_session WHERE projectId = ?", arguments: [projectId])
            // The Dream Journal (v9) holds narratives/epiphanies/proposals synthesized from this
            // project's memories; it has no FK to memory_node, so it must be erased explicitly or it
            // survives the wipe and keeps rendering (and keeps latestDreamNight gating the loop).
            try db.execute(sql: "DELETE FROM dream_journal WHERE projectId = ?", arguments: [projectId])
            try db.execute(sql: "DELETE FROM memory_node WHERE projectId = ?", arguments: [projectId])
            return deleted
        }
    }

    /// Permanently removes all memories and related metadata across all projects. Returns the
    /// number of memory nodes deleted.
    @discardableResult
    public func hardDeleteAllMemories() throws -> Int {
        try dbQueue.write { db in
            let deleted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_node") ?? 0
            try db.execute(sql: "DELETE FROM memory_embedding")
            try db.execute(sql: "DELETE FROM memory_fts")
            try db.execute(sql: "DELETE FROM memory_edge")
            try db.execute(sql: "DELETE FROM capture_queue")
            try db.execute(sql: "DELETE FROM session_progress")
            try db.execute(sql: "DELETE FROM processed_session")
            // Erase the Dream Journal (v9) too — it holds narratives/epiphanies/proposals derived
            // from the memories being wiped and has no FK cascade, so it would otherwise survive the
            // "remove every memory" affordance and keep displaying private transcript-derived content.
            try db.execute(sql: "DELETE FROM dream_journal")
            try db.execute(sql: "DELETE FROM memory_node")
            return deleted
        }
    }

    /// Distinct project ids that have at least one (non-deleted) memory.
    public func projects() throws -> [String] {
        let all = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT projectId FROM memory_node WHERE deletedAt IS NULL ORDER BY projectId
                """)
        }
        return ProjectVisibility.visible(all) { $0 }
    }

    /// Count of non-deleted memories per type for a project.
    public func counts(projectId: String, status: MemoryStatus? = nil) throws -> [MemoryType: Int] {
        try dbQueue.read { db in
            var sql = "SELECT type, COUNT(*) FROM memory_node WHERE projectId = ? AND deletedAt IS NULL"
            var args: [DatabaseValueConvertible] = [projectId]
            if let status {
                sql += " AND status = ?"
                args.append(status.rawValue)
            }
            sql += " GROUP BY type"
            var result: [MemoryType: Int] = [:]
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            for row in rows {
                if let type = MemoryType(rawValue: row[0]) { result[type] = row[1] }
            }
            return result
        }
    }

    // MARK: - Edges

    public func edges(projectId: String) throws -> [MemoryEdge] {
        try dbQueue.read { db in
            try MemoryEdge.filter(Column("projectId") == projectId).fetchAll(db)
        }
    }

    public func upsert(_ edge: MemoryEdge) throws {
        try dbQueue.write { db in try edge.save(db) }
    }

    /// Replace all of a project's edges (used after re-inferring the graph).
    public func replaceEdges(projectId: String, with edges: [MemoryEdge]) throws {
        try dbQueue.write { db in
            try MemoryEdge.filter(Column("projectId") == projectId).deleteAll(db)
            for edge in edges { try edge.insert(db) }
        }
    }

    // MARK: - Capture queue

    public func enqueue(_ item: CaptureQueueItem) throws {
        try dbQueue.write { db in try item.save(db) }
    }

    public func pendingCaptures(limit: Int = 20) throws -> [CaptureQueueItem] {
        try dbQueue.read { db in
            try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.pending)
                .order(Column("enqueuedAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func captureQueueHealth() throws -> CaptureQueueHealth {
        try dbQueue.read { db in
            let pending = try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.pending.rawValue && Column("attempts") == 0)
                .fetchCount(db)
            let retrying = try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.pending.rawValue && Column("attempts") > 0)
                .fetchCount(db)
            let processing = try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.processing.rawValue)
                .fetchCount(db)
            let terminalErrors = try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.error.rawValue)
                .fetchCount(db)
            let last = try CaptureQueueItem
                .filter(Column("lastError") != nil)
                .order(Column("enqueuedAt").desc)
                .fetchOne(db)
            let failure = last.map {
                CaptureQueueFailure(
                    sessionId: $0.sessionId,
                    projectId: $0.projectId,
                    attempts: $0.attempts,
                    message: $0.lastError ?? "Unknown capture failure",
                    date: $0.enqueuedAt
                )
            }
            return CaptureQueueHealth(
                pending: pending,
                processing: processing,
                retrying: retrying,
                terminalErrors: terminalErrors,
                lastError: failure
            )
        }
    }

    public func updateCapture(_ item: CaptureQueueItem) throws {
        try dbQueue.write { db in try item.update(db) }
    }

    public func captureItem(id: String) throws -> CaptureQueueItem? {
        try dbQueue.read { db in try CaptureQueueItem.filter(Column("id") == id).fetchOne(db) }
    }

    /// Reset orphaned `.processing` rows back to `.pending`. Drains are serialized by an advisory
    /// lock, so any row still `.processing` when a new drain starts belongs to a drain that died
    /// mid-classification (crash, reboot, killed nohup) — otherwise it would never be retried.
    @discardableResult
    public func resetOrphanedProcessing() throws -> Int {
        try dbQueue.write { db in
            try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.processing.rawValue)
                .updateAll(db, Column("status").set(to: CaptureStatus.pending.rawValue))
        }
    }

    /// Atomically claim a pending row for draining (pending → processing, attempts += 1). Returns
    /// false if the row is no longer pending (already claimed, or re-enqueued by a concurrent hook).
    /// Scoped to the status column so it can't clobber a concurrent full-row write.
    @discardableResult
    public func beginProcessing(id: String) throws -> Bool {
        try dbQueue.write { db in
            try CaptureQueueItem
                .filter(Column("id") == id && Column("status") == CaptureStatus.pending.rawValue)
                .updateAll(db, Column("status").set(to: CaptureStatus.processing.rawValue), Column("attempts") += 1) > 0
        }
    }

    /// Move a row out of `.processing` to a terminal/retry status, but only if it is *still*
    /// `.processing` — so a re-enqueue that flipped it back to `.pending` mid-drain (a newer final
    /// slice) survives. Returns true if this write landed. Only the status/lastError columns are
    /// touched, so the re-enqueue's fresh transcriptPath/isFinal are never reverted.
    @discardableResult
    public func finishProcessing(id: String, status: CaptureStatus, lastError: String? = nil) throws -> Bool {
        try dbQueue.write { db in
            try CaptureQueueItem
                .filter(Column("id") == id && Column("status") == CaptureStatus.processing.rawValue)
                .updateAll(db, Column("status").set(to: status.rawValue), Column("lastError").set(to: lastError)) > 0
        }
    }

    /// Delete finished (done/error) capture-queue rows older than the retention window. Terminal
    /// rows are only useful for short-term inspection (`drain --dry-run`, doctor); without pruning
    /// they accumulate one per session forever. Pending/processing rows are never touched.
    /// Managed snapshots are removed only when no surviving queue row still points at them — a
    /// done row and a later live re-enqueue share `sha256(sessionId).jsonl`.
    @discardableResult
    public func pruneFinishedCaptures(
        olderThanDays days: Int = 30,
        now: Date = Date(),
        supportDirectory: URL = StoreLocation.supportDirectory
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let asOf = Date()   // a hook re-snapshotting after this point must not lose its file
        let (removedCount, orphanPaths) = try dbQueue.write { db -> (Int, [String]) in
            let rows = try CaptureQueueItem
                .filter([CaptureStatus.done.rawValue, CaptureStatus.error.rawValue].contains(Column("status")))
                .filter(Column("enqueuedAt") < cutoff)
                .fetchAll(db)
            let paths = rows.map(\.transcriptPath)
            _ = try CaptureQueueItem
                .filter(rows.map(\.id).contains(Column("id")))
                .deleteAll(db)
            return (rows.count, try Self.unreferencedTranscriptPaths(paths, db: db))
        }
        orphanPaths.forEach { TranscriptSnapshotStore.removeIfManaged($0, in: supportDirectory, enqueuedAt: asOf) }
        return removedCount
    }

    /// Remove terminal failures without touching memories, transcripts owned by agent clients, or
    /// active queue work. Managed transcript snapshots are deleted only when unreferenced.
    @discardableResult
    public func clearFailedCaptures(
        supportDirectory: URL = StoreLocation.supportDirectory
    ) throws -> Int {
        let asOf = Date()   // a hook re-snapshotting after this point must not lose its file
        let (removedCount, orphanPaths) = try dbQueue.write { db -> (Int, [String]) in
            let rows = try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.error.rawValue)
                .fetchAll(db)
            let paths = rows.map(\.transcriptPath)
            _ = try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.error.rawValue)
                .deleteAll(db)
            return (rows.count, try Self.unreferencedTranscriptPaths(paths, db: db))
        }
        orphanPaths.forEach { TranscriptSnapshotStore.removeIfManaged($0, in: supportDirectory, enqueuedAt: asOf) }
        return removedCount
    }

    /// Drop terminal "transcript missing" failures for sessions that never had anything to capture.
    /// A session whose transcript still doesn't exist on disk, whose live cursor never advanced, and
    /// whose queued path is not a managed snapshot (a snapshot proves a transcript once existed) is
    /// an *empty* session — a window opened and closed without a single prompt. There is nothing to
    /// recover, so leaving these as red "failed" rows only alarms the user. Runs as drain housekeeping.
    @discardableResult
    public func sweepEmptySessionFailures(
        supportDirectory: URL = StoreLocation.supportDirectory,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> Int {
        let candidates = try dbQueue.read { db in
            try CaptureQueueItem
                .filter(Column("status") == CaptureStatus.error.rawValue)
                .filter(Column("lastError").like("transcript missing%"))
                .fetchAll(db)
        }
        var empty: [String] = []
        for item in candidates {
            guard !TranscriptSnapshotStore.isManaged(item.transcriptPath, in: supportDirectory),
                  !fileExists(item.transcriptPath),
                  try cursor(sessionId: item.sessionId) == 0 else { continue }
            empty.append(item.id)
        }
        guard !empty.isEmpty else { return 0 }
        return try dbQueue.write { db in
            try CaptureQueueItem.filter(empty.contains(Column("id"))).deleteAll(db)
        }
    }

    /// True when another queue row (not `excludingId`) still points at `path` — used before
    /// deleting a managed snapshot after a drain completes.
    public func isTranscriptPathReferenced(_ path: String, excludingId: String) throws -> Bool {
        try dbQueue.read { db in
            try CaptureQueueItem
                .filter(Column("transcriptPath") == path)
                .filter(Column("id") != excludingId)
                .fetchCount(db) > 0
        }
    }

    /// Among `paths`, those no longer referenced by any remaining capture_queue row.
    private static func unreferencedTranscriptPaths(_ paths: [String], db: Database) throws -> [String] {
        let unique = Array(Set(paths))
        guard !unique.isEmpty else { return [] }
        let stillHeld = Set(
            try CaptureQueueItem
                .filter(unique.contains(Column("transcriptPath")))
                .fetchAll(db)
                .map(\.transcriptPath)
        )
        return unique.filter { !stillHeld.contains($0) }
    }

    /// Enqueue a session, or refresh the existing not-done item for it (one active item per session).
    /// A fresh enqueue resets the retry budget — a new Stop/SessionEnd (or confirmed backfill) is
    /// new work, not another attempt at a prior failure.
    public func enqueueOrUpdate(
        sessionId: String, projectId: String, transcriptPath: String, cwd: String,
        gitSha: String?, gitBranch: String?, isFinal: Bool, source: CaptureSource = .live
    ) throws {
        try dbQueue.write { db in
            if var existing = try CaptureQueueItem
                .filter(Column("sessionId") == sessionId)
                .filter(Column("status") != CaptureStatus.done)
                .order(Column("enqueuedAt").desc)
                .fetchOne(db) {
                existing.enqueuedAt = Date()
                existing.status = .pending
                existing.attempts = 0
                existing.lastError = nil
                existing.transcriptPath = transcriptPath
                if isFinal { existing.isFinal = true }
                existing.source = source
                try existing.update(db)
            } else {
                try CaptureQueueItem(
                    sessionId: sessionId, projectId: projectId, transcriptPath: transcriptPath,
                    cwd: cwd, gitSha: gitSha, gitBranch: gitBranch, isFinal: isFinal, source: source
                ).insert(db)
            }
        }
    }

    // MARK: - Session cursor (incremental capture)

    /// How many transcript events have already been captured for this session.
    public func cursor(sessionId: String) throws -> Int {
        try dbQueue.read { db in try SessionProgress.fetchOne(db, key: sessionId)?.eventCursor ?? 0 }
    }

    public func setCursor(sessionId: String, projectId: String, count: Int) throws {
        try dbQueue.write { db in
            try SessionProgress(sessionId: sessionId, projectId: projectId, eventCursor: count).save(db)
        }
    }

    // MARK: - Processed sessions

    public func isProcessed(sessionId: String) throws -> Bool {
        try dbQueue.read { db in
            try ProcessedSession.filter(key: sessionId).fetchCount(db) > 0
        }
    }

    public func markProcessed(_ session: ProcessedSession) throws {
        try dbQueue.write { db in try session.save(db) }
    }

    // MARK: - Search

    /// Full-text search over a project's memories, ranked by relevance.
    public func search(projectId: String, query: String, limit: Int = 20) throws -> [MemoryNode] {
        let rawTokens = query
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !rawTokens.isEmpty else { return [] }
        // Drop stopwords so a natural-language recall query ("how should I handle auth tokens")
        // isn't dominated by filler; keep them only if the query is nothing but stopwords.
        let meaningful = rawTokens.filter { !DedupEngine.stopwords.contains($0.lowercased()) }
        let used = meaningful.isEmpty ? rawTokens : meaningful
        // OR semantics, NOT FTS5's implicit AND: a sentence-shaped query must not require every
        // token to appear in one memory (that fails closed — see MemoryHydrator's keyword fallback).
        // FTS5 `rank` (bm25, ORDER BY below) still floats rows matching more/rarer terms to the top,
        // so the best hits lead.
        let match = used
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")

        return try dbQueue.read { db in
            // Scope the MATCH to this project *inside* the query (join memory_node), so the LIMIT
            // caps this project's own top-ranked hits. Selecting globally and filtering by projectId
            // afterward let a busy project fill the candidate pool and starve another project's
            // matches — returning 0 results for a project whose memories genuinely match.
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT memory_fts.node_id
                    FROM memory_fts
                    JOIN memory_node n ON n.id = memory_fts.node_id
                    WHERE memory_fts MATCH ? AND n.projectId = ? AND n.deletedAt IS NULL
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [match, projectId, limit * 4]
            )
            guard !ids.isEmpty else { return [] }
            let nodes = try MemoryNode.filter(ids.contains(Column("id"))).fetchAll(db)
            let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return ids.compactMap { byId[$0] }.prefix(limit).map { $0 }
        }
    }

    // MARK: - Embeddings

    /// Store (or replace) the vector embedding for a node.
    public func setEmbedding(nodeId: String, model: String, vector: [Float]) throws {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO memory_embedding (nodeId, model, dims, vector, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(nodeId) DO UPDATE SET
                    model = excluded.model, dims = excluded.dims,
                    vector = excluded.vector, updatedAt = excluded.updatedAt
                """, arguments: [nodeId, model, vector.count, blob, Date()])
        }
    }

    /// Remove a node's embedding (e.g. after its text was edited) so it gets re-indexed.
    public func clearEmbedding(nodeId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_embedding WHERE nodeId = ?", arguments: [nodeId])
        }
    }

    /// Embeddings for the given node ids (`id` → vector).
    public func embeddings(for ids: [String]) throws -> [String: [Float]] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT nodeId, vector FROM memory_embedding WHERE nodeId IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(ids)
            )
            var result: [String: [Float]] = [:]
            for row in rows {
                let id: String = row["nodeId"]
                let data: Data = row["vector"]
                let count = data.count / MemoryLayout<Float>.stride
                var vector = [Float](repeating: 0, count: count)
                _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }  // alignment-safe
                result[id] = vector
            }
            return result
        }
    }

    /// Non-deleted nodes (optionally of one status) lacking an embedding for `model` — for indexing.
    public func nodesMissingEmbedding(
        projectId: String, model: String, status: MemoryStatus? = nil, limit: Int = 1000
    ) throws -> [MemoryNode] {
        try dbQueue.read { db in
            // Push the "missing an embedding for this model" predicate into SQL (NOT EXISTS) and
            // apply the LIMIT *after* it. Fetching `limit` nodes first and filtering embedded ones out
            // afterward returned "up to limit nodes minus the embedded ones", so once a project
            // exceeded the cap the un-embedded tail was never returned and stayed unsearchable.
            var sql = """
                SELECT n.* FROM memory_node n
                WHERE n.projectId = ? AND n.deletedAt IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_embedding e WHERE e.nodeId = n.id AND e.model = ?
                  )
                """
            var args: [any DatabaseValueConvertible] = [projectId, model]
            if let status {
                sql += " AND n.status = ?"
                args.append(status.rawValue)
            }
            sql += " LIMIT ?"
            args.append(limit)
            return try MemoryNode.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Complete counterpart used before correctness-critical semantic ranking.
    public func allNodesMissingEmbedding(
        projectId: String, model: String, status: MemoryStatus? = nil
    ) throws -> [MemoryNode] {
        try dbQueue.read { db in
            var sql = """
                SELECT n.* FROM memory_node n
                WHERE n.projectId = ? AND n.deletedAt IS NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM memory_embedding e WHERE e.nodeId = n.id AND e.model = ?
                  )
                """
            var args: [any DatabaseValueConvertible] = [projectId, model]
            if let status {
                sql += " AND n.status = ?"
                args.append(status.rawValue)
            }
            return try MemoryNode.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - FTS sync

    private static func reindex(_ node: MemoryNode, in db: Database) throws {
        try db.execute(sql: "DELETE FROM memory_fts WHERE node_id = ?", arguments: [node.id])
        guard node.deletedAt == nil else { return }
        try db.execute(
            sql: "INSERT INTO memory_fts (node_id, title, summary, body) VALUES (?, ?, ?, ?)",
            arguments: [node.id, node.title, node.summary, searchBody(of: node)]
        )
    }

    /// Flatten a node's payload into searchable text so content (rules, facts, files) is indexed.
    private static func searchBody(of node: MemoryNode) -> String {
        var parts: [String] = []
        switch node.data {
        case .decision(let d):
            parts += [d.problem, d.chosen, d.rationale].compactMap { $0 }
            parts += d.alternatives + d.revisitTriggers
        case .convention(let c):
            parts += [c.trigger, c.rule].compactMap { $0 }
            parts += c.examples.flatMap { [$0.good, $0.bad].compactMap { $0 } }
        case .intent(let i):
            parts.append(i.goal)
            parts += i.constraints
            parts += i.behaviors.flatMap { [$0.given, $0.when, $0.then].compactMap { $0 } }
        case .fact(let f):
            parts += [f.category, f.key, f.value]
        case .concern(let c):
            parts += [c.issue, c.severity, c.affectedArea].compactMap { $0 }
        case .backlog(let b):
            parts += [b.idea, b.priority, b.trigger].compactMap { $0 }
        case .codeRef(let r):
            parts += [r.filePath, r.symbolName, r.snippet].compactMap { $0 }
        }
        parts += node.data.relatedFiles
        return parts.joined(separator: " ")
    }
}
