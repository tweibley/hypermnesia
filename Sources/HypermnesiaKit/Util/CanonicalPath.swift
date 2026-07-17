import Foundation

/// Canonicalizes a filesystem path by fully resolving symlinks, matching libc `realpath` — which
/// is exactly how Claude Code derives the working directory it encodes into its transcript
/// directory names (`~/.claude/projects/<encoded-cwd>/`).
///
/// This deliberately does **not** use `URL.resolvingSymlinksInPath()`: on macOS that API strips a
/// leading `/private` once the resolved path exists, collapsing `/private/var/…` back to `/var/…`.
/// But macOS symlinks `/tmp` → `/private/tmp` and `/var` → `/private/var`, and Claude Code names
/// its directories from the `/private`-prefixed real path. To find a repo's transcripts by path —
/// and to mint a stable project id — we must resolve the same way Claude Code does.
public enum CanonicalPath {

    /// The fully symlink-resolved absolute path. Falls back to a `.`/`..`-standardized path when
    /// the path doesn't exist on disk (where `realpath` returns `NULL`).
    public static func resolve(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
