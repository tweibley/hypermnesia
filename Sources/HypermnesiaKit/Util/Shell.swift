import Foundation

/// Minimal synchronous subprocess runner. Used for `git` lookups and (later) the `claude -p`
/// classifier adapter.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }
    }

    /// Ignore SIGPIPE process-wide, once. Without this, writing the stdin payload to a child that
    /// has already exited (e.g. `claude` missing → env exits 127, or an arg/auth error, or our own
    /// watchdog kill) delivers SIGPIPE and terminates the *host* process — the `drain` CLI or the
    /// menu-bar app. With it ignored, the write fails with EPIPE, which the throwing `write` swallows.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Run `executable` with `arguments`. Looks the executable up on `PATH` when given a bare name.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) -> Result {
        _ = ignoreSIGPIPE
        let process = Process()

        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            // Resolve via /usr/bin/env so PATH is honored.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }

        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)")
        }

        // LIVENESS INVARIANT — every helper below runs on a DIRECTLY DETACHED pthread
        // (`Thread.detachNewThread`), never on a dispatch queue. Shell.run blocks its calling
        // thread until the helpers finish; callers include Swift Concurrency cooperative-pool
        // threads (swift-testing runs test bodies there). On a small machine the blocked callers
        // can occupy the ENTIRE thread pool, and dispatch then never grants threads to queued
        // work items — so helpers queued via DispatchQueue.global() never run and Shell.run waits
        // forever. That exact deadlock froze all 229 tests on a 3-vCPU CI runner (sampled stacks:
        // three cooperative threads in group.wait, zero drainer threads in existence). Detached
        // pthreads are created by the kernel unconditionally, so the helpers always make progress
        // regardless of pool pressure.

        // Watchdog: escalate SIGTERM → SIGKILL if the process outlives the timeout, so a child
        // that ignores SIGTERM can't hold us past the deadline. `firedBox` records that *our*
        // watchdog killed it (not some unrelated signal). Cancellation after exit is prompt
        // (100ms slices), so we never signal a reused pid (capture only the Sendable pid).
        let firedBox = FlagBox()
        let watchdogCancelled = FlagBox()
        if let timeout {
            let pid = process.processIdentifier
            Thread.detachNewThread {
                let termAt = Date().addingTimeInterval(timeout)
                let killAt = termAt.addingTimeInterval(5)
                var terminated = false
                while !watchdogCancelled.value {
                    let now = Date()
                    if !terminated, now >= termAt {
                        firedBox.set()
                        kill(pid, SIGTERM)
                        terminated = true
                    }
                    if now >= killAt {
                        kill(pid, SIGKILL)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }

        // Read stdout+stderr and write stdin on dedicated threads so a child that fills any pipe
        // buffer can't deadlock against us. SIGPIPE is ignored process-wide, so a write to a child
        // that already closed its stdin surfaces as a thrown EPIPE here rather than a crash.
        //
        // The readers are non-blocking + poll-based rather than `readDataToEndOfFile()`: a detached
        // grandchild can keep the write end open after the direct child dies, so an EOF may never
        // come. Once the child exits we set a grace deadline, after which the readers stop even
        // without EOF — so a reader thread is never stranded (which would accumulate blocked threads
        // in the long-lived app/CLI over repeated occurrences).
        let outBox = DataBox(), errBox = DataBox()
        let deadline = DeadlineBox()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            Self.drainPipe(outPipe.fileHandleForReading, into: outBox, deadline: deadline)
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            Self.drainPipe(errPipe.fileHandleForReading, into: errBox, deadline: deadline)
            group.leave()
        }
        if let stdin, let data = stdin.data(using: .utf8) {
            Thread.detachNewThread {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        process.waitUntilExit()   // returns when the direct child dies (guaranteed by the watchdog)
        watchdogCancelled.set()
        // Child is dead: give the readers a short grace to drain buffered output, then they stop even
        // if a detached grandchild is still holding a pipe open. group.wait() is now bounded because
        // the readers always terminate once the deadline passes.
        deadline.set(.now() + 3)
        group.wait()
        let outData = outBox.value
        let errData = errBox.value
        // Both readers are done: close the read ends explicitly rather than waiting for the Pipe
        // objects to deallocate. This releases the fds deterministically and delivers EPIPE/SIGPIPE
        // to any detached grandchild still writing, so orphan writers die instead of lingering.
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        let timedOut = firedBox.value
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: timedOut
                ? "timed out after \(Int(timeout ?? 0))s\n" + String(decoding: errData, as: UTF8.self)
                : String(decoding: errData, as: UTF8.self)
        )
    }

    /// Drain a pipe's read end into `box`. Sets the fd non-blocking and polls, so it stops at EOF —
    /// or shortly after `deadline` is set (the direct child has exited) if a detached grandchild is
    /// still holding the write end. Never blocks indefinitely, so the reader thread can't be stranded.
    private static func drainPipe(_ handle: FileHandle, into box: DataBox, deadline: DeadlineBox) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var acc = Data()
        let cap = 65_536
        var buf = [UInt8](repeating: 0, count: cap)
        while true {
            // Check the deadline on every iteration — including when data is flowing. A detached
            // grandchild that writes continuously would otherwise keep the reader (and Shell.run's
            // group.wait) alive forever, since the EAGAIN path would never be reached.
            if let d = deadline.value, DispatchTime.now() >= d { break }  // child gone + grace elapsed
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, cap) }
            if n > 0 { acc.append(contentsOf: buf[0..<n]); continue }
            if n == 0 { break }                                 // EOF — write end fully closed
            if errno == EINTR { continue }
            if errno != EAGAIN && errno != EWOULDBLOCK { break } // unexpected error — stop
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, 250)                               // wait up to 250ms for data (no busy loop)
        }
        box.set(acc)
    }
}

/// Thread-safe `Data` container for collecting subprocess output from a background queue.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Thread-safe one-way flag, set by the timeout watchdog and read after the process exits.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Thread-safe optional deadline, set once the child exits so the pipe readers know when to stop.
private final class DeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: DispatchTime?
    func set(_ d: DispatchTime) { lock.lock(); deadline = d; lock.unlock() }
    var value: DispatchTime? { lock.lock(); defer { lock.unlock() }; return deadline }
}
