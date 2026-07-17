import Foundation

/// The MCP **recall path** as one unit: the `CLAUDE.md` instruction that tells the agent to call
/// `recall` before editing, *plus* pre-approving the read-only tools it calls so the first call
/// doesn't trip Claude Code's per-session permission prompt.
///
/// The two halves are paired here so `install` and `uninstall` stay **symmetric** — uninstalling the
/// guide also withdraws the pre-approval it granted. (Composing them at two separate call sites is
/// exactly how they drifted out of sync once already.)
///
/// The hooks *push* path is independent — see `HookInstaller` — and deliberately never touches MCP
/// permissions. Pre-approval lives only with this pull-path setup, where the tools are actually used.
public enum RecallPathInstaller {

    /// Write the recall guide and pre-approve the read-only tools (idempotent; both preserve existing
    /// CLAUDE.md prose / permission rules).
    public static func install(projectPath: String? = nil) throws {
        try MemoryGuideInstaller.install(projectPath: projectPath)
        try PermissionInstaller.install(projectPath: projectPath)
    }

    /// Remove the recall guide **and** the tool pre-approval it granted — a full revert of `install`.
    public static func uninstall(projectPath: String? = nil) throws {
        try MemoryGuideInstaller.uninstall(projectPath: projectPath)
        try PermissionInstaller.uninstall(projectPath: projectPath)
    }

    /// Whether both halves are in place.
    public static func isInstalled(projectPath: String? = nil) -> Bool {
        MemoryGuideInstaller.isInstalled(projectPath: projectPath)
            && PermissionInstaller.isInstalled(projectPath: projectPath)
    }
}
