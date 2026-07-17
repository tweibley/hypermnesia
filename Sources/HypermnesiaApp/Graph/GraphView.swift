import SwiftUI
import HypermnesiaKit

struct GraphView: View {
    @Environment(AppModel.self) private var app
    @State private var graph = GraphModel()
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.background.opacity(0.001)).contentShape(Rectangle())  // pan hit area
                edges
                ForEach(graph.nodes) { node in
                    let selected = app.selectedMemoryID == node.id
                    NodeMark(node: node, selected: selected)
                        .position(node.position)
                        .onTapGesture { app.selectedMemoryID = node.id }
                    if zoom > 0.55 || selected {
                        Text(label(node.title))
                            .font(.system(size: 9, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                            .position(x: node.position.x, y: node.position.y + 27)
                            .allowsHitTesting(false)
                    }
                }
            }
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .clipped()
            .overlay(alignment: .bottomTrailing) { controls }
            .overlay(alignment: .topLeading) { legend }
            .overlay { if graph.nodes.count < 2 { emptyState } }
            .onAppear { graph.rebuildIfNeeded(memories: app.filteredMemories, mode: app.graphLayout, bounds: geo.size) }
            .onChange(of: geo.size) { _, size in graph.rebuildIfNeeded(memories: app.filteredMemories, mode: app.graphLayout, bounds: size) }
            .onChange(of: app.graphLayout) { _, mode in graph.setMode(mode) }
            .onChange(of: app.selectedProject) { _, _ in graph.rebuild(memories: app.filteredMemories, mode: app.graphLayout, bounds: geo.size) }
            .onChange(of: app.filteredMemories.map(\.id)) { _, _ in graph.rebuild(memories: app.filteredMemories, mode: app.graphLayout, bounds: geo.size) }
            .onReceive(ticker) { _ in graph.step() }
        }
    }

    // MARK: edges

    private var edges: some View {
        Canvas { ctx, _ in
            for edge in graph.edges {
                guard let a = graph.position(of: edge.source), let b = graph.position(of: edge.target) else { continue }
                var path = Path(); path.move(to: a); path.addLine(to: b)
                let dash = (edge.relationship.lineDash ?? []).map { CGFloat($0) }
                ctx.stroke(path, with: .color(.secondary.opacity(0.30)), style: StrokeStyle(lineWidth: 1, dash: dash))
                if edge.relationship.hasArrow { arrowhead(ctx, from: a, to: b) }
            }
        }
    }

    private func label(_ title: String) -> String {
        title.count <= 22 ? title : String(title.prefix(21)) + "…"
    }

    private func arrowhead(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let tip = CGPoint(x: b.x - cos(angle) * 19, y: b.y - sin(angle) * 19)  // sit just off the node
        let s: CGFloat = 7
        var p = Path()
        p.move(to: CGPoint(x: tip.x - cos(angle - .pi / 7) * s, y: tip.y - sin(angle - .pi / 7) * s))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - cos(angle + .pi / 7) * s, y: tip.y - sin(angle + .pi / 7) * s))
        ctx.stroke(p, with: .color(.secondary.opacity(0.45)), lineWidth: 1.2)
    }

    // MARK: gestures

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { pan = CGSize(width: basePan.width + $0.translation.width, height: basePan.height + $0.translation.height) }
            .onEnded { _ in basePan = pan }
    }
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = max(0.3, min(3, baseZoom * $0.magnification)) }
            .onEnded { _ in baseZoom = zoom }
    }

    // MARK: overlays

    private var controls: some View {
        HStack(spacing: 6) {
            Button { withAnimation { zoom = 1; baseZoom = 1; pan = .zero; basePan = .zero } } label: {
                Image(systemName: "scope")
            }.help("Reset view")
            Button { graph.reheat() } label: { Image(systemName: "arrow.clockwise") }.help("Re-run layout")
        }
        .buttonStyle(.bordered).controlSize(.small).padding(10)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(MemoryType.allCases, id: \.self) { type in
                HStack(spacing: 5) {
                    Circle().fill(type.color).frame(width: 7, height: 7)
                    Text(type.displayName).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
    }

    private var emptyState: some View {
        ContentUnavailableView("Not enough to graph", systemImage: "point.3.connected.trianglepath.dotted",
                               description: Text("Capture or backfill a few memories first."))
    }
}

// MARK: - Node rendering

struct NodeMark: View {
    let node: LayoutNode
    let selected: Bool

    var body: some View {
        let color = node.type.color
        let dim = node.decay == .obsolete ? 0.3 : (node.decay == .dormant ? 0.55 : (node.decay == .stale ? 0.8 : 1.0))
        ZStack {
            NodeShape(kind: node.type.nodeShape)
                .fill(color.opacity(dim))
            NodeShape(kind: node.type.nodeShape)
                .stroke(selected ? Color.white : color.opacity(0.6), lineWidth: selected ? 2.5 : 1)
            Image(systemName: node.type.sfSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .shadow(color: selected ? color.opacity(0.7) : .black.opacity(0.25), radius: selected ? 7 : 2)
        .help(node.title)
    }
}

/// A shape per memory type (hexagon for decisions, triangle for concerns, rounded square for
/// code refs, circle otherwise).
struct NodeShape: Shape {
    let kind: MemoryType.NodeShape

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle: return Circle().path(in: rect)
        case .roundedSquare: return RoundedRectangle(cornerRadius: rect.width * 0.28).path(in: rect)
        case .triangle:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            p.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            p.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
            p.closeSubpath()
            return p
        case .hexagon:
            var p = Path()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 2
                let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }
}
