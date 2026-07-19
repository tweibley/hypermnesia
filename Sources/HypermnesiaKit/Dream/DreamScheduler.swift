import Foundation

/// Pure scheduling policy for the idle-after-wake dream pass. The app supplies live idle/power
/// readings; everything here is deterministic and unit-testable.
///
/// The gate is a CALENDAR-DAY gate, deliberately not the rolling 86,400 s interval the existing
/// maintenance uses — a rolling gate drifts later every day, and mornings need a fixed day
/// boundary ("did we dream tonight yet?").
public enum DreamScheduler {

    /// The machine must have been hands-off this long before a dream may start.
    public static let idleThresholdSeconds: TimeInterval = 180
    /// On battery below this floor, skip the night — trust matters more than the marginal dream.
    public static let batteryFloorPercent = 30
    /// Hard wall-clock cap for one whole nightly pass (all projects).
    public static let wallClockCapSeconds: TimeInterval = 600

    /// Local calendar day, "yyyy-MM-dd" — the journal's `night` key.
    public static func nightKey(
        for date: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current
    ) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Due when the project hasn't RUN (dreamed or quiet) tonight. A recorded quiet night counts —
    /// once per calendar day means one model attempt, not one success.
    public static func isDue(
        lastNight: String?, now: Date, calendar: Calendar = .current, timeZone: TimeZone = .current
    ) -> Bool {
        lastNight != nightKey(for: now, calendar: calendar, timeZone: timeZone)
    }

    /// The power/idle guards. `batteryPercent == nil` means no battery (desktop) → power passes.
    public static func guardsPass(
        idleSeconds: TimeInterval, onACPower: Bool, batteryPercent: Int?
    ) -> Bool {
        guard idleSeconds >= idleThresholdSeconds else { return false }
        if !onACPower, let percent = batteryPercent, percent < batteryFloorPercent { return false }
        return true
    }

    /// Whether the per-night classifier call cap still has room. `cap <= 0` disables the cap.
    public static func capAllows(callsTonight: Int, cap: Int) -> Bool {
        cap <= 0 || callsTonight < cap
    }

    /// Most-recently-active projects first (nil activity last, stable by id) — the cap spends its
    /// budget where the user actually works; projects beyond it roll to the next night.
    public static func orderProjects(_ activity: [(projectId: String, lastActive: Date?)]) -> [String] {
        activity
            .sorted { a, b in
                switch (a.lastActive, b.lastActive) {
                case let (l?, r?): l != r ? l > r : a.projectId < b.projectId
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.projectId < b.projectId
                }
            }
            .map(\.projectId)
    }
}
