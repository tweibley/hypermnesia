import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("MemoryActivityLog")
struct MemoryActivityTests {

    private func openTempFile() throws -> (fd1: Int32, fd2: Int32, path: String) {
        let path = NSTemporaryDirectory() + "activity-lock-test-\(UUID().uuidString)"
        let fd1 = open(path, O_CREAT | O_RDWR, 0o600)
        let fd2 = open(path, O_RDWR)
        try #require(fd1 >= 0 && fd2 >= 0)
        return (fd1, fd2, path)
    }

    @Test("acquireLockBriefly waits out a short-lived contending writer instead of dropping")
    func retryOutlivesBriefContention() throws {
        let (fd1, fd2, path) = try openTempFile()
        defer { close(fd1); close(fd2); unlink(path) }

        // Simulate another process mid-append: hold the lock briefly, then release. The old
        // LOCK_NB-only behavior returned false here (a silently dropped event). A dedicated thread
        // and a generous budget keep this deterministic under a heavily parallel test run.
        #expect(flock(fd1, LOCK_EX | LOCK_NB) == 0)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.03)
            flock(fd1, LOCK_UN)
        }
        #expect(MemoryActivityLog.acquireLockBriefly(fd: fd2, budget: 5.0))
        flock(fd2, LOCK_UN)
    }

    @Test("acquireLockBriefly gives up within its budget when the lock is held pathologically long")
    func retryIsBounded() throws {
        let (fd1, fd2, path) = try openTempFile()
        defer { close(fd1); close(fd2); unlink(path) }

        #expect(flock(fd1, LOCK_EX | LOCK_NB) == 0)   // held for the whole test — never released
        let start = Date()
        let acquired = MemoryActivityLog.acquireLockBriefly(fd: fd2, budget: 0.1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!acquired)
        #expect(elapsed < 1.0)   // bounded: gave up near the 100ms budget, didn't block the hot path
    }
}
