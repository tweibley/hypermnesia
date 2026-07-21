import Foundation

/// Infers typed edges between a project's memories. The original system's backend returned sparse
/// edges, so the client inferred most relationships from lineage, shared files, and shared sessions
/// (`docs/design/05-graph-and-visualization.md`). This is the local equivalent — pure, bounded, testable.
public enum GraphBuilder {

    /// Derive edges for a set of memory nodes. `fanout` bounds how many same-file links each node
    /// makes, to keep the graph readable. `includeSessionChains` controls the same-session recency
    /// chain (step 3): on large graphs those chronological `relatedTo` links crisscross the
    /// semantic clusters, so dense views pass `false` to show lineage/file structure only.
    public static func inferEdges(
        _ nodes: [MemoryNode], fanout: Int = 3, includeSessionChains: Bool = true
    ) -> [MemoryEdge] {
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
        // Classifier memories may carry absolute paths while codeRefs are repo-relative; fold an
        // absolute key onto the (longest) relative key it ends with so the two still group.
        var relativeKeys: Set<String> = []
        for node in nodes {
            for file in node.data.relatedFiles {
                let key = normalizeFileKey(file)
                if !key.hasPrefix("/") { relativeKeys.insert(key) }
            }
        }
        func canonicalFileKey(_ key: String) -> String {
            guard key.hasPrefix("/") else { return key }
            var best: String?
            for rel in relativeKeys where key.hasSuffix("/" + rel) {
                if best == nil || rel.count > best!.count { best = rel }
            }
            return best ?? key
        }
        var byFile: [String: [MemoryNode]] = [:]
        for node in nodes {
            for file in node.data.relatedFiles {
                byFile[canonicalFileKey(normalizeFileKey(file)), default: []].append(node)
            }
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
                    } else if pair == Set([.intent, .codeRef]) {
                        // an intent is implemented by the codeRef that shares its file.
                        let intent = a.type == .intent ? a : b
                        let codeRef = a.type == .intent ? b : a
                        add(intent.id, codeRef.id, .implementedBy)
                    } else {
                        // decision↔codeRef and other pairs stay related_to (no new edge types).
                        add(a.id, b.id, .relatedTo)
                    }
                }
            }
        }

        // 3. Same session — a recency chain (not a dense clique).
        guard includeSessionChains else { return Array(edges.values) }
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

    /// Normalize path keys so absolute/relative variants of the same file still group.
    /// Case-sensitive; strips a leading `./` only.
    static func normalizeFileKey(_ file: String) -> String {
        var s = file.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        return s
    }
}
