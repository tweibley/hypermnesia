import SwiftUI
import AppKit
import UserNotifications
import HypermnesiaKit

@main
struct HypermnesiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Hypermnesia", id: "main") {
            RootView()
                .environment(model)
                .tint(.brand)
                .onAppear { WindowSupport.bringToFront() }
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { model.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Quick Open…") { model.quickOpenShown = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("List") { model.browseMode = .list }.keyboardShortcut("1", modifiers: .command)
                Button("Graph") { model.browseMode = .graph }.keyboardShortcut("2", modifiers: .command)
                Button("Health") { model.browseMode = .health }.keyboardShortcut("3", modifiers: .command)
                Button("Trends") { model.browseMode = .trends }.keyboardShortcut("4", modifiers: .command)
                Button("MRI") { model.browseMode = .mri }.keyboardShortcut("5", modifiers: .command)
                Button("Feed") { model.browseMode = .feed }.keyboardShortcut("6", modifiers: .command)
                Divider()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .tint(.brand)
        } label: {
            // The count is the "your agent learned something — come review it" nudge.
            if model.totalDraftCount > 0 {
                Label("\(model.totalDraftCount)", systemImage: "brain")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "brain")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .tint(.brand)
        }
    }
}

/// Ensures the app can show and focus a window even when run as a bare SwiftPM executable (no
/// bundle). Without this the main window opens behind the terminal and never comes forward.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless notch-panel rendering (design iteration); exits the process when requested.
        NotchPreviewHarness.runIfRequested()
        // Headless share-artifact rendering (design iteration); exits the process when requested.
        Task { @MainActor in await SharePreviewHarness.runIfRequested() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        WindowSupport.bringToFront()
        // Live session status at the notch (skipped in the headless share-render harness).
        if ProcessInfo.processInfo.environment["HYPERMNESIA_SHARE_PREVIEW_DIR"] == nil {
            NotchStatusController.shared.start()
        }
        // Keep `hypermnesia` working in Terminal for downloaded installs: the CLI ships inside
        // the bundle, so symlink it into ~/.local/bin on every launch. Refreshing each launch
        // also re-points the link after an update or an app move (a stale target would break
        // every documented `hypermnesia install-…` command). Skips user-managed installs.
        if Bundle.main.bundlePath.hasSuffix(".app"),
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("hypermnesia").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            try? CLIToolInstaller.install(bundledPath: bundled)
        }
        // Clicking the dream digest routes into the Dream Journal (bare SwiftPM runs have no
        // bundle identity, so UNUserNotificationCenter is only touched from a real .app).
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowSupport.bringToFront()
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix("dream-digest") {
            Task { @MainActor in
                WindowSupport.bringToFront()
                NotificationCenter.default.post(name: .hypermnesiaOpenDreamJournal, object: nil)
            }
        }
        completionHandler()
    }
}

enum WindowSupport {
    /// Activate the app and raise its main window (not the menu-bar popover).
    @MainActor static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Put the cursor in the toolbar `.searchable` field. SwiftUI's `searchFocused` is macOS 15+, so
    /// on the macOS 14 deployment target we locate the hosted NSSearchField and make it first
    /// responder. The whole window view tree (theme frame) is walked, since the toolbar search field
    /// lives in the titlebar area, not the content view.
    @MainActor static func focusSearchField() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) else { return }
        let root = window.contentView?.superview ?? window.contentView
        guard let field = firstSearchField(in: root) else { return }
        window.makeFirstResponder(field)
    }

    @MainActor private static func firstSearchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let found = firstSearchField(in: sub) { return found }
        }
        return nil
    }
}

/// The menu-bar popover: quick stats, recent captures, and entry points.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updater = UpdaterModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if let version = updater.availableUpdateVersion { updateCallout(version) }
            if model.draftCount > 0 { draftsCallout }
            if let injection = model.lastInjection {
                // Proof the loop is closing: memory went INTO a session, not just out of one.
                Label {
                    Text("\(injection.count) \(injection.count == 1 ? "memory" : "memories") \(injection.viaRecall ? "recalled" : "injected") \(injection.date.formatted(.relative(presentation: .named))) · \(projectDisplayName(injection.projectId))")
                } icon: {
                    Image(systemName: "drop.fill").foregroundStyle(Color.brand)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
            }
            recentSection
            Divider().padding(.vertical, 5)
            actions
        }
        .padding(8)
        .frame(width: 300)
        .task { model.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("Hypermnesia").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 6)
    }

    private var subtitle: String {
        let count = model.memories.count
        let noun = count == 1 ? "memory" : "memories"
        if let project = model.selectedProject { return "\(projectDisplayName(project)) · \(count) \(noun)" }
        return "\(count) \(noun)"
    }

    // MARK: - Update call-to-action

    /// A scheduled Sparkle check found an update; clicking hands off to the standard
    /// user-initiated flow (which shows the release notes + install UI in focus).
    private func updateCallout(_ version: String) -> some View {
        Button {
            updater.checkForUpdates()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").frame(width: 18)
                Text("Update available: \(version)")
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2).padding(.bottom, 4)
    }

    // MARK: - Drafts call-to-action

    private var draftsCallout: some View {
        Button { openDraftReviewWindow() } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill").frame(width: 18)
                Text(model.draftCount == 1 ? "1 draft awaiting review" : "\(model.draftCount) drafts awaiting review")
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2).padding(.bottom, 4)
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 1)
            if model.memories.isEmpty {
                Text("No memories yet — open Hypermnesia to get started.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                ForEach(model.memories.prefix(5)) { node in
                    Button { openMainWindow() } label: { recentRow(node) }
                        .buttonStyle(.plain).menuHover()
                }
            }
        }
    }

    private func recentRow(_ node: MemoryNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: node.type.sfSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(node.type.color)
                .frame(width: 22, height: 22)
                .background(node.type.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            Text(node.title).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(node.daysSinceValidation())d")
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { openMainWindow() } label: { MenuItemLabel(icon: "macwindow", text: "Open Hypermnesia", tint: .brand) }
                .buttonStyle(.plain).menuHover()
            Button { openSettingsWindow() } label: { MenuItemLabel(icon: "gearshape", text: "Settings…") }
                .buttonStyle(.plain).menuHover()
            Button {
                // The consent dialog lives in the main window — bring it forward first.
                openMainWindow()
                model.processPreviousSessions()
            } label: {
                MenuItemLabel(icon: "clock.arrow.circlepath",
                              text: model.isProcessing ? "Processing…" : "Process previous sessions…")
            }
            .buttonStyle(.plain).menuHover().disabled(model.isProcessing)
            if let status = model.processingStatus {
                Text(status).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 2)
            }
            if model.captureQueueHealth.hasActivity || model.captureQueueHealth.hasErrors {
                let health = model.captureQueueHealth
                Text("Queue: \(health.pending) pending · \(health.processing) processing · "
                     + "\(health.retrying) retrying · \(health.terminalErrors) failed")
                    .font(.caption2)
                    .foregroundStyle(health.hasErrors ? Color.red : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                    .help(health.lastError?.message ?? "Capture queue health")
            }
            Divider().padding(.vertical, 5).padding(.horizontal, 6)
            if UpdaterModel.shared.isAvailable {
                Button {
                    UpdaterModel.shared.checkForUpdates()
                    dismiss()   // Sparkle's window shouldn't fight the popover for focus
                } label: { MenuItemLabel(icon: "arrow.down.circle", text: "Check for Updates…") }
                    .buttonStyle(.plain).menuHover()
            }
            Button { restartApp() } label: { MenuItemLabel(icon: "arrow.clockwise", text: "Restart") }
                .buttonStyle(.plain).menuHover()
            Button { NSApp.terminate(nil) } label: { MenuItemLabel(icon: "power", text: "Quit") }
                .buttonStyle(.plain).menuHover().keyboardShortcut("q")
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        WindowSupport.bringToFront()
        dismiss()   // close the menu-bar popover so it doesn't float over the app window
    }

    private func openDraftReviewWindow() {
        model.openDraftReview()
        openMainWindow()
    }

    private func openSettingsWindow() {
        // A popover click doesn't activate the app, and an inactive app's freshly created
        // Settings window stays buried behind whichever app IS active. Activate first, then
        // raise the window once it exists (SwiftUI creates it on a later runloop turn).
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        dismiss()   // close the menu-bar popover when opening Settings
        DispatchQueue.main.async {
            NSApp.windows.first {
                $0.identifier?.rawValue.contains("Settings") == true || $0.title.hasSuffix("Settings")
            }?.makeKeyAndOrderFront(nil)
        }
    }

    private func restartApp() {
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundlePath]
            try? process.run()
            NSApp.terminate(nil)
            return
        }

        let executablePath = (Bundle.main.executableURL?.path).flatMap { $0.isEmpty ? nil : $0 }
            ?? (CommandLine.arguments.first ?? "")
        guard !executablePath.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = Array(CommandLine.arguments.dropFirst())
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// A leading-icon row label for menu items.
private struct MenuItemLabel: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A subtle rounded highlight on hover — the native menu-row feel.
private struct MenuHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.09) : .clear))
            .onHover { hovering = $0 }
    }
}

private extension View {
    func menuHover() -> some View { modifier(MenuHover()) }
}
