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
        let ta = tokens(a), tb = tokens(b)
        let union = ta.union(tb).count
        guard union > 0 else { return 0 }
        return Double(ta.intersection(tb).count) / Double(union)
    }

    private static func text(_ node: MemoryNode) -> String { node.title + " " + node.summary }

    /// Whether two memories are near-duplicates (threshold lowered when commits match).
    public static func isDuplicate(_ a: MemoryNode, _ b: MemoryNode) -> Bool {
        let sameCommit = a.commitSha != nil && a.commitSha == b.commitSha
        let threshold = sameCommit ? sameCommitThreshold : baseThreshold
        return similarity(text(a), text(b)) >= threshold
    }

    /// The first existing memory (same type, not deleted, not the candidate) that duplicates
    /// `candidate`. `statuses` optionally restricts which statuses are considered.
    public static func duplicate(
        of candidate: MemoryNode, in existing: [MemoryNode], statuses: Set<MemoryStatus>? = nil
    ) -> MemoryNode? {
        existing.first { other in
            other.id != candidate.id
                && !other.isDeleted
                && other.type == candidate.type
                && (statuses?.contains(other.status) ?? true)
                && isDuplicate(candidate, other)
        }
    }

    /// Layer 2: draft memories similar to `node` (for purge-on-confirm).
    public static func similarDrafts(to node: MemoryNode, among existing: [MemoryNode]) -> [MemoryNode] {
        existing.filter { $0.id != node.id && $0.status == .draft && !$0.isDeleted
            && $0.type == node.type && isDuplicate(node, $0) }
    }
}
