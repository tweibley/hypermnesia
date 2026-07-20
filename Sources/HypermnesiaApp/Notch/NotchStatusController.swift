import AppKit
import HypermnesiaKit
#if canImport(Darwin)
import Darwin
#endif

extension Notification.Name {
    /// Posted by the Settings model when `AppConfig` changes, so the notch reacts immediately
    /// instead of on its next poll tick.
    static let hypermnesiaConfigChanged = Notification.Name("Hypermnesia.configChanged")
}

/// Drives the notch status display: watches the session-event log the hooks append to, reduces it
/// to the currently visible cards, and shows/hides the notch panel.
///
/// The pop is for work finishing where you AREN'T looking — cards whose host app is frontmost are
/// suppressed and auto-dismissed (you're already there), and clicking a card jumps back to that
/// exact session and dismisses it.
@MainActor
final class NotchStatusController {
    static let shared = NotchStatusController()

    private var panel: NotchPanel?
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    /// Event ids the user has handled (clicked, dismissed, or visited the host app). Per-event,
    /// not per-session — a NEW event for the same session pops again. Bounded in-memory set; a
    /// relaunch only resurrects cards still inside their TTL, which is the right call for
    /// unanswered attention cards anyway.
    private var dismissedEventIds: Set<String> = []
    private var dismissedOrder: [String] = []
    /// Synthetic "Dreamed" card shown while a dream is unread. Not appended to the event log —
    /// AppModel sets it from the store, so it survives TTLs and clears on read/dismiss. The event
    /// id is the journal entry id: dismissing tonight's chip stays dismissed, a NEW dream pops.
    private var dreamChip: SessionEvent?

    /// Update (or clear) the dream chip from the unread journal entries.
    func setDreamChip(unread: [DreamJournalEntry]) {
        guard let newest = unread.first else {
            if dreamChip != nil { dreamChip = nil; refresh() }
            return
        }
        let epiphanies = unread.reduce(0) { $0 + $1.payload.epiphanies.count }
        let skills = unread.reduce(0) { $0 + $1.payload.skillProposals.count }
        var summary = "\(epiphanies) epiphan\(epiphanies == 1 ? "y" : "ies")"
        if skills > 0 { summary += ", \(skills) skill proposal\(skills == 1 ? "" : "s")" }
        let chip = SessionEvent(
            id: newest.id,
            timestamp: newest.createdAt,
            kind: .finished,
            client: "hypermnesia",
            sessionId: "dream-journal",
            projectId: newest.projectId,
            title: "Dreamed — \(summary). Click to open the journal.")
        if dreamChip != chip { dreamChip = chip; refresh() }
    }

    func start() {
        guard panel == nil else { return }
        panel = NotchPanel(controller: self)
        SessionEventLog.touch()   // the vnode watcher needs a file to attach to
        attachWatcher()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: .hypermnesiaConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Slow safety tick: expires finished cards, catches missed vnode events, re-attaches the
        // watcher after log rotation replaces the file.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.watcher == nil { self.attachWatcher() }
                self.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        guard let panel else { return }
        let config = AppConfigStore.loadBestEffort()
        guard config.notchEnabled else { panel.update(cards: [], working: []); return }

        let events = SessionEventLog.recent()
        // Cap the poppable cards over ONLY the kinds the user enabled, so a disabled kind (e.g.
        // attention pops) can't consume the maxCards budget and starve an enabled one (finished).
        // ended/working are never pops — working is the strip below; both are excluded by omission.
        var allowedKinds: Set<SessionEvent.Kind> = []
        if config.notchOnNeedsAttention { allowedKinds.insert(.attention) }
        if config.notchOnAgentFinish { allowedKinds.insert(.finished) }
        var cards = SessionEventFeed.cards(
            events: events, dismissedEventIds: dismissedEventIds, allowedKinds: allowedKinds)
        var working = config.notchShowWorking ? SessionEventFeed.working(events: events) : []
        // A working row for a dead host is a lie — if every process recorded at hook time is gone
        // (crashed agent, closed terminal), the turn can't still be running.
        working.removeAll { !$0.event.isDemo && !Self.hostLooksAlive($0.event) }

        // The quiet "Dreamed" chip: rides the same card pipeline but is store-backed (no TTL) —
        // it exists exactly while a dream is unread and not dismissed. No hostPids, so the
        // frontmost filter below never hides it.
        if let chip = dreamChip, !dismissedEventIds.contains(chip.id) {
            cards.append(SessionEventFeed.Card(event: chip))
        }

        // You're already looking at that session's app — hide the pop for now. Do NOT permanently
        // dismiss: hostPids is per-app, not per-tab, so another Claude/Cursor tab in the same host
        // would otherwise never resurface when you leave this one. Click/explicit dismiss still
        // records. Demo cards opt out: they're spawned from the app you're looking at.
        if let front = NSWorkspace.shared.frontmostApplication {
            let frontPid = front.processIdentifier
            let seen = { (card: SessionEventFeed.Card) in
                !card.event.isDemo && card.event.hostPids.contains(frontPid)
            }
            cards.removeAll(where: seen)
            // Working rows are presence, not pops: hidden while you're in that app, but never
            // dismissed — step away and the session is on the strip again.
            working.removeAll(where: seen)
        }
        panel.update(cards: cards, working: working)
    }

    /// Card clicked: jump back to that exact session. Pop cards are cleared; a working row stays
    /// live (the frontmost filter hides it the moment the jump lands).
    func activate(_ card: SessionEventFeed.Card) {
        // The dream chip jumps into the Dream Journal, not a host session.
        if card.event.client == "hypermnesia" {
            if card.event.kind != .working { markDismissed(card.event.id) }
            WindowSupport.bringToFront()
            NotificationCenter.default.post(name: .hypermnesiaOpenDreamJournal, object: nil)
            refresh()
            return
        }
        // Jump to that exact session, but only dismiss the pop if we actually landed somewhere: a
        // tmux/screen/ssh session has no GUI host in its pid chain (focus returns false), so keep
        // the card up instead of dismissing it into a silent no-op. Working rows are never dismissed.
        let focused = SessionFocus.focus(card.event)
        if focused, card.event.kind != .working {
            markDismissed(card.event.id)
        }
        refresh()
    }

    func dismiss(_ card: SessionEventFeed.Card) {
        markDismissed(card.event.id)
        refresh()
    }

    /// Any of the pids recorded at hook time still running? (`kill 0` probes for existence;
    /// EPERM still means alive.) No recorded pids — nothing to disprove — reads as alive.
    private static func hostLooksAlive(_ event: SessionEvent) -> Bool {
        guard !event.hostPids.isEmpty else { return true }
        return event.hostPids.contains { kill($0, 0) == 0 || errno == EPERM }
    }

    private func markDismissed(_ id: String) {
        guard dismissedEventIds.insert(id).inserted else { return }
        dismissedOrder.append(id)
        while dismissedOrder.count > 300 {
            dismissedEventIds.remove(dismissedOrder.removeFirst())
        }
    }

    // MARK: - Log watching

    /// Instant pops: a vnode source on the log file fires the moment a hook appends. Rotation
    /// truncates in place (same inode), so `.extend`/`.write` keep firing; if the file is ever
    /// replaced, the timer re-attaches.
    private func attachWatcher() {
        detachWatcher()
        let fd = open(SessionEventLog.fileURL().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.watcher?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.attachWatcher()
            }
            self.refresh()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func detachWatcher() {
        watcher?.cancel()
        watcher = nil
    }
}
