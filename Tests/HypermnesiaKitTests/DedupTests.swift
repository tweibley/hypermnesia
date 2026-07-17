import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Dedup")
struct DedupTests {
    private func node(_ type: MemoryType, _ title: String, _ summary: String,
                      status: MemoryStatus = .confirmed, commit: String? = nil) -> MemoryNode {
        MemoryNode(projectId: "p", type: type, status: status, title: title, summary: summary,
                   data: .fact(.init(category: "c", key: "k", value: "v")), commitSha: commit)
    }

    @Test("tokenizing keeps tech words and use/project; drops stopwords")
    func tokenizing() {
        // "the"/"and" are stopwords; "project"/"uses"/"use"/"go"/"c++" are kept.
        #expect(DedupEngine.tokens("The project uses TypeScript") == Set(["project", "uses", "typescript"]))
        #expect(DedupEngine.tokens("Use Go and C++") == Set(["use", "go", "c++"]))
    }

    @Test("similarity is Jaccard of meaningful tokens")
    func similarity() {
        #expect(DedupEngine.similarity("Use Postgres for search", "Use Postgres for search") == 1.0)
        let s = DedupEngine.similarity("Uses TypeScript", "Uses PostgreSQL")
        #expect(s > 0 && s < 0.6)   // ~0.33, keep both
    }

    @Test("near-duplicate detection; matching commit lowers the threshold")
    func duplicateDetection() {
        let a = node(.convention, "Use tabs", "Always use tabs for indentation")
        let b = node(.convention, "Tabs convention", "Always use tabs for indentation in code")
        #expect(DedupEngine.isDuplicate(a, b))

        // A pair whose similarity lands in [0.4, 0.6): dup only when commits match.
        let c = node(.fact, "x1", "alpha beta gamma delta", commit: "sha1")
        let d = node(.fact, "x1", "alpha beta epsilon zeta", commit: "sha1")
        let sim = DedupEngine.similarity("x1 alpha beta gamma delta", "x1 alpha beta epsilon zeta")
        #expect(sim >= 0.4 && sim < 0.6)        // 3 shared / 7 total ≈ 0.43
        #expect(DedupEngine.isDuplicate(c, d))  // same commit → 0.4 threshold → dup
        let cNoCommit = node(.fact, "x1", "alpha beta gamma delta")
        let dNoCommit = node(.fact, "x1", "alpha beta epsilon zeta")
        #expect(!DedupEngine.isDuplicate(cNoCommit, dNoCommit))  // no shared commit → 0.6 → not dup
    }

    @Test("duplicate() matches only the same type and respects status filter")
    func duplicateByType() {
        let candidate = node(.convention, "Use tabs", "Always use tabs for indentation")
        let pool = [
            node(.fact, "Use tabs", "Always use tabs for indentation"),       // same text, wrong type
            node(.convention, "Tabs", "Always use tabs for indentation now"), // the real dup
        ]
        let hit = DedupEngine.duplicate(of: candidate, in: pool)
        #expect(hit?.type == .convention)
    }

    @Test("similarDrafts finds only draft near-duplicates")
    func similarDrafts() {
        let confirmed = node(.decision, "Use REST", "Chose REST over GraphQL for the API")
        let pool = [
            node(.decision, "REST decision", "Chose REST over GraphQL for the public API", status: .draft),
            node(.decision, "Use GraphQL", "Picked GraphQL for flexible queries", status: .draft),
            node(.decision, "REST again", "Chose REST over GraphQL for the API", status: .confirmed),
        ]
        let dups = DedupEngine.similarDrafts(to: confirmed, among: pool)
        #expect(dups.count == 1)
        #expect(dups.first?.title == "REST decision")
    }
}
