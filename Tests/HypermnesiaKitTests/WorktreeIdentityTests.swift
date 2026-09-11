import Foundation
import Testing
@testable import HypermnesiaKit

/// Sessions in a linked git worktree must belong to the SAME project as the main checkout —
/// conventions and decisions describe the project, and worktrees are routinely deleted. Before
/// canonicalization, a worktree of a remote-less repo minted its own `path:<worktree>` project and
/// its memories were orphaned with the directory.
@Suite("Worktree identity")
struct WorktreeIdentityTests {

    /// A committed repo (optionally with an origin remote) plus a linked worktree on a branch.
    /// Commits carry inline -c identity so the test is hermetic on CI runners with no git config.
    private func makeRepoWithWorktree(
        remote: String? = nil
    ) throws -> (repo: String, worktree: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ht-wt-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        @discardableResult
        func git(_ args: [String], cwd: String) -> Shell.Result {
            Shell.run("git", ["-C", cwd] + args, cwd: cwd)
        }
        git(["init", "-q"], cwd: repo.path)
        git(["-c", "user.email=t@example.com", "-c", "user.name=t",
             "commit", "-q", "--allow-empty", "-m", "init"], cwd: repo.path)
        if let remote { git(["remote", "add", "origin", remote], cwd: repo.path) }
        let worktree = base.appendingPathComponent("wt", isDirectory: true)
        git(["worktree", "add", "-q", worktree.path, "-b", "feature"], cwd: repo.path)
        return (repo.path, worktree.path, { try? fm.removeItem(at: base) })
    }

    @Test("canonicalRepoRoot resolves a worktree to the main checkout; repoRoot keeps the worktree")
    func canonicalRootUnifiesWorktree() throws {
        let (repo, worktree, cleanup) = try makeRepoWithWorktree()
        defer { cleanup() }
        let canonRepo = CanonicalPath.resolve(repo)
        #expect(ProjectIdentity.canonicalRepoRoot(cwd: worktree).map(CanonicalPath.resolve) == canonRepo)
        #expect(ProjectIdentity.canonicalRepoRoot(cwd: repo).map(CanonicalPath.resolve) == canonRepo)
        // The session-local toplevel is still the worktree — file paths captured there must
        // relativize against the tree the session actually edited.
        #expect(ProjectIdentity.repoRoot(cwd: worktree).map(CanonicalPath.resolve)
            == CanonicalPath.resolve(worktree))
    }

    @Test("a worktree of a remote-less repo resolves to the parent repo's project id")
    func worktreeUnifiesPathIdentity() throws {
        let (repo, worktree, cleanup) = try makeRepoWithWorktree()
        defer { cleanup() }
        #expect(ProjectIdentity.resolve(cwd: worktree) == ProjectIdentity.resolve(cwd: repo))
        #expect(ProjectIdentity.resolve(cwd: repo) == "path:\(CanonicalPath.resolve(repo))")
    }

    @Test("a worktree of a remote-backed repo resolves to the remote id")
    func worktreeUnifiesRemoteIdentity() throws {
        let (repo, worktree, cleanup) = try makeRepoWithWorktree(remote: "git@github.com:acme/app.git")
        defer { cleanup() }
        #expect(ProjectIdentity.resolve(cwd: worktree) == "github.com/acme/app")
        #expect(ProjectIdentity.resolve(cwd: repo) == "github.com/acme/app")
    }

    @Test("unification folds a fragmented worktree project into the parent, edges deduped")
    func migrationFoldsWorktreeProject() throws {
        let (repo, worktree, cleanup) = try makeRepoWithWorktree()
        defer { cleanup() }
        let store = try MemoryStore(location: .inMemory)
        let parentId = ProjectIdentity.resolve(cwd: repo)
        let worktreeId = "path:\(CanonicalPath.resolve(worktree))"   // pre-fix fragmented id

        let orphan = MemoryNode(
            projectId: worktreeId, type: .decision, status: .confirmed,
            title: "Use structured logging", summary: "Decided in the worktree session",
            data: .decision(.init(chosen: "Use structured logging", rationale: "grep-ability")))
        let resident = MemoryNode(
            projectId: parentId, type: .convention, status: .confirmed,
            title: "Tabs for indentation", summary: "House style",
            data: .convention(.init(rule: "Tabs for indentation")))
        try store.upsert([orphan, resident])
        // Same edge on both sides: the fold must keep the parent's row and drop the duplicate.
        try store.upsert(MemoryEdge(
            projectId: worktreeId, source: orphan.id, target: resident.id, relationship: .relatedTo))
        try store.upsert(MemoryEdge(
            projectId: parentId, source: orphan.id, target: resident.id, relationship: .relatedTo))

        let touched = WorktreeUnification.run(store: store)
        #expect(touched == [parentId])
        #expect(try store.allProjects() == [parentId])
        let migrated = try store.allNodes(projectId: parentId).map(\.id)
        #expect(Set(migrated) == [orphan.id, resident.id])
    }
}
