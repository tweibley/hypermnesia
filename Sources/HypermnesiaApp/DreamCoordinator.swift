import Foundation
import AppKit
import IOKit
import IOKit.ps
import HypermnesiaKit

extension Notification.Name {
    /// Open the Dream Journal — posted by the notch chip and the digest notification handler.
    static let hypermnesiaOpenDreamJournal = Notification.Name("Hypermnesia.openDreamJournal")
}

/// Darwin-level hands-off-the-machine time, from the IOHIDSystem registry entry. This is the
/// "first idle after wake" half of the dream trigger; the drain loop pausing during sleep is the
/// "after wake" half.
enum SystemIdle {
    static func seconds() -> TimeInterval? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        if let nanos = dict["HIDIdleTime"] as? UInt64 {
            return TimeInterval(nanos) / 1_000_000_000
        }
        if let number = dict["HIDIdleTime"] as? NSNumber {
            return number.doubleValue / 1_000_000_000
        }
        return nil
    }
}

/// AC/battery state for the dream guards. A machine with no battery (desktop) reads as on AC.
enum PowerStatus {
    static func current() -> (onAC: Bool, batteryPercent: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onAC = providing != (kIOPSBatteryPowerValue as String)
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                    let capacity = description[kIOPSCurrentCapacityKey as String] as? Int,
                    let max = description[kIOPSMaxCapacityKey as String] as? Int, max > 0 else { continue }
                percent = Int((Double(capacity) / Double(max) * 100).rounded())
                break
            }
        }
        return (onAC, percent)
    }
}

// MARK: - The nightly pass

extension AppModel {

    func refreshUnreadDreams() {
        guard let store else { unreadDreamCount = 0; return }
        let unread = (try? store.unreadDreamEntries()) ?? []
        unreadDreamCount = unread.count
        NotchStatusController.shared.setDreamChip(unread: unread)
    }

    func openDreamJournal() {
        dreamJournalShown = true
    }

    /// Opening the journal is reading it: the chip and badge clear.
    func markDreamsRead() {
        guard let store else { return }
        try? store.markAllDreamsRead()
        refreshUnreadDreams()
    }

    /// Whether confirming the pending backfill will also run the FIRST dream (only ever the first —
    /// so the consent dialog can price it exactly when it applies).
    var willRunFirstDream: Bool {
        guard let store else { return false }
        return ((try? store.dreamEntries(limit: 1)) ?? []).isEmpty
    }

    /// The engineered first impression: right after backfill lands, the corpus is richest and the
    /// user is watching. Runs under the consent just shown (even before nightly dreams are enabled),
    /// counts against tonight's cap, and ends in the REM replay when the dream has content.
    func runFirstDream(project: String) async {
        guard let store, !dreamPassRunning else { return }
        guard ((try? store.dreamEntries(limit: 1)) ?? []).isEmpty else { return }
        // Hold the shared dream gate for the whole pass so the nightly loop and "Dream now" can't
        // start a concurrent dream for the same night.
        dreamPassRunning = true
        defer { dreamPassRunning = false }
        processingStatus = "Dreaming over your history…"
        let config = AppConfigStore.loadBestEffort()
        let result = await Task.detached {
            await DreamService.dreamProject(projectId: project, store: store, appConfig: config)
        }.value
        Self.recordDreamCalls(result.callsMade)
        refreshUnreadDreams()
        reloadMemories()
        if let entry = result.entry, entry.outcome == .dreamed {
            processingStatus = nil
            remEntry = entry   // auto-plays the skippable REM replay; ends at the journal
        } else {
            // Quiet first night: no fake payoff. The MRI moment already landed.
            processingStatus = nil
        }
    }

    /// The idle-after-wake scheduler, called from the 20 s drain tick. Calendar-day due gate,
    /// idle + power guards, per-night call cap, most-recently-active ordering, re-checked idleness
    /// between projects (return-to-keyboard abort), and a hard wall-clock cap per pass.
    func runDreamsIfDue() async {
        guard let store, !dreamPassRunning else { return }
        let config = AppConfigStore.loadBestEffort()
        guard config.dreamsEnabled else { return }
        let now = Date()

        let projects = (try? store.visibleProjects()) ?? []
        let due = projects.filter { project in
            DreamScheduler.isDue(
                lastNight: (try? store.latestDreamNight(projectId: project)) ?? nil, now: now)
        }
        guard !due.isEmpty else { return }

        let power = PowerStatus.current()
        guard DreamScheduler.guardsPass(
            idleSeconds: SystemIdle.seconds() ?? 0,
            onACPower: power.onAC,
            batteryPercent: power.batteryPercent) else { return }

        var callsTonight = Self.dreamCallsTonight()
        guard DreamScheduler.capAllows(callsTonight: callsTonight, cap: config.dreamNightlyCallCap) else {
            return
        }

        dreamPassRunning = true
        defer { dreamPassRunning = false }

        let ordered = DreamScheduler.orderProjects(due.map { project in
            (project, (try? store.latestProcessedAt(projectId: project)) ?? nil)
        })
        let deadline = now.addingTimeInterval(DreamScheduler.wallClockCapSeconds)
        var dreamedEntries: [DreamJournalEntry] = []

        for project in ordered {
            guard Date() < deadline,
                  DreamScheduler.capAllows(callsTonight: callsTonight, cap: config.dreamNightlyCallCap)
            else { break }
            // Return-to-keyboard: the moment the user is back, stop — remaining projects roll to
            // the next night exactly like cap overflow.
            guard (SystemIdle.seconds() ?? 0) >= DreamScheduler.idleThresholdSeconds else { break }

            let result = await Task.detached {
                await DreamService.dreamProject(projectId: project, store: store, appConfig: config)
            }.value
            if result.callsMade > 0 {
                callsTonight += result.callsMade
                Self.recordDreamCalls(result.callsMade)
            }
            if let entry = result.entry, entry.outcome == .dreamed {
                dreamedEntries.append(entry)
            }
        }

        guard !dreamedEntries.isEmpty else { return }
        refreshUnreadDreams()
        if let selected = selectedProject, dreamedEntries.contains(where: { $0.projectId == selected }) {
            reloadMemories()   // dream drafts land in the visible inbox
        }
        maybeSendDigest(config: config, dreamed: dreamedEntries)
    }

    /// Manual "Dream now" for one project (Settings / journal button). Ignores idle/cap gating;
    /// replaces tonight's entry.
    func dreamNow(project: String) {
        // A single re-entrancy gate across all three dream entry points: `dreamPassRunning` is set
        // by the nightly pass and `runFirstDream` too, so a manual dream can never run concurrently
        // with them (two dreams for one night destroy each other's journal entry via upsert).
        guard let store, !isProcessing, !dreamPassRunning else { return }
        isProcessing = true
        dreamPassRunning = true
        processingStatus = "Dreaming…"
        Task { [weak self] in
            guard let self else { return }
            let config = AppConfigStore.loadBestEffort()
            let result = await Task.detached {
                await DreamService.dreamProject(projectId: project, store: store, appConfig: config)
            }.value
            Self.recordDreamCalls(result.callsMade)
            self.isProcessing = false
            self.dreamPassRunning = false
            self.refreshUnreadDreams()
            self.reloadMemories()
            if let reason = result.skippedReason {
                self.processingStatus = "Dream skipped: \(reason)"
            } else if let entry = result.entry {
                self.processingStatus = entry.outcome == .dreamed
                    ? "Dreamed — open the journal."
                    : "Quiet night — nothing cleared the quality gate."
            }
        }
    }

    // MARK: - Digest

    private func maybeSendDigest(config: AppConfig, dreamed: [DreamJournalEntry]) {
        let defaults = UserDefaults.standard
        switch config.dreamDigestCadence {
        case "off":
            return
        case "weekly":
            let last = defaults.object(forKey: Self.lastDigestKey) as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) >= 6.5 * 86_400 else { return }
        default:
            break   // nightly
        }
        Notifier.notifyDreamDigest(dreamed)
        defaults.set(Date(), forKey: Self.lastDigestKey)
    }

    private static let lastDigestKey = "Hypermnesia.lastDreamDigestAt"

    // MARK: - Per-night call accounting (shared by scheduled, first, and manual dreams)

    private static func capKey(for night: String) -> String { "Hypermnesia.dreamCalls.\(night)" }

    static func dreamCallsTonight(now: Date = Date()) -> Int {
        UserDefaults.standard.integer(forKey: capKey(for: DreamScheduler.nightKey(for: now)))
    }

    static func recordDreamCalls(_ calls: Int, now: Date = Date()) {
        guard calls > 0 else { return }
        let defaults = UserDefaults.standard
        let tonight = DreamScheduler.nightKey(for: now)
        defaults.set(dreamCallsTonight(now: now) + calls, forKey: capKey(for: tonight))
        // Retire yesterday's counter so the defaults don't accrue one key per night forever.
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) {
            defaults.removeObject(forKey: capKey(for: DreamScheduler.nightKey(for: yesterday)))
        }
    }
}
