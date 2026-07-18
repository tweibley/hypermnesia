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
        let root = directory(in: supportDirectory).standardizedFileURL.path + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root)
    }

    public static func removeIfManaged(
        _ path: String,
        in supportDirectory: URL = StoreLocation.supportDirectory
    ) {
        guard isManaged(path, in: supportDirectory) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
