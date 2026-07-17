import SwiftUI
import AppKit
import HypermnesiaKit

/// Headless design harness: when `HYPERMNESIA_SHARE_PREVIEW_DIR` is set, render every share
/// artifact from sample data into that directory and exit — so the share-card design can be
/// reviewed and iterated without driving the app by hand. Inert in normal launches.
///
///     HYPERMNESIA_SHARE_PREVIEW_DIR=/tmp/share-preview swift run HypermnesiaApp
///
/// Emits: share-card.png (2x snapshot), replay-{start,mid,end}.png (key GIF frames), replay.gif,
/// and MEMORY.md (the digest), all from `SampleMemories`.
enum SharePreviewHarness {
    /// Matches BrainMRIView's pulse lifetime so preview timing mirrors real exports.
    private static let pulseLifetime: TimeInterval = 3.8

    @MainActor static func runIfRequested() async {
        guard let dir = ProcessInfo.processInfo.environment["HYPERMNESIA_SHARE_PREVIEW_DIR"],
              !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let now = Date()
        let memories = SampleMemories.make(now: now)
        let edges = GraphBuilder.inferEdges(memories)
        let stats = ShareStats.compute(projectName: "acme/widgets", memories: memories, edges: edges)
        let events = sampleEvents(memories: memories, now: now)

        // Still cards — every preset, with a few in-flight pulses so the snapshots show firing
        // tissue. Narrow presets exercise the compact stats-band layout.
        let livePulses = events.suffix(3).map { BrainPulse(event: $0, startedAt: now.addingTimeInterval(-0.9)) }
        for metrics in ShareCardMetrics.snapshotPresets.map(\.metrics) {
            let brain = BrainMRIView.layoutBrain(in: metrics.canvasSize, memories: memories)
            writePNG(
                ShareCardView(metrics: metrics, stats: stats, nodes: brain.nodes, regions: brain.regions,
                              edges: edges, pulses: livePulses, pulseLifetime: pulseLifetime, now: now),
                scale: 2, to: out.appendingPathComponent("share-card-\(metrics.presetName ?? "wide").png"))
        }

        // GitHub social-preview card: 2:1, the ratio repo settings crops to. Harness-only —
        // not a menu preset, since it exists solely to be uploaded once per repo.
        let social = ShareCardMetrics(
            size: CGSize(width: 1280, height: 640), headerHeight: 126, footerHeight: 114,
            presetName: "social")
        let socialBrain = BrainMRIView.layoutBrain(in: social.canvasSize, memories: memories)
        writePNG(
            ShareCardView(metrics: social, stats: stats, nodes: socialBrain.nodes,
                          regions: socialBrain.regions, edges: edges, pulses: livePulses,
                          pulseLifetime: pulseLifetime, now: now),
            scale: 2, to: out.appendingPathComponent("share-card-social.png"))

        // Replay: key frames as PNGs for close inspection, plus the real GIF.
        let replayMetrics = ShareCardMetrics.replay
        let replayBrain = BrainMRIView.layoutBrain(in: replayMetrics.canvasSize, memories: memories)
        let stagger: TimeInterval = 0.35
        let fps: Double = 10
        let holdSeconds: TimeInterval = 1.2
        let replayPulses = events.enumerated().map { index, event in
            BrainPulse(event: event, startedAt: now.addingTimeInterval(Double(index) * stagger))
        }
        func frame(_ offset: TimeInterval) -> ReplayShareView {
            ReplayShareView(
                metrics: replayMetrics, stats: stats, nodes: replayBrain.nodes,
                regions: replayBrain.regions, edges: edges, pulses: replayPulses, events: events,
                pulseLifetime: pulseLifetime, start: now, stagger: stagger,
                now: now.addingTimeInterval(offset))
        }
        let animated = stagger * Double(events.count) + pulseLifetime
        writePNG(frame(0.05), scale: 1, to: out.appendingPathComponent("replay-start.png"))
        writePNG(frame(stagger * Double(events.count) * 0.5), scale: 1, to: out.appendingPathComponent("replay-mid.png"))
        writePNG(frame(animated + 0.5), scale: 1, to: out.appendingPathComponent("replay-end.png"))
        let frameCount = Int((animated + holdSeconds) * fps)
        _ = await ShareGIFWriter.write(
            to: out.appendingPathComponent("replay.gif"),
            frameCount: frameCount, fps: fps, start: now, content: { frame($0.timeIntervalSince(now)) })

        // The digest, for eyeballing alongside the images.
        let digest = MemoryMarkdown.projectDigest(projectId: "github.com/acme/widgets", nodes: memories)
        try? Data(digest.utf8).write(to: out.appendingPathComponent("MEMORY.md"))

        print("Share previews written to \(out.path)")
        exit(0)
    }

    @MainActor private static func writePNG(_ view: some View, scale: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// A believable event tape: mostly recalls with captures, applies, and the odd override,
    /// spread over ~30 hours so the replay's date range and timestamps look real.
    private static func sampleEvents(memories: [MemoryNode], now: Date) -> [MemoryActivityEvent] {
        let ids = memories.map(\.id)
        let types: [MemoryActivityEvent.EventType] = [
            .hydrate, .recall, .recall, .capture, .applySuccess, .recall, .capture,
            .applySuccess, .applyOverride, .recall, .revalidate, .capture, .recall,
            .applySuccess, .decayTransition, .recall, .capture, .recall, .applySuccess, .recall,
        ]
        return types.enumerated().map { index, type in
            MemoryActivityEvent(
                timestamp: now.addingTimeInterval(Double(index - types.count) * 5_400),
                projectId: "github.com/acme/widgets",
                sessionId: "sample-session",
                eventType: type,
                memoryIds: [ids[index % ids.count]]
            )
        }
    }
}
