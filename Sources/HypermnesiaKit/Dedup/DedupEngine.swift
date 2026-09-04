import Foundation

/// Near-duplicate detection via Jaccard token similarity. Ported from the original two-layer dedup
/// (`docs/design/04-deduplication.md`): threshold 0.6, lowered to 0.4 when two memories share a git
/// commit. Stopwords match the shipped set (which deliberately does NOT include use/uses/project, so
/// those words count); there's no min-word-length filter, so short tech tokens (go, js, c#) survive.
public enum DedupEngine {
    public static let baseThreshold = 0.6
    public static let sameCommitThreshold = 0.4

    static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "must", "shall", "can", "need", "to", "of",
        "in", "for", "on", "with", "at", "by", "from", "as", "into", "through",
        "during", "before", "after", "above", "below", "between", "under",
        "again", "further", "then", "once", "here", "there", "when", "where",
        "why", "how", "all", "each", "few", "more", "most", "other", "some",
        "such", "no", "nor", "not", "only", "own", "same", "so", "than", "too",
        "very", "just", "and", "but", "if", "or", "because", "until", "while",
        "this", "that", "these", "those", "it", "its", "we", "our", "you", "your",
    ]

    /// Meaningful tokens: lowercased, split on non-word boundaries (keeping `+`/`#` for c++/c#),
    /// stopwords removed.
    public static func tokens(_ text: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        func flush() {
            if !current.isEmpty, !stopwords.contains(current) { result.insert(current) }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "+" || ch == "#" { current.append(ch) }
            else { flush() }
        }
        flush()
        return result
    }

    /// Jaccard similarity (shared / total unique) of two texts' meaningful tokens.
    public static func similarity(_ a: String, _ b: String) -> Double {
        similarity(tokens(a), tokens(b))
    }

    /// Jaccard over already-tokenized sets — the cheap half of `similarity` once a
    /// `DedupTokenCache` has paid the tokenization.
    public static func similarity(_ ta: Set<String>, _ tb: Set<String>) -> Double {
        let union = ta.union(tb).count
        guard union > 0 else { return 0 }
        return Double(ta.intersection(tb).count) / Double(union)
    }

    private static func text(_ node: MemoryNode) -> String { node.title + " " + node.summary }

    /// Whether two memories are near-duplicates (threshold lowered when commits match).
    /// CodeRefs match on exact `filePath` — Jaccard on titles would collide same basenames in
    /// different directories (`Sources/Foo.swift` vs `Tests/Foo.swift`).
    ///
    /// Pass a `DedupTokenCache` from any caller that compares one node against many (or many
    /// against many): tokenization is per-character Unicode-property work and dominates an O(N²)
    /// pass when recomputed per pair.
    public static func isDuplicate(_ a: MemoryNode, _ b: MemoryNode, cache: DedupTokenCache? = nil) -> Bool {
        if a.type == .codeRef, b.type == .codeRef,
           case .codeRef(let ad) = a.data, case .codeRef(let bd) = b.data {
            return ad.filePath == bd.filePath
        }
        let sameCommit = a.commitSha != nil && a.commitSha == b.commitSha
        let threshold = sameCommit ? sameCommitThreshold : baseThreshold
        guard let cache else { return similarity(text(a), text(b)) >= threshold }
        let ta = cache.textTokens(a), tb = cache.textTokens(b)
        // Jaccard is bounded above by |smaller| / |larger| — when even the bound misses the
        // threshold, skip the intersection (and its per-element string hashing) entirely.
        let hi = max(ta.count, tb.count)
        guard hi > 0, Double(min(ta.count, tb.count)) / Double(hi) >= threshold else { return false }
        return similarity(ta, tb) >= threshold
    }

    /// The first existing memory (same type, not deleted, not the candidate) that duplicates
    /// `candidate`. `statuses` optionally restricts which statuses are considered.
    public static func duplicate(
        of candidate: MemoryNode, in existing: [MemoryNode], statuses: Set<MemoryStatus>? = nil
    ) -> MemoryNode? {
        let cache = DedupTokenCache()
        return existing.first { other in
            other.id != candidate.id
                && !other.isDeleted
                && other.type == candidate.type
                && (statuses?.contains(other.status) ?? true)
                && isDuplicate(candidate, other, cache: cache)
        }
    }

    /// Layer 2: draft memories similar to `node` (for purge-on-confirm).
    public static func similarDrafts(to node: MemoryNode, among existing: [MemoryNode]) -> [MemoryNode] {
        let cache = DedupTokenCache()
        return existing.filter { $0.id != node.id && $0.status == .draft && !$0.isDeleted
            && $0.type == node.type && isDuplicate(node, $0, cache: cache) }
    }
}

/// Memoizes per-node token sets across a comparison pass, keyed by node id. Valid for the life of
/// one pass: nothing in the dedup/conflict paths mutates a node's title or summary mid-pass (the
/// conflict sweep only touches supersede links and timestamps).
public final class DedupTokenCache {
    private var text: [String: Set<String>] = [:]
    private var title: [String: Set<String>] = [:]

    public init() {}

    /// Tokens of `title + " " + summary` (what `isDuplicate` compares).
    func textTokens(_ node: MemoryNode) -> Set<String> {
        if let cached = text[node.id] { return cached }
        let computed = DedupEngine.tokens(node.title + " " + node.summary)
        text[node.id] = computed
        return computed
    }

    /// Tokens of the title alone (what the conflict engine's same-topic score compares).
    func titleTokens(_ node: MemoryNode) -> Set<String> {
        if let cached = title[node.id] { return cached }
        let computed = DedupEngine.tokens(node.title)
        title[node.id] = computed
        return computed
    }
}
