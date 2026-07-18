import AppKit
import SwiftUI
import HypermnesiaKit

/// Where and how the notch panel draws on the chosen screen.
struct NotchGeometry: Equatable {
    let hasNotch: Bool
    /// Height of the camera-housing area content must clear (0 on notchless displays).
    let topInset: CGFloat
    /// Physical notch width (0 on notchless displays) — the panel is at least this wide so it
    /// reads as the notch expanding.
    let notchWidth: CGFloat
    /// Screen Y of the panel's top edge: flush with the top on notch screens, tucked under the
    /// menu bar elsewhere.
    let topY: CGFloat

    init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        if inset > 0 {
            hasNotch = true
            topInset = inset
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = max(0, screen.frame.width - left.width - right.width)
            } else {
                notchWidth = 200
            }
            topY = screen.frame.maxY
        } else {
            hasNotch = false
            topInset = 0
            notchWidth = 0
            topY = screen.visibleFrame.maxY - 8   // a floating capsule wants air below the menu bar
        }
    }

    /// For previews/harness renders where no real screen is involved.
    init(hasNotch: Bool, topInset: CGFloat, notchWidth: CGFloat, topY: CGFloat = 0) {
        self.hasNotch = hasNotch
        self.topInset = topInset
        self.notchWidth = notchWidth
        self.topY = topY
    }
}

/// The window class behind the notch panel. AppKit's `constrainFrameRect` clamps every window
/// below the menu bar — which would leave the panel hanging under it instead of merging with the
/// notch — so the one job of this subclass is to place frames exactly where asked.
private final class NotchPanelWindow: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The borderless, non-activating panel that hangs from the notch (or floats top-center on
/// notchless displays). Shown only while there are cards, and sized exactly to its content so the
/// invisible window never swallows clicks meant for the menu bar behind it.
///
/// Show/hide is choreographed dynamic-island style: the frame is placed first and the content
/// springs out of the notch; on retract the content springs back before the window disappears,
/// and a shrinking frame waits for the outgoing row's animation instead of clipping it.
@MainActor
final class NotchPanel {
    private let panel: NSPanel
    private let hosting: NSHostingView<NotchStatusView>
    private weak var controller: NotchStatusController?
    private var cards: [SessionEventFeed.Card] = []
    private var workingCards: [SessionEventFeed.Card] = []
    /// Hover state: the working strip is unfolded into per-session rows (and the window resized
    /// to fit them). Collapses shortly after the pointer leaves.
    private var workingExpanded = false
    private var pendingHide: DispatchWorkItem?
    private var pendingShrink: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?

    /// How long the retract/row-exit springs get before the window vanishes or the frame snaps in.
    private static let exitGrace: TimeInterval = 0.35

    init(controller: NotchStatusController) {
        self.controller = controller
        panel = NotchPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // the SwiftUI shape draws its own
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // Above the menu bar (layer 24) so the housing merges with the notch instead of being
        // drawn over. Must come last: setters like `isFloatingPanel` silently reset `level`.
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        hosting = NSHostingView(rootView: NotchStatusView(
            cards: [], geometry: nil, visible: false, onActivate: { _ in }, onDismiss: { _ in }))
        panel.contentView = hosting
    }

    func update(cards newCards: [SessionEventFeed.Card], working newWorking: [SessionEventFeed.Card] = []) {
        guard !(newCards.isEmpty && newWorking.isEmpty) else { retract(); return }
        guard let screen = Self.targetScreen() else { panel.orderOut(nil); return }
        pendingHide?.cancel()
        pendingHide = nil

        cards = newCards
        workingCards = newWorking
        if newWorking.isEmpty, workingExpanded {
            workingExpanded = false
            pendingCollapse?.cancel()
            pendingCollapse = nil
        }

        let appearing = !panel.isVisible
        // Appearing: place the final frame first (no shrink games on an invisible window), then
        // flip `visible` next runloop so the content springs out of the notch inside it.
        layout(on: screen, visible: !appearing, deferShrink: !appearing)
        panel.orderFrontRegardless()
        if appearing {
            DispatchQueue.main.async { [weak self] in
                guard let self, !(self.cards.isEmpty && self.workingCards.isEmpty),
                      let screen = Self.targetScreen() else { return }
                self.layout(on: screen, visible: true, deferShrink: false)
            }
        }
    }

    /// Pointer entered/left the housing. Entering unfolds the working rows (the strip is the only
    /// hover-expandable content); leaving folds them back after a short grace so skimming across
    /// the gap between rows doesn't flap the window.
    func hoverChanged(_ inside: Bool) {
        guard panel.isVisible else { return }
        if inside {
            pendingCollapse?.cancel()
            pendingCollapse = nil
            guard !workingExpanded, !workingCards.isEmpty else { return }
            workingExpanded = true
            relayout(deferShrink: false)
        } else if workingExpanded, pendingCollapse == nil {
            let collapse = DispatchWorkItem { [weak self] in
                guard let self, self.workingExpanded else { return }
                self.workingExpanded = false
                self.pendingCollapse = nil
                self.relayout(deferShrink: true)
            }
            pendingCollapse = collapse
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: collapse)
        }
    }

    /// Animate the housing back into the notch, then drop the window once the spring has landed.
    private func retract() {
        cards = []
        workingCards = []
        workingExpanded = false
        pendingShrink?.cancel()
        pendingShrink = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard panel.isVisible, pendingHide == nil else { return }
        hosting.rootView = NotchStatusView(
            cards: hosting.rootView.cards, workingCards: hosting.rootView.workingCards,
            geometry: hosting.rootView.geometry, visible: false,
            workingExpanded: hosting.rootView.workingExpanded,
            onActivate: { _ in }, onDismiss: { _ in })
        let hide = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: hide)
    }

    private func relayout(deferShrink: Bool) {
        guard let screen = Self.targetScreen() else { return }
        layout(on: screen, visible: true, deferShrink: deferShrink)
    }

    /// Render the current state and size/place the window around it. Growing applies immediately;
    /// shrinking (height or width) waits out the exit springs so outgoing rows aren't clipped.
    private func layout(on screen: NSScreen, visible: Bool, deferShrink: Bool) {
        let geometry = NotchGeometry(screen: screen)
        setRoot(geometry: geometry, visible: visible)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: geometry.topY - size.height,
            width: size.width, height: size.height)

        pendingShrink?.cancel()
        pendingShrink = nil
        let shrinking = frame.height < panel.frame.height - 0.5 || frame.width < panel.frame.width - 0.5
        if deferShrink, shrinking, panel.isVisible {
            let shrink = DispatchWorkItem { [weak self] in self?.panel.setFrame(frame, display: true) }
            pendingShrink = shrink
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: shrink)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func setRoot(geometry: NotchGeometry, visible: Bool) {
        hosting.rootView = NotchStatusView(
            cards: cards,
            workingCards: workingCards,
            geometry: geometry,
            visible: visible,
            workingExpanded: workingExpanded,
            onActivate: { [weak controller] in controller?.activate($0) },
            onDismiss: { [weak controller] in controller?.dismiss($0) },
            onHoverChange: { [weak self] in self?.hoverChanged($0) })
    }

    /// The built-in (notched) display when present, else wherever the menu bar lives.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
