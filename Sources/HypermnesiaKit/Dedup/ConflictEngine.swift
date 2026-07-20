import Foundation

/// Detects when a newly captured memory *contradicts* an existing one (same topic, materially
/// different content) and applies the supersede once the new memory is confirmed.
///
/// This is the write path for `supersedesId`/`supersededById` — every retrieval path already
/// filters superseded memories, so linking a revision here is what keeps a reversed decision from
/// injecting alongside the decision that replaced it.
///
/// The human-review gate is preserved: capture only *links* the candidate (`supersedesId` on the
/// draft); the old memory is marked superseded (`supersededById`) only when the draft is confirmed
/// — by the user or by reinforcement auto-confirm. Dismissing the draft leaves the old memory
/// untouched.
public enum ConflictEngine {

    /// Minimum title-token Jaccard for two non-duplicate memories to count as "same topic".
    public static let titleConflictThreshold = 0.5

    /// Only types where "newer contradicts older" is meaningful and detectable. Facts are keyed
    /// (deterministic); decisions/conventions revise a named subject. Intent/concern/backlog/codeRef
    /// legitimately accumulate in parallel, so they never conflict.
    static let conflictableTypes: Set<MemoryType> = [.decision, .convention, .fact]

    /// The existing memory that `candidate` contradicts, if any.
    ///
    /// - Facts: same `category` + `key`, different `value` — a revision, detected deterministically.
    /// - Decisions/conventions: title similarity ≥ `titleConflictThreshold` while NOT being a
    ///   near-duplicate overall (a duplicate is reinforcement, not conflict). Best match wins.
    public static func conflict(of candidate: MemoryNode, in existing: [MemoryNode]) -> MemoryNode? {
        guard conflictableTypes.contains(candidate.type) else { return nil }
        let others = existing.filter { other in
            other.id != candidate.id
                && !other.isDeleted
                && !other.isSuperseded
                && other.type == candidate.type
                && !DedupEngine.isDuplicate(candidate, other)
        }
        if case .fact(let fact) = candidate.data {
            return others.first { other in
                guard case .fact(let old) = other.data else { return false }
                return old.category == fact.category && old.key == fact.key && old.value != fact.value
            }
        }
        return others
            .map { (node: $0, score: DedupEngine.similarity(candidate.title, $0.title)) }
            .filter { $0.score >= titleConflictThreshold }
            .max { $0.score < $1.score }?
            .node
    }

    /// Retroactively reconcile conflicts among CONFIRMED memories: the newest memory contradicting
    /// an older one supersedes it, newer-wins. Runs automatically (drain cycle, daily maintenance,
    /// CLI audit); both sides passed human review, and the newer confirmation is the later signal,
    /// so no draft gate applies here.
    ///
    /// Idempotent and restore-respecting: a memory that already carries `supersedesId` is skipped,
    /// and Restore deliberately leaves that link in place as a tombstone — so a pair the user
    /// un-superseded is never re-retired by the next sweep.
    @discardableResult
    public static func sweep(store: MemoryStore, projectId: String) -> Int {
        let confirmed = ((try? store.allNodes(projectId: projectId, status: .confirmed)) ?? [])
            .filter { !$0.isSuperseded && !$0.isDeleted }
        let newestFirst = confirmed.sorted { $0.createdAt > $1.createdAt }
        // Mutable working copies keyed by id: a memory can be BOTH a revision of an older one and,
        // in a longer chain, the target superseded by a still-newer one. Every write must carry
        // forward earlier iterations' mutations, so we always read from and write back to `working`
        // rather than re-persisting the immutable `newestFirst` snapshot (which would clobber a
        // `supersededById` already saved this pass).
        var working = Dictionary(uniqueKeysWithValues: newestFirst.map { ($0.id, $0) })
        var retired = Set<String>()
        var applied = 0
        for snapshot in newestFirst {
            guard var newer = working[snapshot.id], newer.supersedesId == nil else { continue }
            let olderPool = newestFirst.compactMap { working[$0.id] }
                .filter { $0.createdAt < newer.createdAt && !retired.contains($0.id) }
            guard let match = conflict(of: newer, in: olderPool),
                  var older = working[match.id] else { continue }
            newer.supersedesId = older.id
            older.supersededById = newer.id
            older.updatedAt = Date()
            guard (try? store.upsert([newer, older])) != nil else { continue }
            working[newer.id] = newer
            working[older.id] = older
            retired.insert(older.id)
            applied += 1
            MemoryActivityLog.append(.init(
                projectId: projectId,
                eventType: .supersede,
                memoryIds: [older.id, newer.id],
                count: 1,
                metadata: ["source": "sweep"]
            ))
        }
        return applied
    }

    /// Apply the supersede a just-confirmed memory carries: mark the memory it revises as
    /// superseded-by it. Call from every confirm path. No-ops when the node isn't confirmed,
    /// carries no `supersedesId`, or the target is already superseded (first confirm wins).
    public static func applySupersede(for node: MemoryNode, store: MemoryStore) {
        guard node.status == .confirmed,
              let oldId = node.supersedesId,
              var old = (try? store.node(id: oldId)) ?? nil,
              !old.isSuperseded, !old.isDeleted else { return }
        old.supersededById = node.id
        old.updatedAt = Date()
        try? store.upsert(old)
    }
}
