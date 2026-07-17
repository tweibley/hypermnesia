import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HypermnesiaKit

private enum BrainStreamMode: String, CaseIterable, Identifiable {
    case live
    case replay
    case paused

    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: "Live"
        case .replay: "Replay"
        case .paused: "Pause"
        }
    }
}

private enum PlaybackSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5
    case normal = 1.0
    case double = 2.0

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .half: "0.5x"
        case .normal: "1x"
        case .double: "2x"
        }
    }
}

struct BrainPulse: Identifiable {
    let id = UUID()
    let event: MemoryActivityEvent
    let startedAt: Date
}

struct NeuralNode: Identifiable {
    let id: String
    let point: CGPoint
    let confidence: Double
    let color: Color
    /// Pending review — drawn with a dashed rim so the picture separates "in effect" from "proposed".
    let isDraft: Bool
    /// Superseded/deleted — drawn hollow: part of the anatomy's history, not its live tissue.
    let isGhost: Bool
    /// Fresh memories breathe gently when idle.
    let breathes: Bool
    /// Stable per-node phase for the idle breathing so nodes don't pulse in lockstep.
    let seed: Double
}

/// A labeled functional region of the brain — one per memory type present.
struct BrainRegion: Identifiable {
    let id: String
    let title: String
    let labelPoint: CGPoint
}

private struct TimelineMarker: Identifiable {
    let id: String
    let position: Double
    let tint: Color
}

struct BrainMRIView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isOccluded = false
    @State private var mode: BrainStreamMode = .live
    @State private var hoveredNodeID: String?
    @State private var pinnedNodeID: String?
    @State private var playbackSpeed: PlaybackSpeed = .normal
    @State private var scrubPosition: Double = 1.0
    @State private var isScrubbing = false
    @State private var pulses: [BrainPulse] = []
    @State private var history: [MemoryActivityEvent] = []
    @State private var seenEventIds: Set<String> = []
    @State private var replayIndex = 0
    @State private var latestEvent: MemoryActivityEvent?
    /// In-flight replay-GIF render; the Export menu offers Cancel while this is non-nil.
    @State private var gifExportTask: Task<Void, Never>?
    /// AppKit view behind the export menu — NSSharingServicePicker needs a real anchor.
    @State private var shareAnchorView: NSView?

    private let loopIntervalNs: UInt64 = 700_000_000
    private let pulseLifetime: TimeInterval = 3.8
    private let maxHistory = 1200
    private let maxVisiblePulses = 40

    var body: some View {
        GeometryReader { geo in
            let brain = Self.layoutBrain(in: geo.size, memories: model.memories)
            let edges = GraphBuilder.inferEdges(model.memories)
            let renderPaused = mode == .paused || isOccluded
            VStack(spacing: 0) {
                header
                Divider()
                ZStack {
                    Color.black.opacity(0.06)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            pinnedNodeID = nil
                            hoveredNodeID = nil
                        }
                    TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0, paused: renderPaused)) { timeline in
                        Canvas { ctx, _ in
                            Self.drawBrain(in: &ctx, size: geo.size, now: timeline.date, nodes: brain.nodes,
                                           regions: brain.regions, edges: edges, pulses: pulses,
                                           reduceMotion: reduceMotion, pulseLifetime: pulseLifetime,
                                           highlightedNodeID: focusedMemory?.id)
                        }
                    }
                    .allowsHitTesting(false)
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: renderPaused)) { timeline in
                        pulseLabels(now: timeline.date)
                    }
                    .allowsHitTesting(false)
                    nodeHitTargets(brain.nodes)
                }
                .overlay(alignment: .bottomLeading) {
                    // Clear the scrubber band at the very bottom so neither box ever collides
                    // with it at narrow window widths.
                    legend
                        .padding(.leading, 12)
                        .padding(.bottom, 52)
                }
                .overlay(alignment: .bottomTrailing) {
                    ticker
                        .padding(.trailing, 12)
                        .padding(.bottom, 52)
                }
                .overlay(alignment: .bottom) {
                    timelineScrubber(totalWidth: geo.size.width)
                        .padding(.bottom, 8)
                }
                .overlay(alignment: .topTrailing) {
                    if let memory = focusedMemory {
                        nodeInspector(memory)
                            .padding(12)
                    }
                }
            }
        }
        .task(id: model.selectedProject) {
            await runLoop()
        }
        // Space toggles play/pause; ←/→ step through events one at a time.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            mode = (mode == .paused) ? .live : .paused
            return .handled
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        // A canvas animating behind other windows is pure battery burn — pause when hidden.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window.canBecomeMain else { return }
            isOccluded = !window.occlusionState.contains(.visible)
        }
        .onChange(of: mode) { _, next in
            if next == .replay {
                // Entering replay from the live edge should rewind to the start instead of
                // immediately pausing on the terminal frame.
                if !history.isEmpty, replayIndex(for: scrubPosition) >= history.count - 1 {
                    scrubPosition = 0
                }
                replayIndex = replayIndex(for: scrubPosition)
            }
            if next == .live {
                scrubPosition = 1.0
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Brain MRI", systemImage: "waveform.path.ecg.rectangle")
                .font(.headline)
            Text("Real events only")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.positive)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.positive.opacity(0.16)))
            sparkline
            Spacer()
            HStack(spacing: 6) {
                Text("Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $mode) {
                    ForEach(BrainStreamMode.allCases) { state in
                        Text(state.label).tag(state)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            HStack(spacing: 6) {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $playbackSpeed) {
                    ForEach(PlaybackSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 145)
            }
            Menu {
                Section("Snapshot") {
                    Button("Copy to Clipboard") { copySnapshot() }
                    Button("Share…") { shareSnapshot() }
                    Menu("Export As") {
                        ForEach(ShareCardMetrics.snapshotPresets, id: \.label) { preset in
                            Button(preset.label) { exportSnapshot(preset.metrics) }
                        }
                    }
                }
                Section("Replay") {
                    if gifExportTask != nil {
                        Button("Cancel Render") { gifExportTask?.cancel() }
                    } else {
                        Button("Export GIF…") { exportReplayGIF() }
                            .disabled(history.isEmpty)
                        Button("Share GIF…") { shareReplayGIF() }
                            .disabled(history.isEmpty)
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .background(ShareAnchor { shareAnchorView = $0 })
            .help("Share this brain — copy, share, or export the snapshot and replay")
        }
        .padding(10)
    }

    /// Events per hour over the last 24h — an active day visible at a glance.
    private var sparkline: some View {
        let buckets = hourlyBuckets
        let peak = max(buckets.max() ?? 1, 1)
        return Canvas { ctx, size in
            let barWidth = size.width / 24
            for (index, count) in buckets.enumerated() where count > 0 {
                // Square-root scale: a single burst hour must not flatten the rest of the day
                // into invisibility.
                let fraction = sqrt(CGFloat(count)) / sqrt(CGFloat(peak))
                let height = max(2, size.height * fraction)
                let rect = CGRect(x: CGFloat(index) * barWidth + 0.5, y: size.height - height,
                                  width: barWidth - 1, height: height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(Color.brand.opacity(0.7)))
            }
        }
        .frame(width: 72, height: 16)
        .help("Events per hour, last 24 hours")
    }

    private var hourlyBuckets: [Int] {
        var buckets = Array(repeating: 0, count: 24)
        let now = Date()
        for event in history {
            let age = now.timeIntervalSince(event.timestamp)
            guard age >= 0, age < 86_400 else { continue }
            buckets[23 - Int(age / 3_600)] += 1
        }
        return buckets
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity pulses")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 5) {
                legendItem(.hydrate)
                legendItem(.recall)
                legendItem(.capture)
                legendItem(.applySuccess)
                legendItem(.applyOverride)
                legendItem(.revalidate)
                legendItem(.decayTransition)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 170, height: 1)
            Text("Memory circles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text("Each circle = one memory")
                .foregroundStyle(.secondary)
            Text("Size = confidence  •  Color = freshness/decay")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                nodeSample("Fresh", color: DecayLevel.fresh.color, radius: 6)
                nodeSample("Aging", color: DecayLevel.aging.color, radius: 5)
                nodeSample("Stale", color: DecayLevel.stale.color, radius: 4)
            }
            Text("Dashed = draft  •  Hollow = superseded")
                .foregroundStyle(.secondary)
            Text("Regions group memories by type")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(10)
        .fixedSize(horizontal: true, vertical: false)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var ticker: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let latestEvent {
                Button {
                    if let id = latestEvent.memoryIds.first, let memory = model.memory(id: id) {
                        model.jump(to: memory)
                    }
                } label: {
                    Text(latestEventSummary(latestEvent))
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(latestEvent.memoryIds.isEmpty ? "" : "Open the affected memory")
            } else {
                Text("Waiting for activity…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320, alignment: .trailing)
    }

    private func legendItem(_ type: MemoryActivityEvent.EventType) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(type.tint)
                .frame(width: 7, height: 7)
            Text(type.label)
                .foregroundStyle(.secondary)
        }
    }

    private func nodeSample(_ label: String, color: Color, radius: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: radius * 2, height: radius * 2)
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
            Text(label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func nodeHitTargets(_ nodes: [NeuralNode]) -> some View {
        ZStack {
            ForEach(nodes) { node in
                Circle()
                    .fill(Color.clear)
                    .contentShape(Circle())
                    .frame(width: 44, height: 44)
                    .position(node.point)
                    .onHover { inside in
                        if inside {
                            hoveredNodeID = node.id
                        } else if hoveredNodeID == node.id {
                            hoveredNodeID = nil
                        }
                    }
                    .onTapGesture {
                        pinnedNodeID = (pinnedNodeID == node.id) ? nil : node.id
                        hoveredNodeID = node.id
                    }
                    .help(memory(for: node.id)?.title ?? "Memory")
            }
        }
    }

    private func nodeInspector(_ memory: MemoryNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(memory.decayLevel.color).frame(width: 8, height: 8)
                Text(memory.title).font(.caption.weight(.semibold)).lineLimit(1)
                if pinnedNodeID == memory.id {
                    Text("Pinned")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.belief)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.belief.opacity(0.14)))
                }
            }
            Text(memory.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(memory.type.displayName)
                Text("·")
                Text("Conf \(Int((memory.confidence * 100).rounded()))%")
                Text("·")
                Text(memory.decayLevel.displayName)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack {
                Text(pinnedNodeID == memory.id ? "Click again to unpin" : "Click a node to pin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Open") { model.jump(to: memory) }
                    .controlSize(.mini)
                    .help("Open this memory in the list")
            }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var focusedMemory: MemoryNode? {
        if let pinnedNodeID, let pinned = memory(for: pinnedNodeID) {
            return pinned
        }
        if let hoveredNodeID, let hovered = memory(for: hoveredNodeID) {
            return hovered
        }
        return nil
    }

    private func memory(for id: String) -> MemoryNode? {
        model.memories.first(where: { $0.id == id })
    }

    /// Pure renderer — shared by the live canvas, the PNG snapshot, and replay-GIF frames, so a
    /// share export is pixel-identical to the live picture. Static and nonisolated: everything it
    /// draws arrives as a parameter, so it can run inside any Canvas rendering closure.
    nonisolated static func drawBrain(
        in ctx: inout GraphicsContext,
        size: CGSize,
        now: Date,
        nodes: [NeuralNode],
        regions: [BrainRegion],
        edges: [MemoryEdge],
        pulses: [BrainPulse],
        reduceMotion: Bool,
        pulseLifetime: TimeInterval,
        highlightedNodeID: String?
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let nodeById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        // age >= 0 matters for GIF frames, where pulses are scheduled in the frame's future.
        let active = pulses.filter {
            let age = now.timeIntervalSince($0.startedAt)
            return age >= 0 && age < pulseLifetime
        }

        let ambient = reduceMotion ? 0.5 : CGFloat((sin(now.timeIntervalSinceReferenceDate * 1.4) + 1) / 2)
        let ambientRadius: CGFloat = 58 + ambient * 12
        ctx.fill(Path(ellipseIn: CGRect(
            x: center.x - ambientRadius,
            y: center.y - ambientRadius,
            width: ambientRadius * 2,
            height: ambientRadius * 2
        )), with: .radialGradient(
            Gradient(colors: [Color.brand.opacity(0.24), Color.clear]),
            center: center, startRadius: 0, endRadius: ambientRadius
        ))

        // Functional-region labels: faint anatomy captions around the ring.
        for region in regions {
            ctx.draw(
                Text(region.title).font(.caption2.weight(.medium)).foregroundColor(.secondary.opacity(0.55)),
                at: region.labelPoint, anchor: .center
            )
        }

        // Relationship filaments: the memory graph as faint connective tissue (capped for perf).
        // Chords bow OUTWARD (control point pushed away from the hub) so long cross-brain edges
        // hug the ring instead of hairballing through the center, and fade with length so the
        // short, meaningful within-region links read strongest.
        let maxChord = Double(min(size.width, size.height)) * 0.72
        for edge in edges.prefix(400) {
            guard let from = nodeById[edge.source], let to = nodeById[edge.target] else { continue }
            let mid = CGPoint(x: (from.point.x + to.point.x) / 2, y: (from.point.y + to.point.y) / 2)
            let awayX = mid.x - center.x, awayY = mid.y - center.y
            let awayLen = max(sqrt(awayX * awayX + awayY * awayY), 0.001)
            let chord = Double(hypot(to.point.x - from.point.x, to.point.y - from.point.y))
            let bulge = CGFloat(chord) * 0.22
            let control = CGPoint(x: mid.x + awayX / awayLen * bulge, y: mid.y + awayY / awayLen * bulge)
            var path = Path()
            path.move(to: from.point)
            path.addQuadCurve(to: to.point, control: control)
            let isSupersede = edge.relationship == .supersedes
            let lengthFade = max(0.25, 1.0 - chord / maxChord)
            let base = isSupersede ? 0.12 : 0.06
            ctx.stroke(path, with: .color(.white.opacity(base * lengthFade + (isSupersede ? 0.03 : 0.0))),
                       style: StrokeStyle(lineWidth: 0.7, dash: isSupersede ? [3, 3] : []))
        }

        for pulse in active {
            let age = now.timeIntervalSince(pulse.startedAt)
            let progress = min(1.0, max(0.0, age / pulseLifetime))
            let tint = pulse.event.eventType.tint
            // Keep pulses legible longer; fade more gently near the tail.
            let alpha = pow(1.0 - progress, 0.65)

            // A supersede is a relationship event: a signal travels from the retired memory to its
            // replacement instead of radiating from the center.
            if pulse.event.eventType == .supersede, pulse.event.memoryIds.count >= 2,
               let from = nodeById[pulse.event.memoryIds[0]], let to = nodeById[pulse.event.memoryIds[1]] {
                var path = Path()
                path.move(to: from.point)
                path.addLine(to: to.point)
                ctx.stroke(path, with: .color(tint.opacity(alpha * 0.6)),
                           style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                let travel = reduceMotion ? 1.0 : progress
                let dot = CGPoint(x: from.point.x + (to.point.x - from.point.x) * CGFloat(travel),
                                  y: from.point.y + (to.point.y - from.point.y) * CGFloat(travel))
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)),
                         with: .color(tint.opacity(alpha)))
                continue
            }

            let waveRadius = reduceMotion ? CGFloat(90) : CGFloat(38 + 130 * progress)
            let waveRect = CGRect(
                x: center.x - waveRadius, y: center.y - waveRadius,
                width: waveRadius * 2, height: waveRadius * 2
            )
            ctx.stroke(Path(ellipseIn: waveRect), with: .color(tint.opacity(alpha * 0.42)),
                       style: StrokeStyle(lineWidth: 2))

            for id in pulse.event.memoryIds {
                guard let node = nodeById[id] else { continue }
                var path = Path()
                path.move(to: node.point)
                path.addLine(to: center)
                ctx.stroke(path, with: .color(tint.opacity(alpha * 0.55)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }

        for node in nodes {
            var nodeBoost: Double = 0
            for pulse in active where pulse.event.memoryIds.contains(node.id) {
                let age = now.timeIntervalSince(pulse.startedAt)
                nodeBoost += max(0, 1 - age / pulseLifetime)
            }
            var radius = CGFloat(7 + node.confidence * 11 + min(nodeBoost, 1.3) * 9)
            // Idle breathing: fresh memories respire gently when nothing is firing.
            if !reduceMotion, nodeBoost == 0, node.breathes {
                radius += CGFloat(sin(now.timeIntervalSinceReferenceDate * 1.1 + node.seed * 2 * .pi)) * 1.1
            }
            let rect = CGRect(x: node.point.x - radius, y: node.point.y - radius,
                              width: radius * 2, height: radius * 2)
            let isFocused = highlightedNodeID == node.id
            if node.isGhost {
                // History, not live tissue: hollow, faint, dashed.
                ctx.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(0.08)))
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(node.color.opacity(isFocused ? 0.7 : 0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(node.isDraft ? 0.42 : 0.75)))
                if node.isDraft {
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(isFocused ? 0.85 : 0.4)),
                               style: StrokeStyle(lineWidth: isFocused ? 1.8 : 1.0, dash: [2.5, 2.5]))
                } else {
                    ctx.stroke(
                        Path(ellipseIn: rect),
                        with: .color(isFocused ? .white.opacity(0.85) : .white.opacity(0.10)),
                        lineWidth: isFocused ? 1.8 : 1.0
                    )
                }
            }
        }

        let claudeRadius: CGFloat = 24
        let claudeRect = CGRect(x: center.x - claudeRadius, y: center.y - claudeRadius,
                                width: claudeRadius * 2, height: claudeRadius * 2)
        ctx.fill(Path(ellipseIn: claudeRect), with: .color(Color.brand))
        ctx.stroke(Path(ellipseIn: claudeRect), with: .color(.white.opacity(0.35)),
                   style: StrokeStyle(lineWidth: 1.5))

        let label = Text("Claude")
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white)
        ctx.draw(label, at: center, anchor: .center)
    }

    /// Semantic layout: each memory type present gets an angular sector of the ring — a functional
    /// region, like areas of a cortex — sized by its share of memories (with a floor so small
    /// regions stay labelable). Sector order is fixed by `MemoryType.allCases`, so regions never
    /// swap sides as counts change; within a sector, placement is a stable per-id hash.
    static func layoutBrain(in size: CGSize, memories: [MemoryNode]) -> (nodes: [NeuralNode], regions: [BrainRegion]) {
        guard !memories.isEmpty else { return ([], []) }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseRadius = min(size.width, size.height) * 0.36

        let present: [(type: MemoryType, members: [MemoryNode])] = MemoryType.allCases.compactMap { type in
            let members = memories.filter { $0.type == type }
            return members.isEmpty ? nil : (type, members)
        }
        let total = Double(memories.count)
        let shares = present.map { max(Double($0.members.count) / total, 0.07) }
        let shareSum = shares.reduce(0, +)

        var angleCursor = -Double.pi / 2   // first region starts at 12 o'clock
        var nodes: [NeuralNode] = []
        var regions: [BrainRegion] = []
        for (index, sector) in present.enumerated() {
            let sweep = 2 * Double.pi * (shares[index] / shareSum)
            let padding = min(0.10, sweep * 0.18)
            for memory in sector.members {
                let angle = angleCursor + padding + (sweep - 2 * padding) * normalizedHash(memory.id)
                let radial = baseRadius * CGFloat(0.62 + 0.30 * normalizedHash(memory.id + "|r"))
                nodes.append(NeuralNode(
                    id: memory.id,
                    point: CGPoint(x: center.x + CGFloat(cos(angle)) * radial,
                                   y: center.y + CGFloat(sin(angle)) * radial),
                    confidence: memory.confidence,
                    color: memory.decayLevel.color,
                    isDraft: memory.status == .draft,
                    isGhost: memory.isSuperseded || memory.isDeleted,
                    breathes: memory.decayLevel == .fresh && !memory.isSuperseded,
                    seed: normalizedHash(memory.id + "|s")
                ))
            }
            let mid = angleCursor + sweep / 2
            let labelRadius = baseRadius * 1.14
            regions.append(BrainRegion(
                id: sector.type.rawValue,
                title: sector.type.displayName,
                labelPoint: CGPoint(x: center.x + CGFloat(cos(mid)) * labelRadius,
                                    y: center.y + CGFloat(sin(mid)) * labelRadius)
            ))
            angleCursor += sweep
        }
        return (relaxed(nodes), regions)
    }

    /// A few deterministic push-apart passes so hash placement doesn't stack nodes into unreadable
    /// clumps inside busy regions. Order-stable and randomness-free, so the layout stays identical
    /// across frames for the same memory set.
    private static func relaxed(_ nodes: [NeuralNode]) -> [NeuralNode] {
        guard nodes.count > 1 else { return nodes }
        var points = nodes.map(\.point)
        let minGap: CGFloat = 26
        for _ in 0..<24 {
            var moved = false
            for i in points.indices {
                for j in (i + 1)..<points.count {
                    let dx = points[j].x - points[i].x
                    let dy = points[j].y - points[i].y
                    let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                    guard distance < minGap else { continue }
                    let push = (minGap - distance) / 2
                    // Coincident points get a deterministic separation axis from their indices.
                    let ux = distance < 0.01 ? cos(CGFloat(i + j)) : dx / distance
                    let uy = distance < 0.01 ? sin(CGFloat(i + j)) : dy / distance
                    points[i].x -= ux * push; points[i].y -= uy * push
                    points[j].x += ux * push; points[j].y += uy * push
                    moved = true
                }
            }
            if !moved { break }
        }
        return zip(nodes, points).map { node, point in
            NeuralNode(id: node.id, point: point, confidence: node.confidence, color: node.color,
                       isDraft: node.isDraft, isGhost: node.isGhost,
                       breathes: node.breathes, seed: node.seed)
        }
    }

    private func latestEventSummary(_ event: MemoryActivityEvent) -> String {
        let countText = event.count.map { " \($0)x" } ?? ""
        return "\(event.eventType.label)\(countText) • \(sessionShortLabel(event.sessionId)) • \(event.timestamp.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private func pulseLabels(now: Date) -> some View {
        let active = Array(pulses
            .filter { now.timeIntervalSince($0.startedAt) < pulseLifetime }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(7))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(active.enumerated()), id: \.element.id) { index, pulse in
                if shouldShowSessionSeparator(at: index, in: active) {
                    sessionSeparator(for: pulse.event.sessionId)
                }
                let age = now.timeIntervalSince(pulse.startedAt)
                let alpha = max(0.30, 1 - age / pulseLifetime)
                Text(labelText(for: pulse.event))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(pulse.event.eventType.tint.opacity(alpha))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.18 + 0.20 * alpha))
                    )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    /// Where in time the playhead sits — "Live" at the leading edge, event wall-clock otherwise.
    private var scrubTimestamp: String {
        if mode == .live && scrubPosition >= 1.0 { return "Live" }
        guard !history.isEmpty else { return "—" }
        return history[replayIndex(for: scrubPosition)].timestamp
            .formatted(date: .omitted, time: .shortened)
    }

    private func timelineScrubber(totalWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(scrubTimestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(scrubTimestamp == "Live" ? Color.positive : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)
            scrubberTrack
            if !(mode == .live && scrubPosition >= 1.0) {
                Button {
                    mode = .live
                    scrubPosition = 1.0
                } label: {
                    Image(systemName: "forward.end.fill").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Jump to now")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: min(max(totalWidth - 380, 260), 760))
    }

    private var scrubberTrack: some View {
        let markers = timelineMarkers(maxCount: 90)
        return GeometryReader { geo in
            let usableWidth = max(1, geo.size.width - 10)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 2)
                    .offset(y: 5)

                ForEach(markers) { marker in
                    Circle()
                        .fill(marker.tint.opacity(0.55))
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: CGFloat(marker.position) * usableWidth + 5 - 1.75, y: 4.25)
                }

                Circle()
                    .fill(Color.brand)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    .offset(x: CGFloat(scrubPosition) * usableWidth + 5 - 4.5, y: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isScrubbing = true
                        seekTimeline(x: drag.location.x, width: geo.size.width)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 12)
    }

    private func timelineMarkers(maxCount: Int) -> [TimelineMarker] {
        guard history.count > 1 else { return [] }
        let stride = max(1, history.count / maxCount)
        let denominator = Double(max(history.count - 1, 1))
        return history.enumerated().compactMap { index, event in
            guard index % stride == 0 || index == history.count - 1 else { return nil }
            return TimelineMarker(
                id: event.id,
                position: Double(index) / denominator,
                tint: event.eventType.tint
            )
        }
    }

    private func seekTimeline(x: CGFloat, width: CGFloat) {
        guard !history.isEmpty else { return }
        let usableWidth = max(1, width - 10)
        let progress = min(1.0, max(0.0, Double((x - 5) / usableWidth)))
        scrubPosition = progress
        let index = replayIndex(for: progress)
        replayIndex = index
        let event = history[index]
        latestEvent = event
        pulses = [BrainPulse(event: event, startedAt: Date())]
        mode = .paused
    }

    // MARK: - Share exports

    private var shareProjectName: String {
        model.selectedProject.map(projectDisplayName) ?? "Project memory"
    }

    /// Filesystem-safe artifact name from the project display name.
    private var shareFileSlug: String {
        let name = model.selectedProject.map(projectDisplayName) ?? "hypermnesia"
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch != "-" || !out.hasSuffix("-") { out.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "hypermnesia" : slug
    }

    /// Render the snapshot card at 2x for the given preset — the one code path behind copy,
    /// share, and save.
    @MainActor private func renderSnapshotPNG(metrics: ShareCardMetrics) -> Data? {
        let brain = Self.layoutBrain(in: metrics.canvasSize, memories: model.memories)
        let edges = GraphBuilder.inferEdges(model.memories)
        let content = ShareCardView(
            metrics: metrics,
            stats: ShareStats.compute(projectName: shareProjectName, memories: model.memories, edges: edges),
            nodes: brain.nodes, regions: brain.regions, edges: edges,
            pulses: pulses, pulseLifetime: pulseLifetime, now: Date()
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private func snapshotFilename(_ metrics: ShareCardMetrics) -> String {
        let suffix = metrics.presetName.map { "-\($0)" } ?? ""
        return "\(shareFileSlug)-memory\(suffix).png"
    }

    @MainActor private func copySnapshot() {
        guard let png = renderSnapshotPNG(metrics: .wide) else {
            model.lastActionError = "Couldn't render the snapshot."
            return
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)   // for paste targets that only take TIFF images
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        model.processingStatus = "Snapshot copied to the clipboard."
    }

    @MainActor private func shareSnapshot() {
        guard let png = renderSnapshotPNG(metrics: .wide) else {
            model.lastActionError = "Couldn't render the snapshot."
            return
        }
        guard let url = tempShareURL(snapshotFilename(.wide)), (try? png.write(to: url)) != nil else {
            model.lastActionError = "Couldn't stage the snapshot for sharing."
            return
        }
        presentSharePicker(items: [url])
    }

    @MainActor private func exportSnapshot(_ metrics: ShareCardMetrics) {
        guard let png = renderSnapshotPNG(metrics: metrics) else {
            model.lastActionError = "Couldn't render the snapshot."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = snapshotFilename(metrics)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            model.processingStatus = "Saved snapshot."
        } catch {
            model.lastActionError = "Couldn't save the snapshot: \(error.localizedDescription)"
        }
    }

    @MainActor private func exportReplayGIF() {
        guard !history.isEmpty else {
            model.lastActionError = "No activity to replay yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "\(shareFileSlug)-replay.gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        renderReplayGIF(to: url) { frameCount in
            model.processingStatus = "Saved replay GIF (\(frameCount) frames)."
        }
    }

    @MainActor private func shareReplayGIF() {
        guard let url = tempShareURL("\(shareFileSlug)-replay.gif") else {
            model.lastActionError = "Couldn't stage the replay for sharing."
            return
        }
        renderReplayGIF(to: url) { _ in presentSharePicker(items: [url]) }
    }

    /// Kick off the replay-GIF render — frames on the main actor (ImageRenderer requirement) with
    /// yields so the UI stays alive. `onSuccess` differs per entry point (status message for
    /// saves, share-sheet presentation for shares); cancellation removes the partial file. The
    /// menu swaps to a single Cancel item while `gifExportTask` is non-nil, so renders can't
    /// overlap.
    @MainActor private func renderReplayGIF(to url: URL, onSuccess: @escaping @MainActor (Int) -> Void) {
        let events = Array(history.suffix(24))
        guard !events.isEmpty else {
            model.lastActionError = "No activity to replay yet."
            return
        }
        let metrics = ShareCardMetrics.replay
        let brain = Self.layoutBrain(in: metrics.canvasSize, memories: model.memories)
        let edges = GraphBuilder.inferEdges(model.memories)
        let stats = ShareStats.compute(projectName: shareProjectName, memories: model.memories, edges: edges)
        let stagger: TimeInterval = 0.35
        let fps: Double = 10
        let holdSeconds: TimeInterval = 1.2   // let the finished picture breathe before the loop restarts
        let start = Date()
        let replayPulses = events.enumerated().map { index, event in
            BrainPulse(event: event, startedAt: start.addingTimeInterval(Double(index) * stagger))
        }
        let frameCount = Int((stagger * Double(events.count) + pulseLifetime + holdSeconds) * fps)

        gifExportTask = Task { @MainActor in
            defer { gifExportTask = nil }
            let finished = await ShareGIFWriter.write(
                to: url, frameCount: frameCount, fps: fps, start: start,
                content: { frameNow in
                    ReplayShareView(
                        metrics: metrics, stats: stats,
                        nodes: brain.nodes, regions: brain.regions, edges: edges,
                        pulses: replayPulses, events: events, pulseLifetime: pulseLifetime,
                        start: start, stagger: stagger, now: frameNow
                    )
                },
                progress: { frame, total in
                    model.processingStatus = "Rendering replay GIF… frame \(frame + 1) of \(total)"
                }
            )
            if finished {
                onSuccess(frameCount)
            } else {
                try? FileManager.default.removeItem(at: url)
                if Task.isCancelled {
                    model.processingStatus = "Replay render canceled."
                } else {
                    model.lastActionError = "Couldn't write the GIF."
                }
            }
        }
    }

    /// Stable staging URL for share-sheet items (overwritten per share; cleaned by the OS).
    private func tempShareURL(_ filename: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-share", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return nil }
        return dir.appendingPathComponent(filename)
    }

    @MainActor private func presentSharePicker(items: [Any]) {
        guard let anchor = shareAnchorView, anchor.window != nil else {
            model.lastActionError = "Couldn't present the share sheet."
            return
        }
        NSSharingServicePicker(items: items)
            .show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Step one event backward/forward through history (pauses playback, like frame-stepping video).
    private func step(_ delta: Int) {
        guard !history.isEmpty else { return }
        mode = .paused
        let index = min(max(0, replayIndex(for: scrubPosition) + delta), history.count - 1)
        replayIndex = index
        scrubPosition = history.count > 1 ? Double(index) / Double(history.count - 1) : 1.0
        let event = history[index]
        latestEvent = event
        pulses = [BrainPulse(event: event, startedAt: Date())]
    }

    private func replayIndex(for progress: Double) -> Int {
        guard history.count > 1 else { return 0 }
        let idx = Int((Double(history.count - 1) * progress).rounded())
        return min(max(0, idx), history.count - 1)
    }

    private func shouldShowSessionSeparator(at index: Int, in active: [BrainPulse]) -> Bool {
        guard index > 0 else { return true }
        return active[index].event.sessionId != active[index - 1].event.sessionId
    }

    private func sessionSeparator(for sessionId: String?) -> some View {
        HStack(spacing: 7) {
            Text(sessionShortLabel(sessionId))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func sessionShortLabel(_ sessionId: String?) -> String {
        guard let sessionId, !sessionId.isEmpty else { return "Out-of-session events" }
        return "Session \(String(sessionId.prefix(8)))"
    }

    private func labelText(for event: MemoryActivityEvent) -> String {
        let base = event.eventType.label
        guard let firstId = event.memoryIds.first,
              let first = model.memories.first(where: { $0.id == firstId }) else {
            let countText = event.count.map { " \($0)x" } ?? ""
            return "\(base)\(countText)"
        }
        let suffix = event.memoryIds.count > 1 ? " +\(event.memoryIds.count - 1)" : ""
        return "\(base) • \(first.title)\(suffix)"
    }

    private func runLoop() async {
        await MainActor.run {
            hoveredNodeID = nil
            pinnedNodeID = nil
            pulses = []
            history = []
            seenEventIds = []
            replayIndex = 0
            latestEvent = nil
        }
        while !Task.isCancelled {
            // Hidden window → no polling, no state churn; re-check every 2s for reappearance.
            if await MainActor.run(body: { isOccluded }) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let projectId = await MainActor.run { model.selectedProject }
            guard let projectId else {
                try? await Task.sleep(nanoseconds: loopIntervalNs)
                continue
            }
            let recent = MemoryActivityLog.recent(projectId: projectId, limit: 600)
            await MainActor.run {
                ingest(recent)
                if mode == .replay, !history.isEmpty {
                    let index = min(max(0, replayIndex), history.count - 1)
                    let event = history[index]
                    pulses.append(.init(event: event, startedAt: Date()))
                    if pulses.count > maxVisiblePulses {
                        pulses.removeFirst(pulses.count - maxVisiblePulses)
                    }
                    latestEvent = event
                    scrubPosition = history.count > 1 ? (Double(index) / Double(history.count - 1)) : 1.0
                    if index < history.count - 1 {
                        replayIndex = index + 1
                    } else {
                        mode = .paused
                    }
                }
                if mode == .live, !isScrubbing { scrubPosition = 1.0 }
                let cutoff = Date().addingTimeInterval(-pulseLifetime)
                pulses.removeAll { $0.startedAt < cutoff }
            }
            let sleepNs = await MainActor.run { () -> UInt64 in
                if mode == .replay {
                    let adjusted = Double(loopIntervalNs) / playbackSpeed.rawValue
                    return UInt64(max(120_000_000, adjusted))
                }
                return loopIntervalNs
            }
            try? await Task.sleep(nanoseconds: sleepNs)
        }
    }

    private func ingest(_ events: [MemoryActivityEvent]) {
        var newEvents: [MemoryActivityEvent] = []
        for event in events where !seenEventIds.contains(event.id) {
            seenEventIds.insert(event.id)
            newEvents.append(event)
        }
        guard !newEvents.isEmpty else { return }
        history.append(contentsOf: newEvents)
        history.sort { a, b in
            if a.timestamp == b.timestamp { return a.id < b.id }
            return a.timestamp < b.timestamp
        }
        let overflow = history.count - maxHistory
        if overflow > 0 {
            // Bound seenEventIds to the retained window too — otherwise it grows unbounded over a
            // long-lived menu-bar session. Safe: dedup runs against the 600-event poll, which is
            // always inside the 1200-event history, so dropping older ids can't resurface an event.
            for dropped in history.prefix(overflow) { seenEventIds.remove(dropped.id) }
            history.removeFirst(overflow)
            replayIndex = max(0, replayIndex - overflow)
        }
        if mode == .live {
            latestEvent = history.last
        } else if latestEvent == nil {
            latestEvent = history.last
        }
        if mode == .live, !isScrubbing { scrubPosition = 1.0 }
        if mode == .live {
            for event in newEvents.suffix(maxVisiblePulses) {
                pulses.append(.init(event: event, startedAt: Date()))
            }
            if pulses.count > maxVisiblePulses {
                pulses.removeFirst(pulses.count - maxVisiblePulses)
            }
        }
    }

    private static func normalizedHash(_ text: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let mod = hash % 10_000
        return Double(mod) / 10_000.0
    }
}

/// Invisible AppKit view behind the export menu — `NSSharingServicePicker.show(relativeTo:of:)`
/// needs a real NSView to anchor its popover to.
private struct ShareAnchor: NSViewRepresentable {
    let onReady: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in onReady(view) }   // defer: no state writes during view construction
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension MemoryActivityEvent.EventType {
    var tint: Color {
        switch self {
        case .hydrate, .recall: .belief
        case .capture: .freshness
        case .applySuccess, .revalidate: .positive
        case .applyOverride: .critical
        case .decayTransition: .caution
        case .supersede: .caution
        }
    }

    var label: String {
        switch self {
        case .hydrate: "Inject"
        case .recall: "Recall"
        case .capture: "Capture"
        case .applySuccess: "Apply (survived)"
        case .applyOverride: "Override"
        case .revalidate: "Revalidate"
        case .decayTransition: "Decay transition"
        case .supersede: "Supersede"
        }
    }
}
