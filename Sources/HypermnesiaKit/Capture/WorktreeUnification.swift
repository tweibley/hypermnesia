import Foundation

/// One-time fold of projects fragmented by git worktrees.
///
/// Before `ProjectIdentity` learned to canonicalize worktrees (`canonicalRepoRoot`), a session in
/// a linked worktree of a remote-less repo resolved to `path:<worktree-dir>` — a separate project
/// with an empty memory bank, orphaned when the worktree was deleted. This sweep re-resolves every
/// `path:` project whose directory still exists and folds it into today's id when they differ
/// (its parent repo's path, or a remote id the repo gained since capture).
///
/// Deleted worktrees are undetectable — there is no `.git` left to ask for the parent — so those
/// projects are left to age out. Runs from drain housekeeping (single-flight under the drain
/// lock), at most once per process; re-runs only re-check that nothing resolvable remains.
enum WorktreeUnification {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ran = false

    /// Returns the target project ids that received memories, so the caller's conflict sweep can
    /// reconcile any duplicates the merge introduced.
    static func runOnce(store: MemoryStore) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !ran else { return [] }
        ran = true
        return run(store: store)
    }

    /// The unguarded fold — separated so tests can exercise it without consuming the once-guard.
    static func run(store: MemoryStore) -> Set<String> {
        var touched: Set<String> = []
        for projectId in (try? store.allProjects()) ?? [] where projectId.hasPrefix("path:") {
            let dir = String(projectId.dropFirst(5))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let canonical = ProjectIdentity.resolve(cwd: dir)
            guard canonical != projectId,
                  (try? store.reassignProject(from: projectId, to: canonical)) != nil else { continue }
            touched.insert(canonical)
        }
        return touched
    }
}
