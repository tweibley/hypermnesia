import Foundation

/// Shared health-check surface for the per-client hook installers (Claude Code, Cursor,
/// Antigravity). Each client records hook commands in its own settings format, so recovering the
/// binary paths those hooks exec is per-installer; deciding whether any of them has vanished is
/// not — the extension methods below centralize it.
public protocol HookInstallerType {
    /// The distinct binary paths this client's installed hook commands are recorded to invoke.
    /// `isInstalled` only proves our name is mentioned in the settings file; this recovers the
    /// actual executable the hooks will exec so callers can confirm it still exists (a moved /
    /// translocated app bakes in a path that later vanishes, leaving hooks that fail silently on
    /// every session).
    static func installedBinaryPaths(projectPath: String?) -> [String]
}

extension HookInstallerType {
    /// Recorded hook binaries that no longer exist / aren't executable — the hooks are present in
    /// the settings file yet every session's hook exec fails silently. Empty when there's nothing
    /// to repair (including when hooks aren't installed at all).
    public static func missingBinaryPaths(projectPath: String? = nil) -> [String] {
        installedBinaryPaths(projectPath: projectPath).filter {
            !FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// True when hooks are recorded but at least one points at a binary that's gone — a broken
    /// install that `isInstalled` reports as healthy. Surfaced as a repair prompt in Settings and
    /// a distinct line in `hypermnesia doctor`.
    public static func hasMissingBinary(projectPath: String? = nil) -> Bool {
        !missingBinaryPaths(projectPath: projectPath).isEmpty
    }
}
