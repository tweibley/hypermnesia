import AppKit
import SwiftUI
import HypermnesiaKit

/// Headless design harness: when `HYPERMNESIA_NOTCH_PREVIEW_DIR` is set, render the notch status
/// panel (notched + capsule variants, single card and full stack) as PNGs into that directory and
/// exit — styling can iterate without hooks, live sessions, or a physical notch. Mirrors
/// `SharePreviewHarness`:
///
///     HYPERMNESIA_NOTCH_PREVIEW_DIR=/tmp/notch-preview swift run HypermnesiaApp
@MainActor
enum NotchPreviewHarness {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["HYPERMNESIA_NOTCH_PREVIEW_DIR"],
              !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let events = SessionEventDemo.events()
        let cards = SessionEventFeed.cards(events: events)
        let working = SessionEventFeed.working(events: events)
        render(cards: Array(cards.prefix(1)), notched: true, name: "notch-1card", to: out)
        render(cards: cards, working: working, notched: true, name: "notch-3cards", to: out)
        render(working: working, notched: true, name: "notch-strip", to: out)
        render(working: working, expanded: true, notched: true, name: "notch-working-expanded", to: out)
        render(cards: cards, working: working, notched: false, name: "capsule-3cards", to: out)
        print("Rendered notch previews to \(out.path)")
        exit(0)
    }

    private static func render(
        cards: [SessionEventFeed.Card] = [], working: [SessionEventFeed.Card] = [],
        expanded: Bool = false, notched: Bool, name: String, to dir: URL
    ) {
        // 14" MacBook Pro-ish notch metrics; the capsule variant needs neither.
        let geometry = NotchGeometry(
            hasNotch: notched, topInset: notched ? 37 : 0, notchWidth: notched ? 200 : 0)
        let view = NotchStatusView(
            cards: cards, workingCards: working, geometry: geometry, visible: true,
            workingExpanded: expanded, onActivate: { _ in }, onDismiss: { _ in })
            .padding(28)                                                // room for the shadow
            .background(Color(red: 0.17, green: 0.25, blue: 0.55))     // wallpaper-ish backdrop
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
