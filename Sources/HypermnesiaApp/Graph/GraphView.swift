import SwiftUI
import HypermnesiaKit

/// Night-sky rendering of a project's memory graph. Everything draws into one `Canvas` in screen
/// space (glow, hulls, curved edges, labels); `GraphModel` owns the world-space simulation and this
/// view owns the camera. The camera auto-frames the content until the user pans or zooms.
struct GraphView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var graph = GraphModel()
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    /// Once the user pans/zooms, the camera stops auto-framing until "Reset view".
    @State private var userMovedCamera = false
    @State private var hoveredID: String?
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            canvas
                .gesture(tapGesture)
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoveredID = graph.hitTest(toWorld(p), tolerance: hitTolerance)
                    case .ended: hoveredID = nil
                    }
                }
                .overlay(alignment: .bottomTrailing) { controls }
                .overlay(alignment: .topLeading) { legend }
                .overlay { if graph.nodes.count < 2 { emptyState } }
                .onAppear { graph.rebuildIfNeeded(memories: app.filteredMemories, mode: app.graphLayout, bounds: geo.size) }
                .onChange(of: geo.size) { _, size in graph.rebuildIfNeeded(memories: app.filteredMemories, mode: app.graphLayout, bounds: size) }
                .onChange(of: app.graphLayout) { _, mode in graph.setMode(mode) }
                .onChange(of: app.selectedProject) { _, _ in graph.rebuild(memories: app.filteredMemories, mode: app.graphLayout, bounds: geo.size) }
                .onChange(of: app.filteredMemories.map(\.id)) { _, _ in graph.rebuild(memories: app.filteredMemories, mode: app.graphLayout, bounds: geo.size) }
                .onChange(of: app.selectedMemoryID) { _, id in graph.setFocus(id) }
                .onExitCommand { app.selectedMemoryID = nil }
                .onReceive(ticker) { _ in
                    graph.tick(reduceMotion: reduceMotion)
                    if !userMovedCamera { fitCamera() }
                }
        }
    }

    // MARK: camera

    private var worldCenter: CGPoint { CGPoint(x: graph.world.width / 2, y: graph.world.height / 2) }
    private var viewCenter: CGPoint { CGPoint(x: graph.viewport.width / 2, y: graph.viewport.height / 2) }
    private var hitTolerance: CGFloat { max(6, 12 / zoom) }

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - worldCenter.x) * zoom + viewCenter.x + pan.width,
                y: (p.y - worldCenter.y) * zoom + viewCenter.y + pan.height)
    }
    private func toWorld(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - viewCenter.x - pan.width) / zoom + worldCenter.x,
                y: (s.y - viewCenter.y - pan.height) / zoom + worldCenter.y)
    }

    /// Frame the content bounding box with a comfortable margin.
    private func fitCamera() {
        let content = graph.contentRect
        guard graph.viewport.width > 1, !graph.nodes.isEmpty else { return }
        let margin: CGFloat = 70
        let fit = min((graph.viewport.width - 2 * margin) / content.width,
                      (graph.viewport.height - 2 * margin) / content.height)
        zoom = max(0.3, min(fit, 1.15))
        baseZoom = zoom
        pan = CGSize(width: -(content.midX - worldCenter.x) * zoom,
                     height: -(content.midY - worldCenter.y) * zoom)
        basePan = pan
    }

    // MARK: canvas

    private var canvas: some View {
        Canvas { ctx, size in
            let dark = colorScheme == .dark
            if dark { drawStarfield(ctx, size: size) }
            if graph.mode == .solarSystem { drawOrbits(ctx) }
            if graph.mode == .constellation { drawHulls(ctx) }
            drawEdges(ctx)
            drawNodes(ctx, dark: dark)
            drawLabels(ctx, dark: dark)
        }
    }

    /// Sparse deterministic background stars with a gentle parallax (dark mode only).
    private func drawStarfield(_ ctx: GraphicsContext, size: CGSize) {
        var seed: UInt64 = 0x9E37_79B9
        func rand() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max)
        }
        for _ in 0..<110 {
            let base = CGPoint(x: rand() * size.width, y: rand() * size.height)
            let depth = 0.04 + rand() * 0.06
            var p = CGPoint(x: base.x + pan.width * depth * 2, y: base.y + pan.height * depth * 2)
            p.x = p.x.truncatingRemainder(dividingBy: size.width)
            p.y = p.y.truncatingRemainder(dividingBy: size.height)
            if p.x < 0 { p.x += size.width }
            if p.y < 0 { p.y += size.height }
            let r = 0.6 + rand() * 0.9
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(depth)))
        }
    }

    private func drawOrbits(_ ctx: GraphicsContext) {
        let c = toScreen(worldCenter)
        for i in 1...MemoryType.allCases.count {
            let r = CGFloat(i) * 70 * zoom
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.secondary.opacity(0.10)), lineWidth: 1)
        }
    }

    /// Soft constellation hulls: a fat round-joined stroke over the convex hull reads as a blob.
    private func drawHulls(_ ctx: GraphicsContext) {
        var placedNames: [CGRect] = []
        for cluster in graph.clusters {
            let points = cluster.members.map { toScreen(graph.nodes[$0].position) }
            let hull = GraphView.convexHull(points)
            guard hull.count >= 2 else { continue }
            let alpha = cluster.members.map { graph.nodes[$0].alpha }.max() ?? 1
            var path = Path()
            path.addLines(hull)
            path.closeSubpath()
            let style = StrokeStyle(lineWidth: 88 * zoom, lineCap: .round, lineJoin: .round)
            ctx.stroke(path, with: .color(cluster.color.opacity(0.055 * alpha)), style: style)
            ctx.fill(path, with: .color(cluster.color.opacity(0.055 * alpha)))

            if let name = cluster.name, zoom > 0.4, alpha > 0.5 {
                let top = hull.min { $0.y < $1.y } ?? hull[0]
                let text = ctx.resolve(
                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .kerning(0.8)
                        .foregroundStyle(cluster.color.opacity(0.7 * alpha)))
                let size = text.measure(in: CGSize(width: 300, height: 30))
                let at = CGPoint(x: top.x, y: top.y - 54 * zoom)
                let rect = CGRect(x: at.x - size.width / 2, y: at.y - size.height,
                                  width: size.width, height: size.height).insetBy(dx: -8, dy: -8)
                if placedNames.contains(where: { $0.intersects(rect) }) { continue }
                placedNames.append(rect)
                ctx.draw(text, at: at, anchor: .bottom)
            }
        }
    }

    private func drawEdges(_ ctx: GraphicsContext) {
        let zoomFade = min(1, zoom * 1.3)
        for edge in graph.edges {
            guard let wa = graph.position(of: edge.source), let wb = graph.position(of: edge.target)
            else { continue }
            let a = toScreen(wa), b = toScreen(wb)
            let alpha = graph.edgeAlpha(edge) * zoomFade
            guard alpha > 0.02 else { continue }
            let lineage = edge.relationship != .relatedTo
            let base = (lineage ? 0.42 : 0.22) * alpha

            // A gentle deterministic curve: constellation lines, not circuit traces.
            let dx = b.x - a.x, dy = b.y - a.y
            let sign: CGFloat = (edge.source.hashValue ^ edge.target.hashValue) & 1 == 0 ? 1 : -1
            let control = CGPoint(x: (a.x + b.x) / 2 - dy * 0.07 * sign,
                                  y: (a.y + b.y) / 2 + dx * 0.07 * sign)
            var path = Path()
            path.move(to: a)
            path.addQuadCurve(to: b, control: control)

            let colorA = colorFor(edge.source).opacity(base)
            let colorB = colorFor(edge.target).opacity(base)
            let dash = (edge.relationship.lineDash ?? []).map { CGFloat($0 * 1.6) }
            ctx.stroke(
                path,
                with: .linearGradient(Gradient(colors: [colorA, colorB]), startPoint: a, endPoint: b),
                style: StrokeStyle(lineWidth: lineage ? 1.3 : 1, dash: dash))
            if edge.relationship.hasArrow {
                arrowhead(ctx, from: control, to: b, alpha: base,
                          inset: nodeScreenRadius(edge.target) + 5)
            }
        }
    }

    private func drawNodes(_ ctx: GraphicsContext, dark: Bool) {
        for node in graph.nodes {
            let p = toScreen(node.position)
            let r = node.radius * zoom
            let dim: CGFloat = node.decay == .obsolete ? 0.3
                : (node.decay == .dormant ? 0.55 : (node.decay == .stale ? 0.8 : 1.0))
            let alpha = node.alpha * dim
            guard alpha > 0.02 else { continue }
            let selected = app.selectedMemoryID == node.id
            let hovered = hoveredID == node.id
            let color = node.type.color

            // Twinkle: fresh memories shimmer; everything else glows steadily.
            let twinkle = reduceMotion ? 0
                : node.freshness * 0.30 * (0.5 + 0.5 * sin(graph.time * 1.6 + node.twinklePhase))
            var glow = (0.34 + 0.30 * node.importance + twinkle) * alpha
            if selected || hovered { glow = min(1, glow + 0.30) }
            let glowR = r * (selected ? 3.4 : 2.7)
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: 2 * glowR, height: 2 * glowR)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(glow * (dark ? 0.55 : 0.38)), .clear]),
                    center: p, startRadius: 0, endRadius: glowR))

            // Core shape with a bright center so nodes read as stars, not discs.
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let shape = NodeShape(kind: node.type.nodeShape).path(in: rect)
            ctx.fill(shape, with: .color(color.opacity(alpha)))
            let coreR = r * 0.45
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - coreR, y: p.y - coreR, width: 2 * coreR, height: 2 * coreR)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.85 * alpha), .white.opacity(0)]),
                    center: p, startRadius: 0, endRadius: coreR))
            if selected || hovered {
                ctx.stroke(shape, with: .color(.white.opacity(selected ? 0.95 : 0.55)),
                           lineWidth: selected ? 2 : 1.2)
            }

            // Type glyph appears once the star is big enough to hold it.
            if r >= 10 || selected {
                let glyph = ctx.resolve(
                    Text(Image(systemName: node.type.sfSymbol))
                        .font(.system(size: max(r * 0.72, 8), weight: .bold))
                        .foregroundStyle(.white.opacity(0.92 * alpha)))
                ctx.draw(glyph, at: p)
            }
        }
    }

    private func drawLabels(_ ctx: GraphicsContext, dark: Bool) {
        guard zoom > 0.42 else { return }
        // Selected/hovered first, then by importance; a label that would overlap an
        // already-placed one is dropped, so dense areas stay readable instead of stacking.
        let candidates = graph.nodes
            .filter { node in
                let active = app.selectedMemoryID == node.id || hoveredID == node.id
                return active || (graph.labeledIDs.contains(node.id) && node.alpha > 0.5)
            }
            .sorted { a, b in
                let aActive = app.selectedMemoryID == a.id || hoveredID == a.id
                let bActive = app.selectedMemoryID == b.id || hoveredID == b.id
                if aActive != bActive { return aActive }
                return a.importance > b.importance
            }
        var placed: [CGRect] = []
        for node in candidates {
            let selected = app.selectedMemoryID == node.id
            let hovered = hoveredID == node.id
            let alpha = node.alpha * (node.decay == .obsolete ? 0.5 : 1)
            let p = toScreen(node.position)
            let text = ctx.resolve(
                Text(label(node.title))
                    .font(.system(size: 10, weight: selected || hovered ? .semibold : .regular))
                    .foregroundStyle((dark ? Color.white : .black).opacity((selected || hovered ? 0.95 : 0.72) * alpha)))
            let size = text.measure(in: CGSize(width: 240, height: 40))
            let origin = CGPoint(x: p.x - size.width / 2, y: p.y + node.radius * zoom + 7)
            let bg = CGRect(origin: origin, size: size).insetBy(dx: -5, dy: -2.5)
            let clearance = bg.insetBy(dx: -4, dy: -4)
            if !(selected || hovered), placed.contains(where: { $0.intersects(clearance) }) { continue }
            placed.append(bg)
            ctx.fill(Path(roundedRect: bg, cornerRadius: 5),
                     with: .color((dark ? Color.black : .white).opacity(0.5 * alpha)))
            ctx.draw(text, in: CGRect(origin: origin, size: size))
        }
    }

    private func label(_ title: String) -> String {
        title.count <= 28 ? title : String(title.prefix(27)) + "…"
    }

    private func colorFor(_ id: String) -> Color {
        graph.node(for: id)?.type.color ?? .secondary
    }

    private func nodeScreenRadius(_ id: String) -> CGFloat {
        (graph.node(for: id)?.radius ?? 10) * zoom
    }

    private func arrowhead(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint,
                           alpha: CGFloat, inset: CGFloat) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let tip = CGPoint(x: b.x - cos(angle) * inset, y: b.y - sin(angle) * inset)
        let s: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: tip.x - cos(angle - .pi / 7) * s, y: tip.y - sin(angle - .pi / 7) * s))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - cos(angle + .pi / 7) * s, y: tip.y - sin(angle + .pi / 7) * s))
        ctx.stroke(p, with: .color(.white.opacity(alpha * 1.4)), lineWidth: 1.1)
    }

    /// Andrew's monotone chain; fine for a few hundred points per frame.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return lower.dropLast() + upper.dropLast()
    }

    // MARK: gestures

    private var tapGesture: some Gesture {
        SpatialTapGesture().onEnded { value in
            app.selectedMemoryID = graph.hitTest(toWorld(value.location), tolerance: hitTolerance)
        }
    }
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged {
                userMovedCamera = true
                pan = CGSize(width: basePan.width + $0.translation.width,
                             height: basePan.height + $0.translation.height)
            }
            .onEnded { _ in basePan = pan }
    }
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged {
                userMovedCamera = true
                zoom = max(0.25, min(3, baseZoom * $0.magnification))
            }
            .onEnded { _ in baseZoom = zoom }
    }

    // MARK: overlays

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                userMovedCamera = false
                withAnimation(.spring(duration: 0.4)) { fitCamera() }
            } label: {
                Image(systemName: "scope")
            }.help("Frame the whole graph")
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
