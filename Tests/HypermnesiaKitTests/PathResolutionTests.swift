import Foundation
import Testing
@testable import HypermnesiaKit

/// Symlinked working directories (anything under `/tmp` or `/var` on macOS, which resolve to
/// `/private/tmp` / `/private/var`) must encode and identify the same way Claude Code does, or
/// `backfill --project` finds zero sessions and live/backfilled memories split across two ids.
@Suite("Path resolution")
struct PathResolutionTests {

    /// Creates `<tmp>/<prefix>-<uuid>/real` plus a sibling symlink `link` → `real`, returning both
    /// paths and a cleanup closure. The temp root is itself under a symlink (`/var/folders/…`),
    /// which is exactly the scenario that broke transcript lookup.
    private func makeSymlinkedDir(_ prefix: String) throws -> (real: String, link: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        return (target.path, link.path, { try? fm.removeItem(at: base) })
    }

    @Test("CanonicalPath.resolve keeps the /private prefix (unlike resolvingSymlinksInPath)")
    func canonicalKeepsPrivatePrefix() throws {
        // macOS symlinks /tmp -> /private/tmp; skip cleanly if this box is unusual.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")) == "/private/tmp" else { return }
        #expect(CanonicalPath.resolve("/tmp") == "/private/tmp")
        // The bug: URL.resolvingSymlinksInPath() strips /private back off.
        #expect(URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path == "/tmp")
    }

    @Test("CanonicalPath.resolve falls back to a standardized path when the path is missing")
    func canonicalFallsBackForMissingPath() {
        let missing = "/no/such/dir/\(UUID().uuidString)/../leaf"
        #expect(CanonicalPath.resolve(missing) == URL(fileURLWithPath: missing).standardizedFileURL.path)
    }

    @Test("encode follows symlinks to the real target, matching Claude Code's transcript dirs")
    func encodeFollowsSymlinks() throws {
        let (real, link, cleanup) = try makeSymlinkedDir("ht-encode")
        defer { cleanup() }
        // The symlinked path and its real target encode identically — Claude names the dir by the real path.
        #expect(ClaudeCodeSessions.encode(path: link) == ClaudeCodeSessions.encode(path: real))
        // And the encoding reflects the resolved leaf ("real"), not the symlink's leaf ("link").
        #expect(ClaudeCodeSessions.encode(path: link).hasSuffix("real"))
    }

    @Test("encode keeps the /private prefix Claude Code uses for symlinked system dirs")
    func encodeKeepsPrivatePrefix() throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")) == "/private/tmp" else { return }
        #expect(ClaudeCodeSessions.encode(path: "/tmp") == "-private-tmp")
    }

    @Test("project id is stable across the symlinked and real form of the same dir")
    func projectIdSymlinkStable() throws {
        let (real, link, cleanup) = try makeSymlinkedDir("ht-projid")
        defer { cleanup() }
        // Temp dir isn't a git repo, so resolve() uses the normalized-path fallback for both.
        #expect(ProjectIdentity.resolve(cwd: link) == ProjectIdentity.resolve(cwd: real))
    }

    @Test("encode maps non-ASCII to '-' the same way Claude Code's ASCII-only regex does")
    func encodeIsASCIIOnly() {
        // Claude Code does replace(/[^a-zA-Z0-9]/g, "-") per UTF-16 unit — non-ASCII letters become '-',
        // NOT kept (which is what the Unicode-aware isLetter/isNumber used to do). Use "π" (a single
        // UTF-16 scalar with no canonical decomposition) so the mapping is normalization-independent.
        #expect(ClaudeCodeSessions.encode(path: "/Users/xπy/proj") == "-Users-x-y-proj")
        #expect(CursorSessions.encode(path: "/Users/xπy/proj") == "Users-x-y-proj")
        // Astral scalars (2 UTF-16 code units) map to two dashes, matching JS per-code-unit behavior.
        #expect(ClaudeCodeSessions.encode(path: "/a/😀b") == "-a---b")
    }
}
