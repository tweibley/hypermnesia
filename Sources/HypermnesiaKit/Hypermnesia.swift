import Foundation

/// Top-level namespace and metadata for the Hypermnesia memory engine.
///
/// Hypermnesia gives Claude Code, Cursor, and Google Antigravity a durable, decaying, queryable
/// memory of every project they touch. This package is the platform-agnostic core (models, store,
/// capture, classification, decay, deduplication, hydration, graph layout) shared by the
/// `hypermnesia` CLI and the macOS app.
///
/// See `docs/IMPLEMENTATION-PLAN.md` and `docs/design/` for the full design.
public enum Hypermnesia {
    /// Semantic version of the engine. Keep in lockstep with the top-level `VERSION` file.
    public static let version = "0.6.0"
}
