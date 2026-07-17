import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("MemoryMarkdown")
struct MemoryMarkdownTests {

    @Test("a decision renders title, summary, payload bullets, and files")
    func decisionRendering() {
        let node = MemoryNode(
            projectId: "github.com/acme/app", type: .decision, status: .confirmed,
            title: "Use GRDB for storage",
            summary: "SQLite via GRDB instead of Core Data.",
            data: .decision(.init(
                problem: "Need a local store", chosen: "GRDB", alternatives: ["Core Data"],
                rationale: "FTS5 + migrations", revisitTriggers: [], relatedFiles: ["Sources/Store.swift"]
            ))
        )
        let md = MemoryMarkdown.render(node)
        #expect(md.hasPrefix("**[Decision] Use GRDB for storage**"))
        #expect(md.contains("SQLite via GRDB instead of Core Data."))
        #expect(md.contains("- Chosen: GRDB"))
        #expect(md.contains("- Alternatives: Core Data"))
        #expect(md.contains("Files: `Sources/Store.swift`"))
    }

    @Test("empty optional fields produce no bullets; a summary equal to the title isn't repeated")
    func omitsEmptyAndDuplicate() {
        let node = MemoryNode(
            projectId: "github.com/acme/app", type: .fact, status: .confirmed,
            title: "db", summary: "db",
            data: .fact(.init(category: "stack", key: "db", value: "postgres"))
        )
        let md = MemoryMarkdown.render(node)
        #expect(md == "**[Fact] db**\n\n- stack / db: postgres")
    }

    @Test("convention examples and intent behaviors render as bullets")
    func examplesAndBehaviors() {
        let convention = MemoryNode(
            projectId: "github.com/acme/app", type: .convention, status: .confirmed,
            title: "Route diagnostics to stderr", summary: "Keep stdout clean.",
            data: .convention(.init(
                rule: "stderr only",
                examples: [.init(bad: "print(err)", good: "FileHandle.standardError.write(err)")]
            ))
        )
        let md = MemoryMarkdown.render(convention)
        #expect(md.contains("- ✗ Bad: print(err)"))
        #expect(md.contains("- ✓ Good: FileHandle.standardError.write(err)"))

        let intent = MemoryNode(
            projectId: "github.com/acme/app", type: .intent, status: .confirmed,
            title: "Fast hydrate", summary: "Hydration stays under budget.",
            data: .intent(.init(
                goal: "Hydrate in <50ms",
                behaviors: [.init(given: "a warm cache", when: "hydrating", then: "no disk reads")],
                constraints: [], relatedFiles: []
            ))
        )
        let intentMd = MemoryMarkdown.render(intent)
        #expect(intentMd.contains("- Behavior: Given a warm cache, when hydrating, then no disk reads"))
    }
}

@Suite("MemoryMarkdown.projectDigest")
struct ProjectDigestTests {

    private func node(
        _ type: MemoryType = .fact,
        title: String = "t",
        status: MemoryStatus = .confirmed,
        confidence: Double = 1.0,
        data: MemoryData? = nil,
        conversationId: String? = nil,
        timesAppliedSuccess: Int = 0,
        timesOverridden: Int = 0,
        updatedAt: Date = Date()
    ) -> MemoryNode {
        MemoryNode(
            projectId: "path:/Users/someone/secret-place/app", type: type, status: status,
            title: title, summary: "\(title) summary",
            data: data ?? .fact(.init(category: "c", key: "k", value: "v")),
            confidence: confidence, updatedAt: updatedAt,
            conversationId: conversationId,
            timesOverridden: timesOverridden, timesAppliedSuccess: timesAppliedSuccess
        )
    }

    @Test("title uses the display name — a path id never leaks the directory layout")
    func displayNameTitle() {
        let md = MemoryMarkdown.projectDigest(
            projectId: "path:/Users/someone/secret-place/app", nodes: [node()])
        #expect(md.hasPrefix("# app — project memory"))
        #expect(!md.contains("secret-place"))
    }

    @Test("stats line counts types and evidence; drafts and superseded don't count")
    func statsLine() {
        var superseded = node(.decision, title: "old")
        superseded.supersededById = "x"
        let nodes = [
            node(.decision, title: "d1", conversationId: "s1", timesAppliedSuccess: 2),
            node(.convention, title: "c1", conversationId: "s2", timesAppliedSuccess: 1),
            node(.convention, title: "c2", status: .draft),
            superseded,
        ]
        let md = MemoryMarkdown.projectDigest(projectId: "github.com/acme/app", nodes: nodes)
        #expect(md.contains("2 confirmed memories"))
        #expect(md.contains("1 decision, 1 convention"))
        #expect(md.contains("applied 3× across 2 sessions"))
        #expect(!md.contains("### old"))
        #expect(!md.contains("### c2"))
    }

    @Test("table of contents links sections with counts when there are 2+ sections")
    func tableOfContents() {
        let nodes = [node(.decision, title: "d1"), node(.codeRef, title: "r1", data: .codeRef(.init(filePath: "a.swift")))]
        let md = MemoryMarkdown.projectDigest(projectId: "github.com/acme/app", nodes: nodes)
        #expect(md.contains("## Contents"))
        #expect(md.contains("- [Decisions](#decisions) — 1"))
        #expect(md.contains("- [Code References](#code-references) — 1"))
    }

    @Test("single-section digest has no table of contents")
    func noTocForSingleSection() {
        let md = MemoryMarkdown.projectDigest(projectId: "github.com/acme/app", nodes: [node()])
        #expect(!md.contains("## Contents"))
    }

    @Test("meta line carries evidence and flags memories that need review")
    func metaLines() {
        let applied = node(.decision, title: "solid", timesAppliedSuccess: 4, timesOverridden: 1)
        let stale = node(.decision, title: "shaky", confidence: 0.3)
        let md = MemoryMarkdown.projectDigest(projectId: "github.com/acme/app", nodes: [applied, stale])
        #expect(md.contains("applied 4×"))
        #expect(md.contains("overridden 1×"))
        #expect(md.contains("⚠️ aging"))
    }

    @Test("concerns order worst-severity first regardless of recency")
    func concernOrdering() {
        let old = Date(timeIntervalSinceNow: -86_400 * 30)
        let nodes = [
            node(.concern, title: "minor",
                 data: .concern(.init(issue: "i", severity: "low")), updatedAt: Date()),
            node(.concern, title: "major",
                 data: .concern(.init(issue: "i", severity: "high")), updatedAt: old),
        ]
        let md = MemoryMarkdown.projectDigest(projectId: "github.com/acme/app", nodes: nodes)
        let majorIndex = md.range(of: "### major")!.lowerBound
        let minorIndex = md.range(of: "### minor")!.lowerBound
        #expect(majorIndex < minorIndex)
    }

    @Test("empty project renders a graceful placeholder")
    func emptyDigest() {
        let md = MemoryMarkdown.projectDigest(projectId: "github.com/acme/app", nodes: [])
        #expect(md.hasPrefix("# acme/app — project memory"))
        #expect(md.contains("No confirmed memories yet"))
    }
}
