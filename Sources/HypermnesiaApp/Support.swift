import SwiftUI
import HypermnesiaKit

extension Color {
    /// The Hypermnesia brand accent (matches the decision-type color and the Stitch mockup).
    static let brand = Color(hex: "#7F13EC")
    /// A brighter purple for selection highlights that need more contrast on dark backgrounds.
    static let brandBright = Color(hex: "#A855F7")

    /// Build a color from an `#RRGGBB` string (the engine exposes type/decay colors as hex data).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        if cleaned.count == 6 {
            self = Color(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self = .gray
        }
    }
}

/// Semantic palette — one source of truth so every analytics surface reuses the *same* green / amber /
/// red as the decay badges, instead of SwiftUI's system colors (a slightly different hue that reads as a
/// clash). Declared on `ShapeStyle` (like the built-in `.orange` etc.) so the names work anywhere a
/// system color does — `.foregroundStyle(.positive)`, `.fill(.caution)`, `tint:` params — and as plain
/// `Color` values (`Color.critical`).
extension ShapeStyle where Self == Color {
    /// Trust / belief — the deep brand purple (also the decision-type "moat" color).
    static var belief: Color { .brand }
    /// Recency / freshness — a lighter purple from the brand family, so the Confidence card stays
    /// monochromatic instead of throwing a competing accent hue against the decay green/amber/red.
    static var freshness: Color { .brandBright }
    /// Healthy / confirmed / validated — the same green as the `fresh` decay band.
    static var positive: Color { Color(hex: "#22C55E") }
    /// Caution — the same amber as the `stale` decay band (warnings, decay, drift).
    static var caution: Color { Color(hex: "#F97316") }
    /// Failure — the same red as the `dormant` decay band (overrides, danger).
    static var critical: Color { Color(hex: "#EF4444") }
}

extension MemoryType {
    var color: Color { Color(hex: colorHex) }
}

extension DecayLevel {
    var color: Color { Color(hex: colorHex) }
}

/// Human-friendly project name: `github.com/acme/app` → `acme/app`, `path:/Users/x/proj` → `proj`.
func projectDisplayName(_ id: String) -> String {
    ProjectIdentity.displayName(for: id)
}

/// Which surface the detail pane shows.
enum BrowseMode: String, CaseIterable, Identifiable {
    case list, graph, health, trends, mri, feed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .list: "List"
        case .graph: "Graph"
        case .health: "Health"
        case .trends: "Trends"
        case .mri: "MRI"
        case .feed: "Feed"
        }
    }
    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .health: "heart.text.square"
        case .trends: "chart.xyaxis.line"
        case .mri: "waveform.path.ecg.rectangle"
        case .feed: "clock.arrow.circlepath"
        }
    }
}

/// Force-directed layout modes (the graph toolbar switches between these — ported in Phase 7).
enum GraphLayoutMode: String, CaseIterable, Identifiable {
    case constellation, solarSystem, hybridCluster
    var id: String { rawValue }
    var label: String {
        switch self {
        case .constellation: "Constellation"
        case .solarSystem: "Solar System"
        case .hybridCluster: "Clusters"
        }
    }
}
