import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("CodeLinks")
struct CodeLinksTests {

    @Test("GitHub file permalink prefers the pinned commit, then branch, then main")
    func refResolutionOrder() {
        let pinned = CodeLinks.githubFileURL(
            projectId: "github.com/acme/app", path: "Sources/App/Main.swift",
            commitSha: "abc123", branch: "feature/x")
        #expect(pinned?.absoluteString == "https://github.com/acme/app/blob/abc123/Sources/App/Main.swift")

        let branch = CodeLinks.githubFileURL(
            projectId: "github.com/acme/app", path: "a.swift", commitSha: nil, branch: "develop")
        #expect(branch?.absoluteString == "https://github.com/acme/app/blob/develop/a.swift")

        let fallback = CodeLinks.githubFileURL(projectId: "github.com/acme/app", path: "a.swift")
        #expect(fallback?.absoluteString == "https://github.com/acme/app/blob/main/a.swift")
    }

    @Test("line ranges normalize to GitHub fragments in several input forms")
    func lineFragments() {
        #expect(CodeLinks.lineFragment("L10-L20") == "L10-L20")
        #expect(CodeLinks.lineFragment("10-20") == "L10-L20")
        #expect(CodeLinks.lineFragment("L7") == "L7")
        #expect(CodeLinks.lineFragment("lines 3 to 9") == "L3-L9")
        #expect(CodeLinks.lineFragment("whole file") == nil)
        #expect(CodeLinks.lineFragment(nil) == nil)
        let url = CodeLinks.githubFileURL(
            projectId: "github.com/acme/app", path: "a.swift", commitSha: "abc", range: "10-20")
        #expect(url?.absoluteString.hasSuffix("#L10-L20") == true)
    }

    @Test("non-GitHub project ids produce no web links")
    func nonGitHubProjects() {
        #expect(CodeLinks.githubFileURL(projectId: "path:/Users/x/proj", path: "a.swift") == nil)
        #expect(CodeLinks.githubCommitURL(projectId: "gitlab.com/acme/app", commitSha: "abc") == nil)
        #expect(CodeLinks.githubRepo(projectId: "github.com/only-owner") == nil)
    }

    @Test("local file URL resolves only when the file actually exists")
    func localResolution() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("real.swift"))

        #expect(CodeLinks.localFileURL(repoPath: dir.path, path: "real.swift") != nil)
        #expect(CodeLinks.localFileURL(repoPath: dir.path, path: "missing.swift") == nil)
        #expect(CodeLinks.localFileURL(repoPath: nil, path: "real.swift") == nil)
    }
}
