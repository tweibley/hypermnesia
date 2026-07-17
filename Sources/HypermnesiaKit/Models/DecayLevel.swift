import Foundation

/// Freshness band derived from a memory's `confidence`.
///
/// Confidence is the authoritative value (set by the decay engine from age + override rate); the
/// band is purely a display/behavior bucket. We use the original's **confidence-based** thresholds,
/// not its calendar-label variant — see the decay reconciliation in `docs/design/00-OVERVIEW.md`.
///
/// **Deviation from the original:** the legacy 3-level `ConfidenceLevel` enum is dropped (it was
/// redundant with this one).
public enum DecayLevel: String, CaseIterable, Sendable, Hashable {
    case fresh      // confidence ≥ 0.75
    case aging      // 0.50 ..< 0.75
    case stale      // 0.25 ..< 0.50
    case dormant    // 0.01 ..< 0.25
    case obsolete   // ≤ 0 or superseded

    /// Bucket a confidence value (and supersession state) into a band.
    /// Uses `>=` cascades so out-of-range values (e.g. > 1.0 from bad data) resolve sensibly.
    public static func from(confidence: Double, isSuperseded: Bool = false) -> DecayLevel {
        if isSuperseded { return .obsolete }
        if confidence >= 0.75 { return .fresh }
        if confidence >= 0.50 { return .aging }
        if confidence >= 0.25 { return .stale }
        if confidence >= 0.01 { return .dormant }
        return .obsolete
    }

    /// Whether a memory at this level should be reviewed before an agent applies it.
    public var requiresReviewBeforeApplying: Bool {
        switch self {
        case .fresh, .aging: false
        case .stale, .dormant, .obsolete: true
        }
    }

    public var displayName: String {
        switch self {
        case .fresh: "Fresh"
        case .aging: "Aging"
        case .stale: "Stale"
        case .dormant: "Dormant"
        case .obsolete: "Obsolete"
        }
    }

    /// SF Symbol name (resolved in the app layer).
    public var sfSymbol: String {
        switch self {
        case .fresh: "checkmark.circle.fill"
        case .aging: "clock.fill"
        case .stale: "exclamationmark.circle.fill"
        case .dormant: "zzz"
        case .obsolete: "xmark.circle.fill"
        }
    }

    /// Hex color (resolved in the app layer).
    public var colorHex: String {
        switch self {
        case .fresh: "#22C55E"   // green
        case .aging: "#EAB308"   // yellow
        case .stale: "#F97316"   // orange
        case .dormant: "#EF4444" // red
        case .obsolete: "#9CA3AF" // gray
        }
    }
}
