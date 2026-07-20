import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression coverage for H4-skill-update-diff:
/// "Update-with-diff confirmation ignores the scope the user picked."
///
/// The DreamJournalView bug was that when `install(scope:)` threw `existsUnmanaged` for the
/// scope the user actually chose, the UI re-derived a *different* scope from config for both the
/// diff it showed and the file it rewrote. The write only stays honest if `install`,
/// `unmanagedMarkdown`, and `update` all resolve their file from the SAME passed scope — these
/// tests pin that contract at the installer level so the scope the UI threads through is the one
/// that decides which file on disk is read for the diff and rewritten on confirm.
struct BugFix_H4skillupdatediffTests {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("h4-skill-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A user-authored `deploy` skill sits at BOTH the project and the user scope. This is the
    /// exact shape that made the bug destructive: the diff/update target must follow the scope
    /// that blocked the install, never the other one.
    private func makeForeignSkillsAtBothScopes(root: URL) throws -> (project: URL, home: URL) {
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectSkill = project.appendingPathComponent(".claude/skills/deploy")
        let homeSkill = home.appendingPathComponent(".claude/skills/deploy")
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeSkill, withIntermediateDirectories: true)
        try Data("PROJECT-AUTHORED".utf8).write(to: projectSkill.appendingPathComponent("SKILL.md"))
        try Data("USER-AUTHORED".utf8).write(to: homeSkill.appendingPathComponent("SKILL.md"))
        return (project, home)
    }

    private func proposal() -> DreamSkillProposal {
        DreamSkillProposal(
            slug: "deploy", title: "Deploy", description: "Ship it",
            rationale: "Repeated in two sessions",
            markdown: "---\nname: Deploy\n---\n\nDREAM-CONTENT",
            evidence: [DreamQuote(sessionId: "s1", text: "a"), DreamQuote(sessionId: "s2", text: "b")])
    }

    @Test("install blocks on the primary dir of the PASSED scope, not a config default")
    func existsUnmanagedIsScopeSpecific() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, home) = try makeForeignSkillsAtBothScopes(root: root)
        let manifestURL = root.appendingPathComponent("manifest.json")

        // Picking "user" must report the USER dir as the blocker (the file the UI will diff/rewrite).
        #expect(throws: SkillInstallError.existsUnmanaged(
            path: home.appendingPathComponent(".claude/skills/deploy").path)) {
            try SkillInstaller.install(
                proposal(), scope: "user", projectPath: project.path, projectId: "p",
                home: home, manifestURL: manifestURL)
        }
        // Picking "project" reports the PROJECT dir instead — a different file entirely.
        #expect(throws: SkillInstallError.existsUnmanaged(
            path: project.appendingPathComponent(".claude/skills/deploy").path)) {
            try SkillInstaller.install(
                proposal(), scope: "project", projectPath: project.path, projectId: "p",
                home: home, manifestURL: manifestURL)
        }
    }

    @Test("the diff source (unmanagedMarkdown) reads the file at the PASSED scope")
    func unmanagedMarkdownFollowsScope() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, home) = try makeForeignSkillsAtBothScopes(root: root)

        #expect(SkillInstaller.unmanagedMarkdown(
            slug: "deploy", scope: "user", projectPath: project.path, home: home) == "USER-AUTHORED")
        #expect(SkillInstaller.unmanagedMarkdown(
            slug: "deploy", scope: "project", projectPath: project.path, home: home) == "PROJECT-AUTHORED")
    }

    @Test("update rewrites ONLY the passed scope's file; the other scope's foreign skill is untouched")
    func updateWritesTheScopeUserPicked() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, home) = try makeForeignSkillsAtBothScopes(root: root)
        let manifestURL = root.appendingPathComponent("manifest.json")

        // User picked "user" → confirmUpdate(scope: "user") must land in ~/.claude/skills/deploy.
        _ = try SkillInstaller.update(
            slug: "deploy", markdown: proposal().markdown, title: "Deploy",
            scope: "user", projectPath: project.path, projectId: "p",
            home: home, manifestURL: manifestURL)

        let homeMarkdown = try String(
            contentsOf: home.appendingPathComponent(".claude/skills/deploy/SKILL.md"), encoding: .utf8)
        #expect(homeMarkdown.contains("DREAM-CONTENT"))
        // The project skill that the user never chose stays exactly as they wrote it.
        let projectMarkdown = try String(
            contentsOf: project.appendingPathComponent(".claude/skills/deploy/SKILL.md"), encoding: .utf8)
        #expect(projectMarkdown == "PROJECT-AUTHORED")
    }
}
