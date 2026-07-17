import Foundation

/// Infers typed edges between a project's memories. The original system's backend returned sparse
/// edges, so the client inferred most relationships from lineage, shared files, and shared sessions
/// (`docs/design/05-graph-and-visualization.md`). This is the local equivalent — pure, bounded, testable.
public enum GraphBuilder {

    /// Derive edges for a set of memory nodes. `fanout` bounds how many same-file links each node
    /// makes, to keep the graph readable.
    public static func inferEdges(_ nodes: [MemoryNode], fanout: Int = 3) -> [MemoryEdge] {
        let present = Set(nodes.map(\.id))
        let projectId = nodes.first?.projectId ?? ""
        var edges: [String: MemoryEdge] = [:]   // keyed by edge.id for dedupe

        func add(_ source: String, _ target: String, _ relationship: MemoryEdgeType) {
            guard source != target, present.contains(source), present.contains(target) else { return }
            let edge = MemoryEdge(projectId: projectId, source: source, target: target, relationship: relationship)
            edges[edge.id] = edge   // keep one per (source, rel, target)
        }

        // 1. Explicit lineage: the newer decision supersedes the older one.
        for node in nodes {
            if let newer = node.supersededById { add(newer, node.id, .supersedes) }
            if let older = node.supersedesId { add(node.id, older, .supersedes) }
        }

        // 2. Shared files — bounded fan-out, typed by the pair.
        var byFile: [String: [MemoryNode]] = [:]
        for node in nodes {
            for file in node.data.relatedFiles { byFile[file, default: []].append(node) }
        }
        for group in byFile.values where group.count >= 2 {
            for i in group.indices {
                for j in (i + 1)..<min(group.count, i + 1 + fanout) {
                    let a = group[i], b = group[j]
                    let pair = Set([a.type, b.type])
                    if pair.contains(.concern) {
                        // a concern affects the thing it shares a file with (concern is the source).
                        let concern = a.type == .concern ? a : b
                        let other = a.type == .concern ? b : a
                        add(concern.id, other.id, .affects)
                    } else if pair == Set([.decision, .intent]) {
                        // a decision implements an intent (decision is the source).
                        let decision = a.type == .decision ? a : b
                        let intent = a.type == .decision ? b : a
                        add(decision.id, intent.id, .implements)
                    } else {
                        add(a.id, b.id, .relatedTo)
                    }
                }
            }
        }

        // 3. Same session — a recency chain (not a dense clique).
        var bySession: [String: [MemoryNode]] = [:]
        for node in nodes {
            if let convo = node.conversationId { bySession[convo, default: []].append(node) }
        }
        for group in bySession.values where group.count >= 2 {
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            for i in 1..<ordered.count {
                add(ordered[i - 1].id, ordered[i].id, .relatedTo)
            }
        }

        return Array(edges.values)
    }
}
