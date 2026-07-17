import Foundation

/// Where the local memory database lives.
public struct StoreLocation: Sendable {
    public enum Kind: Sendable {
        case file(URL)
        case inMemory
    }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public static func file(_ url: URL) -> StoreLocation { .init(kind: .file(url)) }

    /// An ephemeral in-memory database (for tests).
    public static let inMemory = StoreLocation(kind: .inMemory)

    /// The directory Hypermnesia keeps its data in:
    /// `~/Library/Application Support/Hypermnesia/`.
    ///
    /// Override with `HYPERMNESIA_SUPPORT_DIR` to relocate the entire data directory (memory.db,
    /// config.json, the capture queue, embeddings). This isolates a profile from the user's real
    /// store — used by the eval harness and by tests/CI to avoid touching production memory.
    public static var supportDirectory: URL {
        // Env override, with the pre-rename variable honored so existing scripts keep working.
        for key in ["HYPERMNESIA_SUPPORT_DIR", "HYPERTHYMESIA_SUPPORT_DIR"] {
            if let override = ProcessInfo.processInfo.environment[key], !override.isEmpty {
                return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let current = base.appendingPathComponent("Hypermnesia", isDirectory: true)
        migrateLegacyDirectoryIfNeeded(base: base, to: current)
        return current
    }

    /// One-time rename migration: installs that predate the Hypermnesia name keep their entire
    /// store (memory.db, config, queue, embeddings, momentum) by moving the old directory into
    /// place the first time the new name runs. A failed move (permissions, races) leaves the old
    /// directory untouched for the next attempt.
    /// Test seam for the migration logic (the real call sites use user-global paths).
    static func migrateLegacyDirectoryForTesting(base: URL, to current: URL) {
        migrateLegacyDirectoryIfNeeded(base: base, to: current)
    }

    private static func migrateLegacyDirectoryIfNeeded(base: URL, to current: URL) {
        let legacy = base.appendingPathComponent("Hyperthymesia", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }

    /// The default on-disk store: `…/Hypermnesia/memory.db`.
    public static var `default`: StoreLocation {
        .file(supportDirectory.appendingPathComponent("memory.db"))
    }
}
