import Foundation

/// Safe JSON read/write shared by the config installers (Claude Code `settings.json`, Cursor
/// `hooks.json` / `mcp.json`).
///
/// Reading: a missing or empty file reads as `[:]` (fresh install). A file that exists with content
/// that does not parse as a JSON object **throws** — falling back to `[:]` and writing would
/// silently destroy the user's other hooks, permissions, and MCP servers, when a human could still
/// repair the file by hand.
///
/// Writing: always atomic, so a crash — or Claude Code/Cursor reading mid-write — never observes a
/// truncated file.
public enum ConfigFile {
    public struct UnreadableError: LocalizedError {
        public let url: URL
        public let detail: String
        public var errorDescription: String? {
            "\(url.path) exists but is not valid JSON (\(detail)). "
                + "Refusing to overwrite it — fix or move the file, then retry."
        }
    }

    /// Read a JSON object; `[:]` for missing/empty files, throws for anything unparseable.
    public static func readObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UnreadableError(url: url, detail: "top level is not an object")
            }
            return object
        } catch let error as UnreadableError {
            throw error
        } catch {
            throw UnreadableError(url: url, detail: error.localizedDescription)
        }
    }

    /// Atomically write a JSON object (pretty-printed, sorted keys for stable diffs).
    public static func writeObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Single-quote a path for embedding in a shell command string (hook commands), so a binary
    /// installed under a path with spaces or shell metacharacters survives the shell's parsing.
    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
