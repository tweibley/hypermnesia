import Foundation

/// Cosine-similarity ranking over stored embeddings, plus a lazy indexer. Brute-force is fine at
/// this scale (hundreds of memories per project).
public enum SemanticIndex {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? Double(dot / denom) : 0
    }

    /// Rank candidates by similarity to `query`, keeping scores ≥ `minScore`, top `limit`.
    public static func rank(
        query: [Float], candidates: [(id: String, vector: [Float])], limit: Int, minScore: Double = 0
    ) -> [(id: String, score: Double)] {
        candidates
            .map { (id: $0.id, score: cosine(query, $0.vector)) }
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
            .prefix(max(0, limit))   // negative would trap; clamp defensively
            .map { $0 }
    }

    /// Compute + store embeddings for project memories that don't yet have one for this embedder.
    /// Cheap to call repeatedly — it skips already-indexed nodes. Returns the count indexed.
    @discardableResult
    public static func indexMissing(
        store: MemoryStore, embedder: Embedder, projectId: String, status: MemoryStatus? = nil
    ) -> Int {
        let missing = (try? store.nodesMissingEmbedding(
            projectId: projectId, model: embedder.identifier, status: status
        )) ?? []
        var indexed = 0
        for node in missing {
            guard let vector = embedder.embed(node.title + " " + node.summary) else { continue }
            try? store.setEmbedding(nodeId: node.id, model: embedder.identifier, vector: vector)
            indexed += 1
        }
        return indexed
    }
}
