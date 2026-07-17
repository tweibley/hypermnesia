import Foundation

/// Discovers Cursor agent-session transcripts on disk.
///
/// Cursor stores each session at
/// `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<session-id>/<session-id>.jsonl`, where
/// `<encoded-cwd>` is the workspace path with the leading `/` dropped and every non-alphanumeric
/// character replaced by `-`. (Subagent transcripts live under `…/<session-id>/subagents/` and are
/// skipped here.) This mirrors `ClaudeCodeSessions`, but the directory encoding differs: Cursor does
/// *not* drop a leading dash and does *not* symlink-resolve the path.
public enum CursorSessions {

    public static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Cursor's directory-name encoding: drop the leading `/`, then map `[^A-Za-z0-9]` → `-`.
    /// Unlike Claude Code, Cursor keeps the literal (non-symlink-resolved) path.
    ///
    /// Match ASCII `[A-Za-z0-9]` per UTF-16 code unit (not Unicode-aware `isLetter/isNumber`), so a
    /// workspace with non-ASCII characters encodes the same way Cursor's own JS does.
    public static func encode(path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.utf16.count)
        for unit in trimmed.utf16 {
            let isASCIIAlnum = (unit >= 48 && unit <= 57)
                || (unit >= 65 && unit <= 90)
                || (unit >= 97 && unit <= 122)
            bytes.append(isASCIIAlnum ? UInt8(unit) : 0x2D)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public struct Transcript: Sendable, Hashable {
        public let sessionId: String
        public let url: URL
        public let modifiedAt: Date
    }

    /// Canonical transcript path for a (cwd, sessionId) — used as a fallback when a hook omits
    /// `transcript_path`.
    public static func transcriptPath(cwd: String, sessionId: String) -> URL {
        projectsDirectory
            .appendingPathComponent(encode(path: cwd), isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// All transcripts whose workspace is the repo, oldest first. Matches both the literal and the
    /// symlink-resolved encodings of `repoPath` for robustness.
    ///
    /// Exact-dir match only: the encoding is lossy (`/` and `-` both map to `-`), so an `encoded + "-"`
    /// prefix match would also catch a *sibling* repo (`foo-bar` for `foo`) and — because Cursor
    /// transcripts carry no `cwd` field to disambiguate with (unlike Claude's) — silently ingest its
    /// sessions into the wrong project and mark them processed. A workspace that is a strict
    /// subdirectory of the repo can be backfilled by passing that subdirectory path directly.
    public static func transcripts(forRepoPath repoPath: String) -> [Transcript] {
        let encodings = Set([encode(path: repoPath), encode(path: CanonicalPath.resolve(repoPath))])
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let matching = projectDirs.filter { dir in encodings.contains(dir.lastPathComponent) }

        var transcripts: [Transcript] = []
        for dir in matching {
            transcripts += transcriptsInProjectDir(dir)
        }
        return transcripts.sorted { $0.modifiedAt < $1.modifiedAt }
    }

    /// Every transcript on disk, across all Cursor projects, oldest first.
    public static func allTranscripts() -> [Transcript] {
        allTranscriptsByProjectDir().map(\.transcript)
    }

    /// Every session transcript with the encoded project-directory name it lives under — bulk
    /// backfill needs the directory because Cursor transcript lines carry no `cwd`.
    public static func allTranscriptsByProjectDir() -> [(encodedDir: String, transcript: Transcript)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(encodedDir: String, transcript: Transcript)] = []
        for dir in dirs {
            for transcript in transcriptsInProjectDir(dir) {
                out.append((dir.lastPathComponent, transcript))
            }
        }
        return out.sorted { $0.transcript.modifiedAt < $1.transcript.modifiedAt }
    }

    /// Best-effort inverse of `encode(path:)`. The encoding is lossy — every non-alphanumeric
    /// character became `-` — so each dash is either a path separator or one of the common in-name
    /// characters (`-`, `.`, `_`, space). The search is pruned against the real filesystem: a branch
    /// survives only while some entry of the current parent directory extends the partial segment,
    /// which collapses the combinatorics to (in practice) the single true path. Returns nil when no
    /// on-disk directory matches (renamed/deleted workspace, exotic characters); callers must treat
    /// that as "can't backfill this one".
    public static func decode(encodedDir: String) -> String? {
        guard !encodedDir.isEmpty else { return nil }
        let tokens = encodedDir.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let fm = FileManager.default
        var listings: [String: [String]] = [:]
        func entries(of dir: String) -> [String] {
            if let cached = listings[dir] { return cached }
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            listings[dir] = names
            return names
        }
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func join(_ parent: String, _ name: String) -> String {
            parent == "/" ? "/" + name : parent + "/" + name
        }
        var budget = 5_000   // backstop for adversarial trees; real paths prune to one branch
        func search(_ index: Int, parent: String, segment: String) -> String? {
            budget -= 1
            guard budget > 0 else { return nil }
            let seg = segment + tokens[index]
            let names = entries(of: parent)
            if index == tokens.count - 1 {
                let full = join(parent, seg)
                return names.contains(seg) && isDirectory(full) ? full : nil
            }
            // The dash after this token was a path separator: seg must be a real subdirectory.
            if names.contains(seg) {
                let full = join(parent, seg)
                if isDirectory(full), let found = search(index + 1, parent: full, segment: "") {
                    return found
                }
            }
            // …or a literal character inside the name: only follow joiners some entry actually extends.
            for joiner in ["-", ".", "_", " "] where names.contains(where: { $0.hasPrefix(seg + joiner) }) {
                if let found = search(index + 1, parent: parent, segment: seg + joiner) { return found }
            }
            return nil
        }
        return search(0, parent: "/", segment: "")
    }

    /// The session transcripts directly under `<projectDir>/agent-transcripts/<id>/<id>.jsonl`
    /// (subagent transcripts under `…/<id>/subagents/` are not session roots and are skipped).
    private static func transcriptsInProjectDir(_ projectDir: URL) -> [Transcript] {
        let fm = FileManager.default
        let root = projectDir.appendingPathComponent("agent-transcripts", isDirectory: true)
        guard let sessionDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [Transcript] = []
        for sessionDir in sessionDirs {
            let id = sessionDir.lastPathComponent
            let file = sessionDir.appendingPathComponent("\(id).jsonl")
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            out.append(Transcript(
                sessionId: id, url: file,
                modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return out
    }
}
