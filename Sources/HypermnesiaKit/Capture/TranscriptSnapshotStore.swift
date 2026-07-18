import CryptoKit
import Darwin
import Foundation

/// Durable, private copies of hook transcripts. Host applications may remove their transcript as
/// soon as a stop hook returns, so queued work must never depend on the host-owned path remaining.
public enum TranscriptSnapshotStore {
    public static func directory(in supportDirectory: URL = StoreLocation.supportDirectory) -> URL {
        supportDirectory.appendingPathComponent("capture-transcripts", isDirectory: true)
    }

    public static func snapshot(
        transcript: URL,
        sessionId: String,
        in supportDirectory: URL = StoreLocation.supportDirectory
    ) throws -> URL {
        let snapshots = directory(in: supportDirectory)
        try FileManager.default.createDirectory(
            at: snapshots,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let digest = SHA256.hash(data: Data(sessionId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = snapshots.appendingPathComponent("\(digest).jsonl")
        let temporary = snapshots.appendingPathComponent(".\(UUID().uuidString).tmp")

        do {
            try FileManager.default.copyItem(at: transcript, to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            guard rename(temporary.path, destination.path) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [NSFilePathErrorKey: destination.path,
                               NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func isManaged(
        _ path: String,
        in supportDirectory: URL = StoreLocation.supportDirectory
    ) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = directory(in: supportDirectory).standardizedFileURL.path + "/"
        if standardized.hasPrefix(root) { return true }
        // Snapshots created against a non-default support root (tests) still use the
        // …/capture-transcripts/<digest>.jsonl layout — treat those as managed too so drain
        // can mark a missing snapshot terminal without requiring the live support directory.
        guard let range = standardized.range(of: "/capture-transcripts/") else { return false }
        let rest = standardized[range.upperBound...]
        return !rest.contains("/") && rest.hasSuffix(".jsonl")
    }

    /// Delete a managed snapshot when nothing else needs it. Skips host-owned paths. When
    /// `enqueuedAt` is supplied, also skips if the file's mtime is newer — a concurrent re-capture
    /// refreshed the same sessionId digest after this row was claimed.
    public static func removeIfManaged(
        _ path: String,
        in supportDirectory: URL = StoreLocation.supportDirectory,
        enqueuedAt: Date? = nil
    ) {
        guard isManaged(path, in: supportDirectory) else { return }
        if let enqueuedAt,
           let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date,
           mtime > enqueuedAt {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}
