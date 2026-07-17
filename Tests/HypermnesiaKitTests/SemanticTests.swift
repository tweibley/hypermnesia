import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Semantic")
struct SemanticTests {

    /// Deterministic embedder for plumbing tests (an 8-dim vector from character codes).
    struct MockEmbedder: Embedder {
        let identifier = "mock-v1"
        func embed(_ text: String) -> [Float]? {
            guard !text.isEmpty else { return nil }
            var vector = [Float](repeating: 0, count: 8)
            for (i, scalar) in text.unicodeScalars.enumerated() {
                vector[i % 8] += Float(scalar.value % 17)
            }
            return vector
        }
    }

    @Test("cosine similarity")
    func cosine() {
        #expect(SemanticIndex.cosine([Float]([1, 0, 0]), [Float]([1, 0, 0])) == 1.0)
        #expect(SemanticIndex.cosine([Float]([1, 0]), [Float]([0, 1])) == 0.0)
        #expect(abs(SemanticIndex.cosine([Float]([1, 0]), [Float]([-1, 0])) + 1) < 1e-6)
        #expect(SemanticIndex.cosine([Float]([1, 2, 3]), []) == 0)   // mismatched dims
    }

    @Test("rank orders by similarity and respects limit + minScore")
    func rank() {
        let candidates: [(id: String, vector: [Float])] = [
            ("a", [1, 0]), ("b", [0, 1]), ("c", [0.9, 0.1]),
        ]
        let top = SemanticIndex.rank(query: [Float]([1, 0]), candidates: candidates, limit: 2)
        #expect(top.first?.id == "a")
        #expect(top.count == 2)

        let strict = SemanticIndex.rank(query: [Float]([1, 0]), candidates: candidates, limit: 5, minScore: 0.95)
        #expect(strict.allSatisfy { $0.score >= 0.95 })   // a (1.0) and c (~0.99), not b
        #expect(!strict.contains { $0.id == "b" })
    }

    @Test("embeddings round-trip and indexMissing is idempotent")
    func storeAndIndex() throws {
        let store = try MemoryStore(location: .inMemory)
        let project = "github.com/acme/app"
        func node(_ title: String) -> MemoryNode {
            MemoryNode(projectId: project, type: .fact, status: .confirmed, title: title, summary: "s",
                       data: .fact(.init(category: "c", key: "k", value: "v")))
        }
        let n1 = node("Storage layer"), n2 = node("Auth flow")
        try store.upsert([n1, n2])

        #expect(try store.nodesMissingEmbedding(projectId: project, model: "mock-v1").count == 2)

        let indexed = SemanticIndex.indexMissing(store: store, embedder: MockEmbedder(), projectId: project)
        #expect(indexed == 2)
        #expect(try store.nodesMissingEmbedding(projectId: project, model: "mock-v1").isEmpty)

        let vectors = try store.embeddings(for: [n1.id, n2.id])
        #expect(vectors[n1.id]?.count == 8)
        #expect(vectors[n2.id] != nil)

        // Re-indexing does nothing.
        #expect(SemanticIndex.indexMissing(store: store, embedder: MockEmbedder(), projectId: project) == 0)
    }

    @Test("Apple sentence embeddings rank related text above unrelated")
    func appleEmbedderSemantics() {
        let embedder = AppleEmbedder()
        guard embedder.isAvailable else { return }   // model may be absent in some environments
        guard let a = embedder.embed("We store data in a SQLite database"),
              let b = embedder.embed("The database persists records using SQLite"),
              let c = embedder.embed("The weather today is sunny and warm") else {
            Issue.record("expected embeddings"); return
        }
        #expect(SemanticIndex.cosine(a, b) > SemanticIndex.cosine(a, c))
    }
}
