import Foundation

/// The complete reversible result of a confirmation action.
public struct MemoryConfirmationResult: Sendable {
    public let confirmed: Int
    public let snapshots: [MemoryNode]

    public init(confirmed: Int, snapshots: [MemoryNode]) {
        self.confirmed = confirmed
        self.snapshots = snapshots
    }
}

/// Canonical confirmation semantics shared by single and bulk UI actions.
public enum MemoryTriageService {
    /// Confirms drafts in caller order. Every touched row is persisted atomically: the confirmed
    /// draft, its superseded target, and near-duplicate drafts purged by layer-2 dedup. The returned
    /// pre-mutation snapshots are sufficient to undo the entire action with one bulk upsert.
    public static func confirm(
        nodeIDs: [String], store: MemoryStore, at: Date = Date()
    ) throws -> MemoryConfirmationResult {
        var requested: [MemoryNode] = []
        var seen = Set<String>()
        for id in nodeIDs where seen.insert(id).inserted {
            if let node = try store.node(id: id), node.status == .draft, !node.isDeleted {
                requested.append(node)
            }
        }
        guard !requested.isEmpty else {
            return MemoryConfirmationResult(confirmed: 0, snapshots: [])
        }

        var states: [String: MemoryNode] = [:]
        for projectId in Set(requested.map(\.projectId)) {
            for node in try store.allNodes(projectId: projectId, includeDeleted: true) {
                states[node.id] = node
            }
        }

        var snapshots: [String: MemoryNode] = [:]
        var mutations: [String: MemoryNode] = [:]
        var confirmed = 0

        func remember(_ node: MemoryNode) {
            if snapshots[node.id] == nil { snapshots[node.id] = node }
        }
        func mutate(_ node: MemoryNode) {
            states[node.id] = node
            mutations[node.id] = node
        }

        for requestedNode in requested {
            guard var node = states[requestedNode.id],
                  node.status == .draft, !node.isDeleted else { continue }
            remember(node)
            node.status = .confirmed
            node.updatedAt = at
            mutate(node)
            confirmed += 1

            if let oldId = node.supersedesId,
               var old = states[oldId], !old.isDeleted, !old.isSuperseded {
                remember(old)
                old.supersededById = node.id
                old.updatedAt = at
                mutate(old)
            }

            let drafts = states.values.filter { $0.projectId == node.projectId }
            for duplicate in DedupEngine.similarDrafts(to: node, among: drafts) {
                guard var purged = states[duplicate.id], !purged.isDeleted else { continue }
                remember(purged)
                purged.deletedAt = at
                purged.updatedAt = at
                mutate(purged)
            }
        }

        try store.upsert(Array(mutations.values))
        return MemoryConfirmationResult(confirmed: confirmed, snapshots: Array(snapshots.values))
    }
}
