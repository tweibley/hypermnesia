import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Shell")
struct ShellTests {

    @Test("captures stdout, stderr, and exit status")
    func capturesStreams() {
        let r = Shell.run("/bin/sh", ["-c", "printf out; printf err 1>&2; exit 3"])
        #expect(r.stdout == "out")
        #expect(r.stderr == "err")
        #expect(r.status == 3)
        #expect(!r.succeeded)
    }

    @Test("delivers stdin to the child")
    func deliversStdin() {
        let r = Shell.run("/bin/cat", [], stdin: "hello stdin")
        #expect(r.stdout == "hello stdin")
        #expect(r.succeeded)
    }

    @Test("a child that exits without reading a large stdin doesn't crash the host (SIGPIPE ignored)")
    func stdinToNonReaderIsSafe() {
        // `true` ignores stdin and exits immediately; writing a big payload would SIGPIPE without the guard.
        let r = Shell.run("/usr/bin/true", [], stdin: String(repeating: "x", count: 500_000))
        #expect(r.succeeded)
    }

    @Test("returns the child's output promptly when a detached grandchild keeps the pipe open")
    func grandchildDoesNotStrand() {
        let start = Date()
        // sh echoes, then backgrounds a long sleep that inherits stdout and outlives sh. The reader
        // must stop at the post-exit drain deadline (~3s), not wait ~30s for the grandchild's EOF.
        let r = Shell.run("/bin/sh", ["-c", "echo hi; sleep 30 &"], timeout: 20)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.stdout.contains("hi"))
        #expect(elapsed < 15)
    }

    @Test("returns promptly when a detached grandchild writes continuously (deadline honored mid-stream)")
    func spammingGrandchildDoesNotStrand() {
        let start = Date()
        // The backgrounded loop inherits stdout and never stops writing, so the reader always has
        // data and would never reach the EAGAIN path. The drain deadline must be honored on the
        // data path too, and closing the read end afterwards SIGPIPEs the orphan writer dead.
        let r = Shell.run("/bin/sh", ["-c", "echo hi; while :; do echo x; done &"], timeout: 20)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.stdout.contains("hi"))
        #expect(elapsed < 15)
    }
}
