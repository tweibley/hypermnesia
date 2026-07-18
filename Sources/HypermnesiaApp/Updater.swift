import SwiftUI
import Combine
import Sparkle

/// Sparkle auto-update wiring.
///
/// Active only when running from the assembled .app bundle with a configured feed —
/// `SUFeedURL` and `SUPublicEDKey` are stamped into Info.plist by Scripts/release.sh
/// (and Scripts/make-app.sh). A bare `swift run` build has neither, so the updater
/// stays dormant and the "Check for Updates…" items hide themselves.
@MainActor
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()

    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false

    var isAvailable: Bool { controller != nil }

    private init() {
        let bundle = Bundle.main
        let configured = bundle.bundlePath.hasSuffix(".app")
            && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        guard configured else {
            controller = nil
            return
        }
        // The standard controller: schedules background checks (after asking the user once)
        // and drives the stock Sparkle update UI.
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                     updaterDelegate: nil,
                                                     userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// App-menu item ("Hypermnesia → Check for Updates…"). Hidden when the updater is dormant.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = UpdaterModel.shared

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
