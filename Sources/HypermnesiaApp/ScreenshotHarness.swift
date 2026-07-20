import SwiftUI
import AppKit
import HypermnesiaKit

/// Marketing-screenshot harness: when `HYPERMNESIA_SCREENSHOT_DIR` is set, drive the live main
/// window through each browse mode (plus the Dream Journal sheet), snapshot the window's own view
/// hierarchy at Retina scale into that directory, and exit. Capturing our own hierarchy needs no
/// screen-recording permission and includes the real titlebar/toolbar chrome. Pairs with
/// `HYPERMNESIA_HIDE_PROJECTS` so private repositories never appear in the shots. Inert in normal
/// launches, like the share/notch preview harnesses.
///
///     HYPERMNESIA_HIDE_PROJECTS="secret" HYPERMNESIA_SCREENSHOT_DIR=/tmp/shots \
///         ./Hypermnesia.app/Contents/MacOS/Hypermnesia
enum ScreenshotHarness {
    /// Window size for the shots — 16:10, comfortably above RootView's 820×520 floor.
    private static let shotSize = NSSize(width: 1200, height: 750)

    @MainActor static func runIfRequested(model: AppModel) async {
        guard let dir = ProcessInfo.processInfo.environment["HYPERMNESIA_SCREENSHOT_DIR"],
              !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Let the first data load land and the window settle before resizing it.
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil })
        else { exit(1) }
        var frame = window.frame
        frame.size = shotSize
        window.setFrame(frame, display: true)
        window.center()

        for mode in BrowseMode.allCases {
            model.browseMode = mode
            // Graph/MRI run entrance animations and force-directed layout; give them time to settle.
            try? await Task.sleep(for: .seconds(mode == .graph ? 10 : 3))
            capture(window: window, to: out.appendingPathComponent("app-\(mode.rawValue).png"))
        }

        model.dreamJournalShown = true
        try? await Task.sleep(for: .seconds(2))
        // The sheet is its own window; capture it alone (the journal panel stands on its own).
        if let sheet = window.attachedSheet {
            capture(window: sheet, to: out.appendingPathComponent("app-dreams.png"))
        }
        model.dreamJournalShown = false

        exit(0)
    }

    /// Snapshot the window through the window server — true on-screen pixels (vibrancy, toolbar
    /// chrome, traffic lights), which offscreen `cacheDisplay` can't produce for material views.
    /// Imaging our *own* window needs no screen-recording permission.
    @MainActor private static func capture(window: NSWindow, to url: URL) {
        let id = CGWindowID(window.windowNumber)
        guard let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
        else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
