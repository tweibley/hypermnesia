import Foundation
import Testing
@testable import HypermnesiaKit

// Regression coverage for cluster H3-skill-scope: dream-skill manifest lookups must be keyed on
// (slug, scope, projectId), not slug alone. Otherwise installing a same-slug skill into a SECOND
// project silently rewrote the FIRST project's copy (and wrote nothing to the current one), and a
// stale/removed directory made an "update" report success while writing nothing.
@Suite("BugFix H3 skill scope")
struct BugFixH3SkillScopeTests {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("h3-skill-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func proposal(
        slug: String = "release-checklist", markdown: String = "---\nname: X\n---\nbody"
    ) -> DreamSkillProposal {
        DreamSkillProposal(
            slug: slug, title: "Release checklist", description: "Run the release steps",
            rationale: "Repeated across sessions", markdown: markdown,
            evidence: [DreamQuote(sessionId: "s1", text: "a")])
    }

    @Test("installing the same slug into a second project writes to project B, not project A")
    func secondProjectDoesNotClobberFirst() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectA = root.appendingPathComponent("repoA", isDirectory: true)
        let projectB = root.appendingPathComponent("repoB", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")

        _ = try SkillInstaller.install(
            proposal(markdown: "A-content"), scope: "project",
            projectPath: projectA.path, projectId: "A",
            home: home, manifestURL: manifestURL)

        let recordB = try SkillInstaller.install(
            proposal(markdown: "B-content"), scope: "project",
            projectPath: projectB.path, projectId: "B",
            home: home, manifestURL: manifestURL)

        // Project B actually received the skill, at a fresh 1.0.0 (a real install, not an update).
        #expect(recordB.version == "1.0.0")
        let bSkill = projectB.appendingPathComponent(".claude/skills/release-checklist/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: bSkill.path))
        #expect(try String(contentsOf: bSkill, encoding: .utf8) == "B-content")

        // Project A is untouched: still its own content, still version 1.0.0.
        let aSkill = projectA.appendingPathComponent(".claude/skills/release-checklist/SKILL.md")
        #expect(try String(contentsOf: aSkill, encoding: .utf8) == "A-content")
        let aVersion = try String(
            contentsOf: projectA.appendingPathComponent(".claude/skills/release-checklist/VERSION"),
            encoding: .utf8)
        #expect(aVersion.trimmingCharacters(in: .whitespacesAndNewlines) == "1.0.0")

        // Both records coexist in the manifest, distinguished by projectId.
        let manifest = SkillInstaller.loadManifest(from: manifestURL)
        #expect(manifest.skills.count == 2)
        #expect(Set(manifest.skills.compactMap(\.projectId)) == ["A", "B"])
    }

    @Test("re-installing in the SAME project is still an update (version bump), not a duplicate")
    func sameProjectStillUpdates() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")

        _ = try SkillInstaller.install(
            proposal(markdown: "v1"), scope: "project", projectPath: project.path, projectId: "P",
            home: home, manifestURL: manifestURL)
        let updated = try SkillInstaller.install(
            proposal(markdown: "v2"), scope: "project", projectPath: project.path, projectId: "P",
            home: home, manifestURL: manifestURL)

        #expect(updated.version == "1.0.1")
        let manifest = SkillInstaller.loadManifest(from: manifestURL)
        #expect(manifest.skills.count == 1)
        let skillFile = project.appendingPathComponent(".claude/skills/release-checklist/SKILL.md")
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == "v2")
    }

    @Test("uninstalling project B's copy leaves project A's directory and record intact")
    func uninstallTargetsTheRightProject() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectA = root.appendingPathComponent("repoA", isDirectory: true)
        let projectB = root.appendingPathComponent("repoB", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")

        _ = try SkillInstaller.install(
            proposal(markdown: "A"), scope: "project", projectPath: projectA.path, projectId: "A",
            home: home, manifestURL: manifestURL)
        _ = try SkillInstaller.install(
            proposal(markdown: "B"), scope: "project", projectPath: projectB.path, projectId: "B",
            home: home, manifestURL: manifestURL)

        _ = try SkillInstaller.uninstall(
            slug: "release-checklist", scope: "project", projectId: "B", manifestURL: manifestURL)

        // Project B gone; project A survives on disk and in the manifest.
        #expect(!FileManager.default.fileExists(
            atPath: projectB.appendingPathComponent(".claude/skills/release-checklist").path))
        #expect(FileManager.default.fileExists(
            atPath: projectA.appendingPathComponent(".claude/skills/release-checklist/SKILL.md").path))
        let manifest = SkillInstaller.loadManifest(from: manifestURL)
        #expect(manifest.skills.map(\.projectId) == ["A"])
    }

    @Test("install whose recorded directory has vanished reinstalls fresh instead of a silent no-op")
    func staleRecordReinstallsFresh() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")

        _ = try SkillInstaller.install(
            proposal(markdown: "v1"), scope: "project", projectPath: project.path, projectId: "P",
            home: home, manifestURL: manifestURL)

        // Simulate the user deleting the skill directory out from under the manifest.
        try FileManager.default.removeItem(
            at: project.appendingPathComponent(".claude/skills/release-checklist"))

        let record = try SkillInstaller.install(
            proposal(markdown: "v2"), scope: "project", projectPath: project.path, projectId: "P",
            home: home, manifestURL: manifestURL)

        // A real fresh install landed (1.0.0), content on disk — not a phantom success.
        #expect(record.version == "1.0.0")
        let skillFile = project.appendingPathComponent(".claude/skills/release-checklist/SKILL.md")
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == "v2")
        // No duplicate record for the same (slug, scope, projectId).
        #expect(SkillInstaller.loadManifest(from: manifestURL).skills.count == 1)
    }
}
