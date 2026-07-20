import Foundation
import GRDB

/// Dream-journal persistence + the cheap activity queries the scheduler's pre-gate needs.
extension MemoryStore {

    // MARK: - Journal CRUD

    /// Insert or replace an entry. `(projectId, night)` is unique — when an entry for that night
    /// already exists under a different id (a manual re-dream), the old row is replaced so the
    /// strip never shows two results for one night.
    public func upsertDreamEntry(_ entry: DreamJournalEntry) throws {
        try dbQueue.write { db in
            try DreamJournalEntry
                .filter(Column("projectId") == entry.projectId)
                .filter(Column("night") == entry.night)
                .filter(Column("id") != entry.id)
                .deleteAll(db)
            try entry.save(db)
        }
    }

    public func dreamEntry(id: String) throws -> DreamJournalEntry? {
        try dbQueue.read { db in try DreamJournalEntry.fetchOne(db, key: id) }
    }

    public func dreamEntry(projectId: String, night: String) throws -> DreamJournalEntry? {
        try dbQueue.read { db in
            try DreamJournalEntry
                .filter(Column("projectId") == projectId)
                .filter(Column("night") == night)
                .fetchOne(db)
        }
    }

    /// Newest first; `projectId: nil` spans all projects (digest + journal home).
    public func dreamEntries(projectId: String? = nil, limit: Int = 60) throws -> [DreamJournalEntry] {
        let entries = try dbQueue.read { db in
            var request = DreamJournalEntry.order(Column("createdAt").desc).limit(limit)
            if let projectId { request = request.filter(Column("projectId") == projectId) }
            return try request.fetchAll(db)
        }
        return ProjectVisibility.visible(entries, projectId: \.projectId)
    }

    /// The most recent night this project's dream loop RAN (dreamed or quiet) — the calendar-day
    /// due gate compares it to tonight.
    public func latestDreamNight(projectId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT night FROM dream_journal WHERE projectId = ? ORDER BY night DESC LIMIT 1",
                arguments: [projectId])
        }
    }

    public func unreadDreamEntries() throws -> [DreamJournalEntry] {
        let entries = try dbQueue.read { db in
            try DreamJournalEntry
                .filter(Column("unread") == true)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
        return ProjectVisibility.visible(entries, projectId: \.projectId)
    }

    public func markDreamRead(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE dream_journal SET unread = 0 WHERE id = ?", arguments: [id])
        }
    }

    public func markAllDreamsRead() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE dream_journal SET unread = 0")
        }
    }

    /// Every dream-entry id for a project — dream-sourced memories carry the entry id in
    /// `conversationId`, so this set identifies them for report-backs.
    public func dreamEntryIds(projectId: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT id FROM dream_journal WHERE projectId = ?",
                arguments: [projectId]))
        }
    }

    // MARK: - Pre-gate activity queries

    /// Sealed sessions for a project since `since` (the "did anything happen here" half of the
    /// pre-gate, checked before any model call).
    public func processedSessionCount(projectId: String, since: Date) throws -> Int {
        try dbQueue.read { db in
            try ProcessedSession
                .filter(Column("projectId") == projectId)
                .filter(Column("processedAt") >= since)
                .fetchCount(db)
        }
    }

    /// Non-deleted memories touched since `since` — the "meaningful memory churn" half.
    public func memoriesUpdatedCount(projectId: String, since: Date) throws -> Int {
        try dbQueue.read { db in
            try MemoryNode
                .filter(Column("projectId") == projectId)
                .filter(Column("deletedAt") == nil)
                .filter(Column("updatedAt") >= since)
                .fetchCount(db)
        }
    }

    /// Most recent seal time per project — orders the nightly pass most-recently-active first, so
    /// the call cap spends its budget where the user actually works.
    public func latestProcessedAt(projectId: String) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT MAX(processedAt) FROM processed_session WHERE projectId = ?",
                arguments: [projectId])
        }
    }
}
