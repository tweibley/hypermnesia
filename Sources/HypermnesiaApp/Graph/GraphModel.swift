import SwiftUI
import Observation
import HypermnesiaKit

/// A node in the force simulation.
struct LayoutNode: Identifiable {
    let id: String
    let type: MemoryType
    let decay: DecayLevel
    let title: String
    var position: CGPoint
    var velocity: CGVector = .zero
    var pinned: Bool = false
}

/// Drives a force-directed layout for a project's memories. Ported from the original
/// `ForceDirectedLayout` (`docs/design/05-graph-and-visualization.md`).
@MainActor
@Observable
final class GraphModel {
    private(set) var nodes: [LayoutNode] = []
    private(set) var edges: [MemoryEdge] = []
    var mode: GraphLayoutMode = .constellation
    private(set) var bounds: CGSize = CGSize(width: 800, height: 600)
    private var temperature: CGFloat = 1
    private var indexById: [String: Int] = [:]
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
        if sig == signature && bounds == self.bounds { return }
        signature = sig
        rebuild(memories: memories, mode: mode, bounds: bounds)
    }

    func rebuild(memories: [MemoryNode], mode: GraphLayoutMode, bounds: CGSize) {
        self.mode = mode
        self.bounds = bounds
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let radius = min(bounds.width, bounds.height) * 0.35
        let count = max(memories.count, 1)

        nodes = memories.enumerated().map { i, m in
            let angle = 2 * .pi * CGFloat(i) / CGFloat(count)
            return LayoutNode(
                id: m.id, type: m.type, decay: m.decayLevel, title: m.title,
                position: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            )
        }
        indexById = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let ids = Set(memories.map(\.id))
        edges = GraphBuilder.inferEdges(memories).filter { ids.contains($0.source) && ids.contains($0.target) }
        temperature = 1
    }

    func setMode(_ mode: GraphLayoutMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        temperature = 1
    }

    func reheat() { temperature = 1 }

    func pin(_ id: String, to point: CGPoint) {
        guard let i = indexById[id] else { return }
        nodes[i].position = point
        nodes[i].velocity = .zero
        nodes[i].pinned = true
        temperature = max(temperature, 0.4)
    }
    func unpin(_ id: String) {
        guard let i = indexById[id] else { return }
        nodes[i].pinned = false
    }

    func step() {
        guard temperature >= 0.02, nodes.count > 1 else { return }
        ForceLayout.step(nodes: &nodes, indexById: indexById, edges: edges, mode: mode, bounds: bounds, temperature: temperature)
        temperature *= 0.97
    }

    func position(of id: String) -> CGPoint? {
        indexById[id].map { nodes[$0].position }
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
            if nodes[i].pinned { nodes[i].velocity = .zero; continue }

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

            // Keep inside the bounds.
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
