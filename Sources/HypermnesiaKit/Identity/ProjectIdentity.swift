import Foundation

/// Resolves a stable project identifier from a working directory.
///
/// Prefers the git remote (so the same repo gets the same id across clones/machines), e.g.
/// `github.com/acme/app`. Falls back to a normalized filesystem path (`path:/Users/x/proj`) when
/// there's no remote. This is the value stored in `MemoryNode.projectId`.
public enum ProjectIdentity {

    public static func resolve(cwd: String) -> String {
        if let remote = gitRemote(cwd: cwd), let normalized = normalizeRemote(remote) {
            return normalized
        }
        return normalizePath(repoRoot(cwd: cwd) ?? cwd)
    }

    /// Human-friendly name for a project id: `github.com/acme/app` → `acme/app`,
    /// `path:/Users/x/proj` → `proj`. Shareable artifacts use this instead of the raw id so a
    /// path-based id never leaks the machine's directory layout.
    public static func displayName(for id: String) -> String {
        if id == MemoryNode.globalProjectId { return "Global" }
        if id.hasPrefix("path:") {
            return URL(fileURLWithPath: String(id.dropFirst(5))).lastPathComponent
        }
        let parts = id.split(separator: "/")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : id
    }

    // MARK: - git

    /// `origin` remote URL, if any.
    static func gitRemote(cwd: String) -> String? {
        let result = Shell.run("git", ["-C", cwd, "remote", "get-url", "origin"], cwd: cwd)
        guard result.succeeded else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Top-level directory of the repo containing `cwd`, if any.
    static func repoRoot(cwd: String) -> String? {
        let result = Shell.run("git", ["-C", cwd, "rev-parse", "--show-toplevel"], cwd: cwd)
        guard result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Current commit SHA, if in a repo.
    public static func headSha(cwd: String) -> String? {
        let result = Shell.run("git", ["-C", cwd, "rev-parse", "HEAD"], cwd: cwd)
        guard result.succeeded else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Current branch name, if in a repo.
    public static func currentBranch(cwd: String) -> String? {
        let result = Shell.run("git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        guard result.succeeded else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch.isEmpty || branch == "HEAD") ? nil : branch
    }

    // MARK: - Normalization

    /// `git@github.com:acme/app.git` / `https://github.com/acme/app.git` → `github.com/acme/app`.
    static func normalizeRemote(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        if let range = s.range(of: "://") {
            // scheme://[user@]host/path
            s = String(s[range.upperBound...])
            if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        } else if let at = s.firstIndex(of: "@"), let colon = s.firstIndex(of: ":") {
            // scp-like: user@host:path
            let host = s[s.index(after: at)..<colon]
            let path = s[s.index(after: colon)...]
            s = "\(host)/\(path)"
        }

        s = s.lowercased()
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s.isEmpty ? nil : s
    }

    /// Symlink-resolve so the same repo gets one id regardless of how its path was reached — e.g.
    /// the live capture hook sees Claude Code's resolved cwd (`/private/var/…`) while `backfill
    /// --project` is handed the symlinked form (`/var/…`). Both must canonicalize to the same id.
    static func normalizePath(_ path: String) -> String {
        return "path:\(CanonicalPath.resolve(path))"
    }
}
