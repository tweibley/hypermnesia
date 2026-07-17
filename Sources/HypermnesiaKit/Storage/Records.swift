import Foundation
import GRDB

// MARK: - Enum column conformances
// These let GRDB store the enums as clean string columns (e.g. `WHERE type = 'convention'`)
// rather than JSON. The default implementation comes from GRDB's RawRepresentable extension.

extension MemoryType: DatabaseValueConvertible {}
extension MemoryStatus: DatabaseValueConvertible {}
extension MemoryEdgeType: DatabaseValueConvertible {}
extension CaptureStatus: DatabaseValueConvertible {}

// MARK: - Record conformances
// MemoryNode/MemoryEdge are Codable, so GRDB synthesizes row coding. Nested non-scalar values
// (`data: MemoryData`, `properties: [String:String]`) are stored as JSON text columns.

extension MemoryNode: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "memory_node"
}

extension MemoryEdge: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "memory_edge"
}

// MARK: - Capture queue

/// Lifecycle of a queued capture.
public enum CaptureStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case pending
    case processing
    case done
    case error
}

/// A session handed off by a hook, awaiting out-of-band classification.
public struct CaptureQueueItem: Codable, Identifiable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "capture_queue"

    public var id: String
    /// Claude Code `session_id`.
    public var sessionId: String
    public var projectId: String
    public var transcriptPath: String
    public var cwd: String
    public var gitSha: String?
    public var gitBranch: String?
    public var enqueuedAt: Date
    public var status: CaptureStatus
    public var attempts: Int
    public var lastError: String?
    /// True once the session has ended — drain flushes the remaining slice regardless of threshold.
    public var isFinal: Bool

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        projectId: String,
        transcriptPath: String,
        cwd: String,
        gitSha: String? = nil,
        gitBranch: String? = nil,
        enqueuedAt: Date = Date(),
        status: CaptureStatus = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        isFinal: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.projectId = projectId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.gitSha = gitSha
        self.gitBranch = gitBranch
        self.enqueuedAt = enqueuedAt
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.isFinal = isFinal
    }
}

/// Per-session capture cursor — how many transcript events have already been turned into memories.
public struct SessionProgress: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session_progress"
    public var sessionId: String
    public var projectId: String
    public var eventCursor: Int
    public var updatedAt: Date

    public init(sessionId: String, projectId: String, eventCursor: Int, updatedAt: Date = Date()) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.eventCursor = eventCursor
        self.updatedAt = updatedAt
    }
}

// MARK: - Processed sessions (idempotency for live + backfill)

/// How a session's memories entered the store.
public enum CaptureSource: String, Codable, Sendable, CaseIterable, Hashable {
    case live
    case backfill
}

extension CaptureSource: DatabaseValueConvertible {}

/// A record that a given session has already been turned into memories.
public struct ProcessedSession: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "processed_session"

    /// Claude Code `session_id` (primary key).
    public var sessionId: String
    public var projectId: String
    public var processedAt: Date
    public var source: CaptureSource
    public var memoryCount: Int

    public init(
        sessionId: String,
        projectId: String,
        processedAt: Date = Date(),
        source: CaptureSource,
        memoryCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.processedAt = processedAt
        self.source = source
        self.memoryCount = memoryCount
    }
}
