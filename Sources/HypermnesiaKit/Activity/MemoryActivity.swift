import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A single append-only activity event emitted by Hypermnesia runtime paths (hooks, MCP, audit).
public struct MemoryActivityEvent: Codable, Sendable, Equatable, Identifiable {
    public enum EventType: String, Codable, Sendable, CaseIterable {
        case hydrate
        case recall
        case capture
        case applySuccess = "apply_success"
        case applyOverride = "apply_override"
        case revalidate
        case decayTransition = "decay_transition"
        case supersede
        case dream
    }

    public let id: String
    public let timestamp: Date
    public let projectId: String
    public let sessionId: String?
    public let eventType: EventType
    public let memoryIds: [String]
    public let count: Int?
    public let latencyMs: Int?
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        projectId: String,
        sessionId: String? = nil,
        eventType: EventType,
        memoryIds: [String] = [],
        count: Int? = nil,
        latencyMs: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.projectId = projectId
        self.sessionId = sessionId
        self.eventType = eventType
        self.memoryIds = memoryIds
        self.count = count
        self.latencyMs = latencyMs
        self.metadata = metadata
    }
}

/// Cross-process JSONL activity log used by the live MRI view.
public enum MemoryActivityLog {
    private static let filename = "activity-events.jsonl"
    private static let maxReadBytes = 1_000_000
    private static let maxFileBytes = 5_000_000
    private static let rotationRetainBytes = 1_000_000
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var decodedTailCache: DecodedTailCache?

    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    private struct DecodedTailCache {
        let signature: FileSignature
        let windowBytes: Int
        let events: [MemoryActivityEvent]
    }

    public static var fileURL: URL {
        StoreLocation.supportDirectory.appendingPathComponent(filename)
    }

    public static func append(_ event: MemoryActivityEvent) {
        let dir = StoreLocation.supportDirectory
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = fileURL.path
            let fd = open(path, O_CREAT | O_RDWR | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            // Best-effort telemetry with a bounded wait: a concurrent writer holds the lock only for
            // the microseconds an append (or rare rotation) takes, so a brief retry makes drops
            // effectively disappear without ever blocking a hot path for more than ~100ms. If the
            // lock is still held after the budget (pathological contention), drop the event.
            guard acquireLockBriefly(fd: fd) else { return }
            defer { flock(fd, LOCK_UN) }

            rotateIfNeeded(fd: fd, maxFileBytes: maxFileBytes, retainBytes: rotationRetainBytes)
            let line = try encode(event) + "\n"
            guard let data = line.data(using: .utf8) else { return }
            guard writeAll(fd: fd, data: data) else { return }
        } catch {
            return
        }
    }

    /// Try to take an exclusive flock without blocking; on contention, retry every 2ms for up to
    /// ~100ms total, then give up. Internal so tests can lock the contention behavior.
    static func acquireLockBriefly(fd: Int32, budget: TimeInterval = 0.1) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EINTR else { return false }
            guard Date() < deadline else { return false }
            usleep(2_000)
        }
    }

    /// Recent events in ascending timestamp order, optionally filtered by project.
    ///
    /// For a project filter this does an **adaptive backward scan**: it starts from the standard tail
    /// window and widens toward the start of the file until it has `limit` matching events or reaches
    /// BOF — so a quiet project isn't starved out of the shared log's tail by a noisy one. The file is
    /// rotation-bounded (`maxFileBytes`), so the widen terminates in a couple of steps.
    public static func recent(projectId: String? = nil, limit: Int = 400) -> [MemoryActivityEvent] {
        guard limit > 0 else { return [] }
        let url = fileURL
        guard let signature = fileSignature(url: url) else {
            cacheLock.lock()
            decodedTailCache = nil
            cacheLock.unlock()
            return []
        }
        let fileSize = Int(signature.size)

        guard let projectId else {
            let tail = ProjectVisibility.visible(
                decodedTail(url: url, signature: signature, windowBytes: maxReadBytes),
                projectId: \.projectId)
            return Array(tail.suffix(limit))
        }
        guard !ProjectVisibility.isHidden(projectId: projectId) else { return [] }

        var window = maxReadBytes
        var selected = projectMatches(
            decodedTail(url: url, signature: signature, windowBytes: window), projectId: projectId, limit: limit)
        while selected.count < limit, fileSize > window {
            window = min(fileSize, window * 4)
            selected = projectMatches(
                decodedTail(url: url, signature: signature, windowBytes: window), projectId: projectId, limit: limit)
        }
        return selected
    }

    /// The last `limit` events for a project, in ascending order (scans from the tail, stops early).
    private static func projectMatches(
        _ events: [MemoryActivityEvent], projectId: String, limit: Int
    ) -> [MemoryActivityEvent] {
        var selected: [MemoryActivityEvent] = []
        selected.reserveCapacity(limit)
        for event in events.reversed() where event.projectId == projectId {
            selected.append(event)
            if selected.count >= limit { break }
        }
        return selected.reversed()
    }

    private static func encode(_ event: MemoryActivityEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    private static func decode(_ line: String, decoder: JSONDecoder) -> MemoryActivityEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(MemoryActivityEvent.self, from: data)
    }

    /// Decode the last `windowBytes` of the log, cached by file signature + window. Reuses the cache
    /// whenever it already covers an equal-or-wider window for the same signature — so the adaptive
    /// widen never re-decodes, and a warm (wide) cache serves narrower requests for free.
    private static func decodedTail(
        url: URL, signature: FileSignature, windowBytes: Int
    ) -> [MemoryActivityEvent] {
        let effective = min(windowBytes, Int(signature.size))
        cacheLock.lock()
        if let cache = decodedTailCache, cache.signature == signature, cache.windowBytes >= effective {
            let events = cache.events
            cacheLock.unlock()
            return events
        }
        cacheLock.unlock()

        guard let data = tailData(url: url, maxBytes: effective),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [MemoryActivityEvent] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            guard let event = decode(String(line), decoder: decoder) else { continue }
            events.append(event)
        }
        cacheLock.lock()
        decodedTailCache = DecodedTailCache(signature: signature, windowBytes: effective, events: events)
        cacheLock.unlock()
        return events
    }

    private static func fileSignature(url: URL) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileSignature(size: size.uint64Value, modifiedAt: modifiedAt)
    }

    /// Truncate-in-place rotation, keeping the newest `retainBytes` aligned to a line boundary.
    /// Internal + parameterized so `SessionEventLog` shares the exact same discipline.
    static func rotateIfNeeded(fd: Int32, maxFileBytes: Int, retainBytes: Int) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let size = Int(info.st_size)
        guard size > maxFileBytes else { return }

        let keep = min(size, retainBytes)
        var retained = Data()
        if keep > 0 {
            retained = Data(count: keep)
            let offset = off_t(size - keep)
            let readBytes = retained.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                var bytesRead = 0
                while bytesRead < keep {
                    let n = pread(fd, base.advanced(by: bytesRead), keep - bytesRead, offset + off_t(bytesRead))
                    if n > 0 {
                        bytesRead += n
                    } else if n == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        return -1
                    }
                }
                return bytesRead
            }
            if readBytes <= 0 {
                retained.removeAll(keepingCapacity: false)
            } else if readBytes < keep {
                retained.removeSubrange(readBytes..<retained.count)
            }
            if offset > 0, let firstNL = retained.firstIndex(of: 0x0A) {
                retained = Data(retained.suffix(from: retained.index(after: firstNL)))
            }
        }

        guard ftruncate(fd, 0) == 0 else { return }
        if !retained.isEmpty {
            _ = lseek(fd, 0, SEEK_SET)
            _ = writeAll(fd: fd, data: retained)
        }
        cacheLock.lock()
        decodedTailCache = nil
        cacheLock.unlock()
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let n = write(fd, base.advanced(by: written), raw.count - written)
                if n > 0 {
                    written += n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func tailData(url: URL, maxBytes: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber else {
            return try? Data(contentsOf: url)
        }
        let size = fileSize.intValue
        if size <= maxBytes { return try? Data(contentsOf: url) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read one extra byte before the window so we can tell whether it begins exactly on a line
        // boundary. Dropping the first line unconditionally would discard a *complete* event whenever
        // the window happened to start right after a newline.
        let windowStart = size - maxBytes
        let readFrom = UInt64(max(0, windowStart - 1))
        do {
            try handle.seek(toOffset: readFrom)
            let data = (try handle.readToEnd()) ?? Data()
            guard windowStart > 0, let first = data.first else { return data }
            if first == 0x0A {
                // Window aligned on a boundary: drop only the leading newline, keep the whole line.
                return data.suffix(from: data.index(after: data.startIndex))
            }
            if let firstNL = data.firstIndex(of: 0x0A) {
                // Started mid-line: drop the partial first line.
                return data.suffix(from: data.index(after: firstNL))
            }
            return data
        } catch {
            return nil
        }
    }
}
