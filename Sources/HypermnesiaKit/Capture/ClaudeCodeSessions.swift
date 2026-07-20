import Foundation

/// Discovers Claude Code session transcripts on disk.
///
/// Claude Code stores each session at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where
/// `<encoded-cwd>` is the absolute working directory with every non-alphanumeric character replaced
/// by `-`. (`CLAUDE_CONFIG_DIR` overrides `~/.claude`.)
public enum ClaudeCodeSessions {

    public static var projectsDirectory: URL {
        let base: URL
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            base = URL(fileURLWithPath: configDir)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
        }
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    /// Claude Code's directory-name encoding: symlink-resolve the cwd (Claude names its transcript
    /// dir from the real path — `/var/…` → `/private/var/…` on macOS), then map `[^A-Za-z0-9]` → `-`.
    ///
    /// Claude Code's JS does `replace(/[^a-zA-Z0-9]/g, "-")` per UTF-16 code unit against **ASCII**
    /// alphanumerics only — so we must match that exactly. `Character.isLetter/isNumber` are
    /// Unicode-aware (`ö`, `项` count as letters) and would diverge, making non-ASCII paths find zero
    /// transcripts. Iterate UTF-16 units and keep only ASCII `[A-Za-z0-9]`.
    public static func encode(path: String) -> String {
        let resolved = CanonicalPath.resolve(path)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(resolved.utf16.count)
        for unit in resolved.utf16 {
            let isASCIIAlnum = (unit >= 48 && unit <= 57)   // 0-9
                || (unit >= 65 && unit <= 90)               // A-Z
                || (unit >= 97 && unit <= 122)              // a-z
            bytes.append(isASCIIAlnum ? UInt8(unit) : 0x2D) // else '-'
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public struct Transcript: Sendable, Hashable {
        public let sessionId: String
        public let url: URL
        public let modifiedAt: Date
    }

    /// All transcripts whose cwd is the repo (or a subdirectory of it), oldest first.
    public static func transcripts(forRepoPath repoPath: String) -> [Transcript] {
        let encoded = encode(path: repoPath)
        let canonRepo = CanonicalPath.resolve(repoPath)
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        // Prefilter by dir name: the repo's own dir, plus any subdirectory-cwd dirs (encoded + "-…").
        // The encoding is lossy (both `/` and `-` map to `-`), so the `encoded + "-"` prefix also
        // matches a *sibling* repo like `foo-bar` for `foo`. Confirm each transcript's real cwd below
        // before claiming it, so one repo's sessions can't be ingested into a dash-prefixed neighbor.
        let matching = projectDirs.filter { dir in
            let name = dir.lastPathComponent
            return name == encoded || name.hasPrefix(encoded + "-")
        }

        var transcripts: [Transcript] = []
        for dir in matching {
            let exactDir = dir.lastPathComponent == encoded
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // Verify the transcript's own cwd is the repo or a descendant. If the cwd can't be
                // read, trust only an exact dir-name match (ambiguous prefix dirs are skipped).
                if let cwd = firstCwd(of: file).map({ CanonicalPath.resolve($0) }) {
                    guard cwd == canonRepo || cwd.hasPrefix(canonRepo + "/") else { continue }
                } else if !exactDir {
                    continue
                }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date(timeIntervalSince1970: 0)
                transcripts.append(Transcript(
                    sessionId: file.deletingPathExtension().lastPathComponent,
                    url: file,
                    modifiedAt: mtime
                ))
            }
        }
        return transcripts.sorted { $0.modifiedAt < $1.modifiedAt }
    }

    /// Every transcript on disk, across all projects, oldest first.
    public static func allTranscripts() -> [Transcript] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var transcripts: [Transcript] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date(timeIntervalSince1970: 0)
                transcripts.append(Transcript(
                    sessionId: file.deletingPathExtension().lastPathComponent, url: file, modifiedAt: mtime
                ))
            }
        }
        return transcripts.sorted { $0.modifiedAt < $1.modifiedAt }
    }

    /// Whether a working directory is transient (temp dirs) and not worth building memory for.
    public static func isEphemeral(cwd: String) -> Bool {
        ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].contains { cwd.hasPrefix($0) }
    }

    /// The working directory a transcript ran in (read from its first line carrying a `cwd`).
    ///
    /// Reads incrementally rather than a single fixed prefix. A session whose early lines contain a
    /// huge pasted attachment (base64 image, large file/tool payload) must not push the first
    /// cwd-bearing line out of a small fixed window and become permanently unattributable — which
    /// silently excludes it from `backfill --all` and from `transcripts(forRepoPath:)`. Oversized
    /// lines can't be a compact `{…"cwd":…}` header, so they're skipped without a parse attempt.
    public static func firstCwd(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let maxScan = 16 * 1024 * 1024        // overall ceiling so a cwd-less transcript isn't read whole
        let maxLineBytes = 512 * 1024         // a cwd header line is tiny; skip anything larger unparsed

        func cwd(inLine line: Data) -> String? {
            guard !line.isEmpty, line.count <= maxLineBytes,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let value = object["cwd"] as? String else { return nil }
            return value
        }

        var buffer = Data()
        var scanned = 0
        var skippingOversized = false        // discarding the tail of a too-large line until its newline
        while scanned < maxScan, let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            scanned += chunk.count
            buffer.append(chunk)
            // Split off only *complete* lines; keep the trailing partial for the next chunk.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if skippingOversized {
                    skippingOversized = false   // this newline ends the oversized line we skipped
                    continue
                }
                if let value = cwd(inLine: line) { return value }
            }
            // An unterminated line already larger than a plausible cwd header can't be one — drop the
            // buffered partial (a 600 KB attachment line costs nothing) and skip until its newline.
            if buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
                skippingOversized = true
            }
        }
        // Trailing line with no final newline (EOF), unless we were mid-skip of an oversized line.
        if !skippingOversized, let value = cwd(inLine: buffer) { return value }
        return nil
    }
}
