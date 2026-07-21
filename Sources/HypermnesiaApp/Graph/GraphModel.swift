import SwiftUI
import Observation
import HypermnesiaKit

/// A node in the force simulation.
struct LayoutNode: Identifiable {
    let id: String
    let type: MemoryType
    let decay: DecayLevel
    let title: String
    /// 0…1 blend of connectivity, confidence, and recency — drives size and label priority.
    let importance: CGFloat
    /// Node radius in world units (derived from `importance`).
    let radius: CGFloat
    /// 0…1: how recently this memory was created/validated — drives the twinkle shimmer.
    let freshness: CGFloat
    /// Stable per-node phase so fresh nodes don't all pulse in sync.
    let twinklePhase: CGFloat
    var position: CGPoint
    var velocity: CGVector = .zero
    /// Smoothed focus-mode opacity (eased toward `targetAlpha` each tick).
    var alpha: CGFloat = 1
    var targetAlpha: CGFloat = 1
}

/// A connected component of the graph, rendered as a soft "constellation" hull.
struct GraphCluster: Identifiable {
    let id: Int
    /// Indices into `GraphModel.nodes`.
    let members: [Int]
    let color: Color
    /// Short derived name ("Capture", "Sparkle") — nil when nothing distinctive is shared.
    let name: String?
}

/// Drives a force-directed layout for a project's memories. Ported from the original
/// `ForceDirectedLayout` (`docs/design/05-graph-and-visualization.md`).
///
/// The simulation runs in a *world* larger than the viewport (so dense graphs spread out instead
/// of jamming against the window edges); `GraphView` owns the camera that maps world → screen.
@MainActor
@Observable
final class GraphModel {
    /// Above this many nodes, session-chain edges are dropped and hover-only labels kick in.
    static let denseThreshold = 60

    private(set) var nodes: [LayoutNode] = []
    private(set) var edges: [MemoryEdge] = []
    private(set) var clusters: [GraphCluster] = []
    /// IDs whose labels always show (the most important few); others label on hover/selection.
    private(set) var labeledIDs: Set<String> = []
    var mode: GraphLayoutMode = .constellation
    private(set) var world: CGSize = CGSize(width: 800, height: 600)
    private(set) var viewport: CGSize = CGSize(width: 800, height: 600)
    /// Monotonic time for the twinkle shimmer; only advances while something twinkles.
    private(set) var time: CGFloat = 0
    private var hasFreshNodes = false
    private var focusID: String?
    private var temperature: CGFloat = 1
    private var indexById: [String: Int] = [:]
    private var neighbors: [[Int]] = []
    private var signature: Int = 0   // detect when the memory set actually changed

    func rebuildIfNeeded(memories: [MemoryNode], mode: GraphLayoutMode, bounds: CGSize) {
        // Hash the render-affecting content, not just ids — otherwise an in-place mutation
        // (revalidate changing decay level, an edited title, changed related-files/lineage that move
        // inferred edges) leaves the graph showing stale node attributes and edges.
        var hasher = Hasher()
        for m in memories {
            hasher.combine(m.id)
            hasher.combine(m.decayLevel)
            hasher.combine(m.title)
            hasher.combine(m.supersededById)
            hasher.combine(m.data.relatedFiles)
        }
        hasher.combine(mode)
        let sig = hasher.finalize()
        if sig == signature && bounds == viewport { return }
        signature = sig
        rebuild(memories: memories, mode: mode, bounds: bounds)
    }

    func rebuild(memories: [MemoryNode], mode: GraphLayoutMode, bounds: CGSize) {
        self.mode = mode
        self.viewport = bounds
        // World scales with node count so a dense graph spreads out; the camera frames it.
        let scale = max(1, sqrt(CGFloat(max(memories.count, 1)) / 40))
        world = CGSize(width: max(bounds.width, bounds.width * scale),
                       height: max(bounds.height, bounds.height * scale))
        let center = CGPoint(x: world.width / 2, y: world.height / 2)
        let radius = min(world.width, world.height) * 0.35
        let count = max(memories.count, 1)
        let dense = memories.count > Self.denseThreshold

        let ids = Set(memories.map(\.id))
        edges = GraphBuilder.inferEdges(memories, includeSessionChains: !dense)
            .filter { ids.contains($0.source) && ids.contains($0.target) }

        var degree: [String: Int] = [:]
        for e in edges {
            degree[e.source, default: 0] += 1
            degree[e.target, default: 0] += 1
        }
        let maxDegree = CGFloat(max(degree.values.max() ?? 1, 1))
        let now = Date()

        nodes = memories.enumerated().map { i, m in
            let angle = 2 * .pi * CGFloat(i) / CGFloat(count)
            let recencyAnchor = max(m.createdAt, m.lastValidatedAt ?? .distantPast)
            let days = now.timeIntervalSince(recencyAnchor) / 86_400
            let freshness = CGFloat(max(0, min(1, (10 - days) / 8)))   // 1 within ~2 days → 0 at 10
            let importance = 0.55 * (CGFloat(degree[m.id] ?? 0) / maxDegree)
                + 0.30 * CGFloat(m.confidence)
                + 0.15 * freshness
            return LayoutNode(
                id: m.id, type: m.type, decay: m.decayLevel, title: m.title,
                importance: importance,
                radius: 7 + 9 * importance,
                freshness: freshness,
                twinklePhase: CGFloat(abs(m.id.hashValue % 628)) / 100,
                position: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            )
        }
        indexById = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        hasFreshNodes = nodes.contains { $0.freshness > 0 }

        neighbors = Array(repeating: [], count: nodes.count)
        for e in edges {
            guard let s = indexById[e.source], let t = indexById[e.target] else { continue }
            neighbors[s].append(t)
            neighbors[t].append(s)
        }

        labeledIDs = Set(
            nodes.sorted { $0.importance > $1.importance }.prefix(dense ? 14 : 40).map(\.id))
        clusters = Self.findClusters(memories: memories, nodes: nodes, neighbors: neighbors)
        setFocus(focusID)
        temperature = 1
    }

    func setMode(_ mode: GraphLayoutMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        temperature = 1
    }

    func reheat() { temperature = 1 }

    /// Focus mode: dim everything outside the 2-hop neighborhood of `id`.
    func setFocus(_ id: String?) {
        focusID = id
        guard let id, let start = indexById[id] else {
            for i in nodes.indices { nodes[i].targetAlpha = 1 }
            return
        }
        var hop = Array(repeating: Int.max, count: nodes.count)
        hop[start] = 0
        var frontier = [start]
        for depth in 1...2 {
            var next: [Int] = []
            for i in frontier {
                for j in neighbors[i] where hop[j] == .max {
                    hop[j] = depth
                    next.append(j)
                }
            }
            frontier = next
        }
        for i in nodes.indices {
            nodes[i].targetAlpha = hop[i] == 0 ? 1 : (hop[i] == 1 ? 0.95 : (hop[i] == 2 ? 0.7 : 0.08))
        }
    }

    /// Alpha an edge should render at under the current focus (min of endpoint alphas).
    func edgeAlpha(_ edge: MemoryEdge) -> CGFloat {
        guard let s = indexById[edge.source], let t = indexById[edge.target] else { return 0 }
        return min(nodes[s].alpha, nodes[t].alpha)
    }

    /// One frame: physics while hot, focus-alpha easing while converging, clock while twinkling.
    /// Returns without touching state when fully settled — no state change, no Canvas redraw.
    func tick(reduceMotion: Bool) {
        let hot = temperature >= 0.02 && nodes.count > 1
        let twinkling = hasFreshNodes && !reduceMotion
        let converging = nodes.contains { abs($0.alpha - $0.targetAlpha) > 0.01 }
        guard hot || twinkling || converging else { return }

        if hot {
            ForceLayout.step(nodes: &nodes, indexById: indexById, edges: edges, mode: mode,
                             bounds: world, temperature: temperature)
            temperature *= 0.97
        }
        if converging {
            for i in nodes.indices {
                nodes[i].alpha += (nodes[i].targetAlpha - nodes[i].alpha) * 0.18
            }
        }
        if twinkling { time += 1 / 60 }
    }

    func position(of id: String) -> CGPoint? {
        indexById[id].map { nodes[$0].position }
    }

    func node(for id: String) -> LayoutNode? {
        indexById[id].map { nodes[$0] }
    }

    /// Nearest node within `tolerance` (world units) of a world-space point.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> String? {
        var best: (id: String, d2: CGFloat)?
        for node in nodes {
            let dx = node.position.x - point.x, dy = node.position.y - point.y
            let reach = node.radius + tolerance
            let d2 = dx * dx + dy * dy
            if d2 < reach * reach, best == nil || d2 < best!.d2 { best = (node.id, d2) }
        }
        return best?.id
    }

    /// Bounding box of all nodes (world space), for the camera's fit-to-content.
    var contentRect: CGRect {
        guard let first = nodes.first else {
            return CGRect(origin: .zero, size: world)
        }
        var minX = first.position.x, maxX = minX, minY = first.position.y, maxY = minY
        for node in nodes {
            minX = min(minX, node.position.x); maxX = max(maxX, node.position.x)
            minY = min(minY, node.position.y); maxY = max(maxY, node.position.y)
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    // MARK: clusters

    /// Connected components (≥ 3 members) with a dominant-type color and a cheaply derived name:
    /// the most-shared related-file directory, else the most repeated title word.
    static func findClusters(
        memories: [MemoryNode], nodes: [LayoutNode], neighbors: [[Int]]
    ) -> [GraphCluster] {
        var component = Array(repeating: -1, count: nodes.count)
        var componentCount = 0
        for start in nodes.indices where component[start] == -1 {
            var stack = [start]
            component[start] = componentCount
            while let i = stack.popLast() {
                for j in neighbors[i] where component[j] == -1 {
                    component[j] = componentCount
                    stack.append(j)
                }
            }
            componentCount += 1
        }
        var groups: [Int: [Int]] = [:]
        for (i, c) in component.enumerated() { groups[c, default: []].append(i) }
        let byId = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })

        // A component that swallows most of the graph paints one giant wash over everything —
        // structure comes from the mid-sized constellations, so hull only those.
        let maxHull = max(6, Int(Double(nodes.count) * 0.35))
        var seenNames: Set<String> = []
        return groups.values.filter { $0.count >= 4 && $0.count <= maxHull }
            .sorted { $0.count > $1.count }
            .prefix(12)
            .enumerated()
            .map { clusterIndex, members in
                var typeCounts: [MemoryType: Int] = [:]
                for i in members { typeCounts[nodes[i].type, default: 0] += 1 }
                let dominant = typeCounts.max { $0.value < $1.value }?.key ?? .fact
                let memoryGroup = members.compactMap { byId[nodes[$0].id] }
                var name = clusterName(memoryGroup)
                // The same derived name twice reads as a rendering bug; keep it on the
                // largest cluster only.
                if let n = name, !seenNames.insert(n.lowercased()).inserted { name = nil }
                return GraphCluster(
                    id: clusterIndex, members: members, color: dominant.color, name: name)
            }
    }

    static func clusterName(_ memories: [MemoryNode]) -> String? {
        // 1. The directory the cluster's files most often share.
        var dirCounts: [String: Int] = [:]
        for m in memories {
            for file in Set(m.data.relatedFiles.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
            }) where !file.isEmpty && file != "/" && file != "." {
                dirCounts[file, default: 0] += 1
            }
        }
        if let top = dirCounts.max(by: { $0.value < $1.value }), top.value >= 3 { return top.key }

        // 2. The word the cluster's titles most repeat (case-preserving, stopwords dropped).
        let stop: Set<String> = ["the", "and", "for", "with", "not", "must", "use", "when", "from",
                                 "are", "all", "via", "into", "over", "only", "app", "new"]
        var wordCounts: [String: (display: String, count: Int)] = [:]
        for m in memories {
            let words = m.title.split { !$0.isLetter && !$0.isNumber }
            for word in Set(words.map(String.init)) where word.count >= 4 {
                let key = word.lowercased()
                guard !stop.contains(key) else { continue }
                wordCounts[key, default: (word, 0)].count += 1
            }
        }
        // Demand real consensus from titles — a word shared by a third of a big cluster,
        // not any three coincidental repeats.
        let needed = max(3, memories.count / 3)
        if let top = wordCounts.values.max(by: { $0.count < $1.count }), top.count >= needed {
            return top.display
        }
        return nil
    }
}

/// One step of the force simulation (repulsion + edge attraction + gravity + mode constraints).
enum ForceLayout {
    static let repulsion: CGFloat = 14000
    static let attraction: CGFloat = 0.0045
    static let gravity: CGFloat = 0.0016
    static let friction: CGFloat = 0.85
    static let idealDistance: CGFloat = 150
    static let maxVelocity: CGFloat = 28

    static func step(
        nodes: inout [LayoutNode], indexById: [String: Int], edges: [MemoryEdge],
        mode: GraphLayoutMode, bounds: CGSize, temperature t: CGFloat
    ) {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let count = nodes.count

        // Repulsion between every pair.
        for i in 0..<count {
            for j in 0..<count where i != j {
                var dx = nodes[i].position.x - nodes[j].position.x
                var dy = nodes[i].position.y - nodes[j].position.y
                if dx == 0 && dy == 0 {
                    // Exactly coincident (e.g. two nodes clamped to the same bound): (dx/d, dy/d) would
                    // be (0,0) and they'd stay stacked forever. Nudge along a per-pair angle so
                    // repulsion can separate them.
                    let angle = CGFloat(i &* 31 &+ j) * 0.7
                    dx = cos(angle) * 0.01
                    dy = sin(angle) * 0.01
                }
                let d2 = max(dx * dx + dy * dy, 400)
                let d = sqrt(d2)
                let force = (repulsion / d2) * t * (d < idealDistance ? 2 : 1)
                nodes[i].velocity.dx += (dx / d) * force
                nodes[i].velocity.dy += (dy / d) * force
            }
        }

        // Attraction along edges.
        for edge in edges {
            guard let s = indexById[edge.source], let e = indexById[edge.target] else { continue }
            let dx = nodes[e].position.x - nodes[s].position.x
            let dy = nodes[e].position.y - nodes[s].position.y
            let f = attraction * t
            nodes[s].velocity.dx += dx * f; nodes[s].velocity.dy += dy * f
            nodes[e].velocity.dx -= dx * f; nodes[e].velocity.dy -= dy * f
        }

        let clusters = mode == .hybridCluster ? clusterCenters(center: center, bounds: bounds) : [:]

        for i in 0..<count {
            // Gentle gravity toward the center.
            nodes[i].velocity.dx += (center.x - nodes[i].position.x) * gravity
            nodes[i].velocity.dy += (center.y - nodes[i].position.y) * gravity

            switch mode {
            case .constellation:
                break
            case .solarSystem:
                let orbit = CGFloat(nodes[i].type.index + 1) * 70
                let dx = nodes[i].position.x - center.x, dy = nodes[i].position.y - center.y
                let cur = sqrt(dx * dx + dy * dy)
                if cur > 0 {
                    let of = (orbit - cur) * 0.03 * t
                    nodes[i].velocity.dx += (dx / cur) * of
                    nodes[i].velocity.dy += (dy / cur) * of
                }
            case .hybridCluster:
                if let target = clusters[nodes[i].type] {
                    nodes[i].velocity.dx += (target.x - nodes[i].position.x) * 0.02 * t
                    nodes[i].velocity.dy += (target.y - nodes[i].position.y) * 0.02 * t
                }
            }

            // Cap velocity.
            let v = sqrt(nodes[i].velocity.dx * nodes[i].velocity.dx + nodes[i].velocity.dy * nodes[i].velocity.dy)
            if v > maxVelocity {
                let scale = maxVelocity / v
                nodes[i].velocity.dx *= scale; nodes[i].velocity.dy *= scale
            }

            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy

            // Keep inside the world.
            let pad: CGFloat = 44
            if nodes[i].position.x < pad { nodes[i].position.x = pad; nodes[i].velocity.dx *= -0.5 }
            else if nodes[i].position.x > bounds.width - pad { nodes[i].position.x = bounds.width - pad; nodes[i].velocity.dx *= -0.5 }
            if nodes[i].position.y < pad { nodes[i].position.y = pad; nodes[i].velocity.dy *= -0.5 }
            else if nodes[i].position.y > bounds.height - pad { nodes[i].position.y = bounds.height - pad; nodes[i].velocity.dy *= -0.5 }

            nodes[i].velocity.dx *= friction
            nodes[i].velocity.dy *= friction
        }
    }

    static func clusterCenters(center: CGPoint, bounds: CGSize) -> [MemoryType: CGPoint] {
        let radius = min(bounds.width, bounds.height) * 0.30
        let types = MemoryType.allCases
        var centers: [MemoryType: CGPoint] = [:]
        for (i, type) in types.enumerated() {
            let angle = 2 * .pi * CGFloat(i) / CGFloat(types.count)
            centers[type] = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        return centers
    }
}
