import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Transcript snapshots")
struct TranscriptSnapshotStoreTests {
    @Test("snapshot survives source deletion and refreshes atomically")
    func durableSnapshot() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = support.appendingPathComponent("source.jsonl")
        try "first\n".write(to: source, atomically: true, encoding: .utf8)

        let first = try TranscriptSnapshotStore.snapshot(
            transcript: source, sessionId: "session/with unsafe characters", in: support)
        #expect(TranscriptSnapshotStore.isManaged(first.path, in: support))
        try FileManager.default.removeItem(at: source)
        #expect(try String(contentsOf: first, encoding: .utf8) == "first\n")

        try "second\n".write(to: source, atomically: true, encoding: .utf8)
        let second = try TranscriptSnapshotStore.snapshot(
            transcript: source, sessionId: "session/with unsafe characters", in: support)
        #expect(second == first)
        #expect(try String(contentsOf: second, encoding: .utf8) == "second\n")

        TranscriptSnapshotStore.removeIfManaged(second.path, in: support)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("cleanup never removes a host-owned transcript")
    func preservesSourceTranscript() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = support.appendingPathComponent("host-owned.jsonl")
        try "data".write(to: source, atomically: true, encoding: .utf8)

        TranscriptSnapshotStore.removeIfManaged(source.path, in: support)

        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
