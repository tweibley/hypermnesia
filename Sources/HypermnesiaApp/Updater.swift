import SwiftUI
import Combine
import Sparkle

/// Sparkle auto-update wiring.
///
/// Active only when running from the assembled .app bundle with a configured feed —
/// `SUFeedURL` and `SUPublicEDKey` are stamped into Info.plist by Scripts/release.sh.
/// Dev bundles from Scripts/make-app.sh intentionally omit them, so local builds
/// keep the updater dormant; a bare `swift run` build does too. In both cases the
/// "Check for Updates…" items hide themselves.
///
/// Scheduled background checks use Sparkle's "gentle reminders" hook (the approach
/// Ghostty hand-rolls with a custom user driver): instead of a modal window appearing
/// out of nowhere, a found update only sets `availableUpdateVersion`, which the
/// menu-bar popover renders as a banner. Clicking the banner runs a user-initiated
/// check, which uses Sparkle's standard UI in immediate focus.
@MainActor
final class UpdaterModel: NSObject, ObservableObject {
    static let shared = UpdaterModel()

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false
    /// Set when a *scheduled* check found an update we haven't shown UI for yet.
    @Published private(set) var availableUpdateVersion: String?

    var isAvailable: Bool { controller != nil }

    private override init() {
        super.init()
        let bundle = Bundle.main
        let configured = bundle.bundlePath.hasSuffix(".app")
            && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        guard configured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension UpdaterModel: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never let a scheduled check steal focus with a window — the banner is our reminder.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        Task { @MainActor in
            if !userInitiated { UpdaterModel.shared.availableUpdateVersion = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in UpdaterModel.shared.availableUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in UpdaterModel.shared.availableUpdateVersion = nil }
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
