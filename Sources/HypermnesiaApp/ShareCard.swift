import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HypermnesiaKit

/// Share exports are the one surface strangers see, so they carry their own chrome: a wordmark
/// header, an MRI-style backdrop, and a band of corpus stats. Everything textual here is a *number*
/// or a type name — memory titles and content never enter an image artifact, because images travel
/// further than the person who exported them intended (the digest document is the deliberate,
/// content-carrying artifact).

/// Writes an animated GIF by rendering a view per frame timestamp. Frames render on the main actor
/// (ImageRenderer requirement) with periodic yields so the UI stays alive during long exports.
enum ShareGIFWriter {
    @MainActor static func write<Content: View>(
        to url: URL,
        frameCount: Int,
        fps: Double,
        start: Date,
        content: (Date) -> Content,
        progress: ((_ frame: Int, _ total: Int) -> Void)? = nil
    ) async -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { return false }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
        ] as CFDictionary
        for frame in 0..<frameCount {
            if Task.isCancelled { return false }
            let renderer = ImageRenderer(content: content(start.addingTimeInterval(Double(frame) / fps)))
            if let cgImage = renderer.cgImage {
                CGImageDestinationAddImage(destination, cgImage, frameProperties)
            }
            if frame % 10 == 0 {
                progress?(frame, frameCount)
                await Task.yield()
            }
        }
        return CGImageDestinationFinalize(destination)
    }
}

/// Fixed export geometry. Header and footer bands are reserved up front so the brain layout —
/// computed for `canvasSize`, not the full card — never collides with the chrome.
struct ShareCardMetrics {
    let size: CGSize
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    /// Filename suffix and menu label for snapshot presets (nil for the default wide card).
    let presetName: String?

    init(size: CGSize, headerHeight: CGFloat, footerHeight: CGFloat, presetName: String? = nil) {
        self.size = size
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.presetName = presetName
    }

    var canvasSize: CGSize {
        CGSize(width: size.width, height: size.height - headerHeight - footerHeight)
    }

    /// Narrow cards wrap the stats band into stacked rows instead of one long strip.
    var isCompact: Bool { size.width < 1280 }

    static let wide = ShareCardMetrics(
        size: CGSize(width: 1600, height: 1000), headerHeight: 132, footerHeight: 172)
    static let landscape = ShareCardMetrics(
        size: CGSize(width: 1600, height: 900), headerHeight: 128, footerHeight: 168,
        presetName: "landscape")
    static let square = ShareCardMetrics(
        size: CGSize(width: 1200, height: 1200), headerHeight: 132, footerHeight: 228,
        presetName: "square")
    static let story = ShareCardMetrics(
        size: CGSize(width: 1080, height: 1920), headerHeight: 150, footerHeight: 250,
        presetName: "story")
    static let replay = ShareCardMetrics(
        size: CGSize(width: 1280, height: 800), headerHeight: 112, footerHeight: 152)

    /// Snapshot presets in menu order.
    static let snapshotPresets: [(label: String, metrics: ShareCardMetrics)] = [
        ("Wide (1600×1000)", .wide),
        ("Landscape 16:9", .landscape),
        ("Square", .square),
        ("Story 9:16", .story),
    ]
}

// MARK: - Still snapshot

/// The PNG share card: backdrop, header, live brain render, stats band.
struct ShareCardView: View {
    let metrics: ShareCardMetrics
    let stats: ShareStats
    let nodes: [NeuralNode]
    let regions: [BrainRegion]
    let edges: [MemoryEdge]
    let pulses: [BrainPulse]
    let pulseLifetime: TimeInterval
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            ShareHeader(
                projectName: stats.projectName,
                subtitle: "Project memory · \(now.formatted(date: .abbreviated, time: .omitted))"
            )
            .frame(height: metrics.headerHeight, alignment: .topLeading)
            shareBrainCanvas(
                nodes: nodes, regions: regions, edges: edges, pulses: pulses,
                pulseLifetime: pulseLifetime, now: now
            )
            .frame(width: metrics.canvasSize.width, height: metrics.canvasSize.height)
            ShareStatsBand(stats: stats, compact: metrics.isCompact)
                .frame(height: metrics.footerHeight, alignment: .bottomLeading)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .background(ShareBackdrop(size: metrics.size))
        // Offscreen rendering resolves adaptive colors (`.secondary` region labels) for the app's
        // scheme; the backdrop is committed dark, so pin the scheme or the labels vanish.
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Animated replay

/// One frame of the replay GIF: the brain firing plus the story layer — accumulating per-type
/// counters, the current event with its real wall-clock time, and a progress track whose markers
/// are the events themselves.
struct ReplayShareView: View {
    let metrics: ShareCardMetrics
    let stats: ShareStats
    let nodes: [NeuralNode]
    let regions: [BrainRegion]
    let edges: [MemoryEdge]
    /// Synthetic pulses: real events re-timed onto the GIF clock (start + index × stagger).
    let pulses: [BrainPulse]
    /// The same events in the same chronological order as `pulses`.
    let events: [MemoryActivityEvent]
    let pulseLifetime: TimeInterval
    let start: Date
    let stagger: TimeInterval
    let now: Date

    /// The animated span (hold frames beyond it clamp the playhead at the end).
    private var totalDuration: TimeInterval {
        stagger * Double(events.count) + pulseLifetime
    }

    private var firedCount: Int {
        min(events.count, max(0, Int(now.timeIntervalSince(start) / stagger) + 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            ShareHeader(projectName: stats.projectName, subtitle: replaySubtitle)
                .frame(height: metrics.headerHeight, alignment: .topLeading)
            shareBrainCanvas(
                nodes: nodes, regions: regions, edges: edges, pulses: pulses,
                pulseLifetime: pulseLifetime, now: now
            )
            .frame(width: metrics.canvasSize.width, height: metrics.canvasSize.height)
            replayBand
                .frame(height: metrics.footerHeight, alignment: .bottomLeading)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .background(ShareBackdrop(size: metrics.size))
        .environment(\.colorScheme, .dark)   // committed-dark artifact; see ShareCardView
    }

    private var replaySubtitle: String {
        var parts = ["Activity replay"]
        if let first = events.first?.timestamp, let last = events.last?.timestamp {
            let from = first.formatted(date: .abbreviated, time: .omitted)
            let to = last.formatted(date: .abbreviated, time: .omitted)
            parts.append(from == to ? from : "\(from) – \(to)")
        }
        parts.append("\(events.count) events")
        return parts.joined(separator: " · ")
    }

    private var replayBand: some View {
        let fired = Array(events.prefix(firedCount))
        let firedByType = Dictionary(grouping: fired, by: \.eventType).mapValues(\.count)
        let presentTypes = MemoryActivityEvent.EventType.allCases.filter { type in
            events.contains { $0.eventType == type }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                // Every chip is present from frame one (dimmed at ×0) so the layout never jumps
                // as counts arrive — GIFs amplify reflow into flicker.
                HStack(spacing: 14) {
                    ForEach(presentTypes, id: \.self) { type in
                        counterChip(type, count: firedByType[type] ?? 0)
                    }
                }
                Spacer()
                if let current = fired.last {
                    Text("\(current.eventType.label) · \(current.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(current.eventType.tint)
                        .lineLimit(1)
                }
            }
            progressTrack
            HStack(alignment: .firstTextBaseline) {
                Text("\(stats.memoryCount) memories · \(Int((stats.healthyShare * 100).rounded()))% healthy")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                ShareTagline()
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 24)
    }

    private func counterChip(_ type: MemoryActivityEvent.EventType, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(type.tint).frame(width: 7, height: 7)
            Text("\(type.label) ×\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .monospacedDigit()
        }
        .opacity(count == 0 ? 0.35 : 1)
    }

    private var progressTrack: some View {
        let width = metrics.size.width - 72
        let playhead = min(1.0, max(0.0, now.timeIntervalSince(start) / totalDuration))
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.12)).frame(width: width, height: 3)
            Capsule().fill(Color.brand.opacity(0.55))
                .frame(width: max(3, width * CGFloat(playhead)), height: 3)
            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                let position = stagger * Double(index) / totalDuration
                Circle()
                    .fill(event.eventType.tint.opacity(index < firedCount ? 0.9 : 0.35))
                    .frame(width: 5, height: 5)
                    .offset(x: width * CGFloat(position) - 2.5)
            }
            Circle()
                .fill(Color.brandBright)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                .offset(x: width * CGFloat(playhead) - 4.5)
        }
        .frame(width: width, height: 9)
    }
}

// MARK: - Shared chrome

private struct ShareHeader: View {
    let projectName: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brandBright)
                    Text("HYPERMNESIA")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(4.5)
                        .foregroundStyle(Color.brandBright.opacity(0.92))
                }
                Text(projectName)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
    }
}

private struct ShareStatsBand: View {
    let stats: ShareStats
    /// Narrow cards (square/story) wrap chips and the type row into stacked rows; wide cards run
    /// one strip. Chunk sizes are fixed so the layout is deterministic, not squeeze-dependent.
    let compact: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(chipValues.chunked(into: compact ? 3 : .max).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, chip in
                            statChip(chip.value, chip.label)
                        }
                    }
                }
                ForEach(Array(stats.typeCounts.chunked(into: compact ? 4 : .max).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row, id: \.type) { entry in
                            HStack(spacing: 6) {
                                Circle().fill(entry.type.color).frame(width: 7, height: 7)
                                Text(entry.type.counted(entry.count))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.62))
                            }
                        }
                    }
                }
            }
            Spacer()
            ShareTagline()
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 26)
    }

    private var chipValues: [(value: String, label: String)] {
        var chips: [(String, String)] = [("\(stats.memoryCount)", "confirmed memories")]
        if stats.memoryCount > 0 {
            chips.append(("\(Int((stats.healthyShare * 100).rounded()))%", "healthy"))
        }
        if stats.appliedCount > 0 { chips.append(("\(stats.appliedCount)×", "applied")) }
        if stats.sessionCount > 0 {
            chips.append(("\(stats.sessionCount)", stats.sessionCount == 1 ? "session" : "sessions"))
        }
        if stats.connectionCount > 0 {
            chips.append(("\(stats.connectionCount)", stats.connectionCount == 1 ? "connection" : "connections"))
        }
        if let days = stats.memoryAgeDays {
            chips.append(("\(days)", days == 1 ? "day of memory" : "days of memory"))
        }
        return chips
    }

    private func statChip(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private extension Array {
    /// Fixed-size rows for deterministic band layout (`.max` → everything on one row).
    func chunked(into size: Int) -> [[Element]] {
        guard size < count else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

private struct ShareTagline: View {
    var body: some View {
        Text("Durable, decaying memory for your coding agents")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.40))
    }
}

/// Deep-space gradient with a brand glow behind the brain and a corner vignette. Committed colors
/// (never theme-dependent) so the artifact looks right wherever it lands.
private struct ShareBackdrop: View {
    let size: CGSize

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.045, green: 0.04, blue: 0.085), Color(red: 0.08, green: 0.065, blue: 0.13)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Color.brand.opacity(0.15), .clear],
                center: .center, startRadius: 0, endRadius: min(size.width, size.height) * 0.55)
            RadialGradient(
                colors: [.clear, .black.opacity(0.32)],
                center: .center,
                startRadius: min(size.width, size.height) * 0.45,
                endRadius: hypot(size.width, size.height) / 2)
        }
    }
}

/// The brain render inside share chrome: faint scanner rings + tick marks (the MRI motif) drawn
/// beneath the same pure `drawBrain` the live canvas uses, so the export is pixel-identical tissue.
private func shareBrainCanvas(
    nodes: [NeuralNode],
    regions: [BrainRegion],
    edges: [MemoryEdge],
    pulses: [BrainPulse],
    pulseLifetime: TimeInterval,
    now: Date
) -> some View {
    Canvas { ctx, size in
        drawScannerRings(in: &ctx, size: size)
        BrainMRIView.drawBrain(
            in: &ctx, size: size, now: now, nodes: nodes, regions: regions, edges: edges,
            pulses: pulses, reduceMotion: false, pulseLifetime: pulseLifetime, highlightedNodeID: nil)
    }
}

private func drawScannerRings(in ctx: inout GraphicsContext, size: CGSize) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let unit = min(size.width, size.height)
    for (index, factor) in [0.30, 0.42, 0.54].enumerated() {
        let radius = unit * factor
        ctx.stroke(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .color(.white.opacity(0.05 - Double(index) * 0.012)), lineWidth: 1)
    }
    let outer = unit * 0.54
    for degree in stride(from: 0, to: 360, by: 15) {
        let angle = Double(degree) * .pi / 180
        var tick = Path()
        tick.move(to: CGPoint(x: center.x + cos(angle) * (outer - 5), y: center.y + sin(angle) * (outer - 5)))
        tick.addLine(to: CGPoint(x: center.x + cos(angle) * (outer + 5), y: center.y + sin(angle) * (outer + 5)))
        ctx.stroke(tick, with: .color(.white.opacity(0.07)), lineWidth: 1)
    }
}
