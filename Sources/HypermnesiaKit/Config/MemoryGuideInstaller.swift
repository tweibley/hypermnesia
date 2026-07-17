import Foundation

/// Installs/removes a CLAUDE.md "memory usage" instruction block so MCP-path agents
/// know to call `recall` before editing. Shared by the CLI (`install-memory-guide`) and
/// future app settings.
public enum MemoryGuideInstaller {
    static let openMarker  = "<!-- hypermnesia:memory-guide -->"
    static let closeMarker = "<!-- /hypermnesia:memory-guide -->"

    static let blockContent = """
    \(openMarker)
    # Hypermnesia — project memory

    This project uses Hypermnesia memory, exposed via an MCP server (`hypermnesia`).
    BEFORE reading or editing code for any task, call the `recall` tool
    (`mcp__hypermnesia__recall`) with a short query describing what you are about to do,
    to load the project's established conventions, decisions, and gotchas.
    Treat what it returns as rules to follow.
    \(closeMarker)
    """

    /// URL of the CLAUDE.md to write/read.
    public static func claudeMdURL(projectPath: String? = nil) -> URL {
        let base = projectPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        return base.appendingPathComponent("CLAUDE.md")
    }

    /// Whether the guide block is already present in the target file.
    public static func isInstalled(projectPath: String? = nil) -> Bool {
        let url = claudeMdURL(projectPath: projectPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(openMarker)
    }

    /// Install (or replace) the block in CLAUDE.md. Idempotent: re-running replaces
    /// the existing block rather than appending a second copy.
    public static func install(projectPath: String? = nil) throws {
        let url = claudeMdURL(projectPath: projectPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = replaceOrAppend(in: existing, block: blockContent)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the marker-delimited block from CLAUDE.md.
    /// If the file becomes empty (or whitespace-only) after removal, delete it.
    public static func uninstall(projectPath: String? = nil) throws {
        let url = claudeMdURL(projectPath: projectPath)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }

        let stripped = removeBlock(from: existing)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try stripped.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the merged file text for dry-run preview.
    public static func preview(projectPath: String? = nil) -> String {
        let url = claudeMdURL(projectPath: projectPath)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return replaceOrAppend(in: existing, block: blockContent)
    }

    // MARK: - Helpers

    private static func replaceOrAppend(in text: String, block: String) -> String {
        if text.contains(openMarker) || text.contains(legacyOpenMarker) {
            // Re-install replaces the existing block — including one written under the old name,
            // which would otherwise duplicate the guidance.
            return removeBlock(from: text).appending(block + "\n")
        }
        let base = text.hasSuffix("\n") || text.isEmpty ? text : text + "\n"
        return base + (base.isEmpty ? "" : "\n") + block + "\n"
    }

    /// The pre-rename marker pair. Uninstall stays the inverse of every install we ever shipped,
    /// so blocks written under the old name are removed the same way as current ones.
    static let legacyOpenMarker  = "<!-- hyperthymesia:memory-guide -->"
    static let legacyCloseMarker = "<!-- /hyperthymesia:memory-guide -->"

    static func removeBlock(from text: String) -> String {
        let current = removeBlock(from: text, open: openMarker, close: closeMarker)
        return removeBlock(from: current, open: legacyOpenMarker, close: legacyCloseMarker)
    }

    private static func removeBlock(from text: String, open openMarker: String, close closeMarker: String) -> String {
        // Strip each well-formed block (open … close), inclusive, plus any trailing newline. Scan
        // open-first and pair an open with the first close *after* it, skipping orphan opens — so
        // neither an orphaned open marker (which must not span the user's content to a later block's
        // close) nor an orphaned close marker (which must not stop us finding a valid later block)
        // can corrupt or block removal. Orphan markers are left in place.
        var result = text
        outer: while true {
            var searchStart = result.startIndex
            while let open = result.range(of: openMarker, range: searchStart..<result.endIndex) {
                guard let close = result.range(of: closeMarker, range: open.upperBound..<result.endIndex) else {
                    return result   // no close after any remaining open → orphan open(s), leave intact
                }
                // Another open before this close ⇒ the current open is orphaned; retry from the next open.
                if let nextOpen = result.range(of: openMarker, range: open.upperBound..<close.lowerBound) {
                    searchStart = nextOpen.lowerBound
                    continue
                }
                let afterClose = close.upperBound
                let endIndex: String.Index = (afterClose < result.endIndex && result[afterClose] == "\n")
                    ? result.index(after: afterClose) : afterClose
                result.removeSubrange(open.lowerBound..<endIndex)
                continue outer   // string mutated — restart the scan
            }
            return result   // no opens left
        }
    }
}
