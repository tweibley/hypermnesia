import Foundation

/// The kind of knowledge a memory captures.
///
/// Ported from the original `MemoryType` (see `docs/design/01-data-model-and-types.md`).
///
/// **Deviation from the original:** the engine is UI-free, so visual metadata is exposed as plain
/// data — `sfSymbol` (an SF Symbol name) and `colorHex` — instead of `SwiftUI.Image`/`Color`. The
/// app layer maps these to real SwiftUI values. This keeps `HypermnesiaKit` buildable headlessly
/// (it's what the CLI and hooks use) without importing SwiftUI.
public enum MemoryType: String, Codable, CaseIterable, Sendable, Hashable {
    /// A choice made between alternatives, with rationale — the "why" layer (the moat).
    case decision
    /// A rule the project follows ("always do X").
    case convention
    /// A goal / desired behavior the work is driving toward.
    case intent
    /// A stable piece of project state ("uses Postgres 16").
    case fact
    /// A risk, caveat, or known problem to watch.
    case concern
    /// A deferred idea / future work, not yet acted on.
    case backlog
    /// A durable pointer into the codebase (file + symbol + range), anchored to a commit.
    case codeRef

    /// Stable ordering index (matches `allCases`), used by layout modes.
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public var displayName: String {
        switch self {
        case .decision: "Decision"
        case .convention: "Convention"
        case .intent: "Intent"
        case .fact: "Fact"
        case .concern: "Concern"
        case .backlog: "Backlog"
        case .codeRef: "Code Reference"
        }
    }

    /// Noun phrase for stats lines in shareable artifacts: "3 decisions", "1 backlog item".
    public func counted(_ count: Int) -> String {
        let noun: String = switch self {
        case .decision: count == 1 ? "decision" : "decisions"
        case .convention: count == 1 ? "convention" : "conventions"
        case .intent: count == 1 ? "intent" : "intents"
        case .fact: count == 1 ? "fact" : "facts"
        case .concern: count == 1 ? "concern" : "concerns"
        case .backlog: count == 1 ? "backlog item" : "backlog items"
        case .codeRef: count == 1 ? "code reference" : "code references"
        }
        return "\(count) \(noun)"
    }

    /// SF Symbol name (resolved to an `Image` in the app layer).
    public var sfSymbol: String {
        switch self {
        case .decision: "arrow.triangle.branch"
        case .convention: "ruler"
        case .intent: "target"
        case .fact: "info.circle"
        case .concern: "exclamationmark.triangle"
        case .backlog: "tray"
        case .codeRef: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Hex color (`#RRGGBB`), matched to the original Stitch palette.
    public var colorHex: String {
        switch self {
        case .decision: "#7F13EC"   // purple
        case .convention: "#A855F7" // light purple
        case .intent: "#4ADE80"     // green
        case .fact: "#22D3EE"       // cyan
        case .concern: "#FBBF24"    // amber
        case .backlog: "#818CF8"    // indigo
        case .codeRef: "#2DD4BF"    // teal
        }
    }

    /// Shape used to render this type as a graph node.
    public var nodeShape: NodeShape {
        switch self {
        case .decision: .hexagon
        case .concern: .triangle
        case .codeRef: .roundedSquare
        default: .circle
        }
    }

    /// Whether memories of this type lose confidence over time.
    ///
    /// Per the original's shipped behavior, only the "knowledge" types age; facts, concerns,
    /// backlog items, and code references hold their confidence until explicitly changed.
    /// (See the decay reconciliation in `docs/design/00-OVERVIEW.md`.)
    public var decaysWithTime: Bool {
        switch self {
        case .decision, .convention, .intent: true
        case .fact, .concern, .backlog, .codeRef: false
        }
    }

    /// Whether drafts of this type are elevated to confirmed only by repeat sightings (or a
    /// human) — never by the confident-capture fast path. CodeRefs are observed facts with a high
    /// prior, but a one-off edit must stay a draft the user can ignore.
    public var confirmsBySightingOnly: Bool {
        switch self {
        case .codeRef: true
        default: false
        }
    }

    /// Whether memories of this type compete for hydration ranking slots (session-start context
    /// and per-prompt primary ranking). CodeRefs don't: they would crowd out the knowledge types,
    /// so they enrich via annotations or query-path matching instead.
    public var ranksInHydration: Bool {
        switch self {
        case .codeRef: false
        default: true
        }
    }

    /// Geometric shape for graph rendering (resolved to a `Shape` in the app layer).
    public enum NodeShape: String, Codable, Sendable, Hashable {
        case hexagon
        case circle
        case roundedSquare
        case triangle
    }
}

/// Draft (proposed, awaiting confirmation) vs confirmed (accepted, hydrates prompts).
public enum MemoryStatus: String, Codable, Sendable, Hashable {
    case draft
    case confirmed
}
