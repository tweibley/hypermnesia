import Foundation

/// Per-dialect edit-tool path/content keys. Shared by transcript parsing (retain full paths) and
/// `Conversation.editToolMarkers` (edit-heavy detection), so both stay in sync.
public enum EditToolSpec: Sendable {

    public struct Keys: Sendable, Equatable {
        /// Ordered candidate keys for the edited file path.
        public let pathKeys: [String]
        /// Ordered candidate keys for a short new-content snippet (never old_string).
        public let contentKeys: [String]
        /// How path/content values should be read from tool args.
        public let dialect: Dialect

        public init(pathKeys: [String], contentKeys: [String] = [], dialect: Dialect) {
            self.pathKeys = pathKeys
            self.contentKeys = contentKeys
            self.dialect = dialect
        }
    }

    public enum Dialect: Sendable, Equatable {
        /// Claude Code / Cursor: snake_case `input` object, plain string values.
        case anthropic
        /// Antigravity: TitleCase args, often double-encoded JSON strings.
        case antigravity
    }

    /// Claude Code file-editing tools.
    public static let claude: [String: Keys] = [
        "Edit": .init(pathKeys: ["file_path"], contentKeys: ["new_string"], dialect: .anthropic),
        "Write": .init(pathKeys: ["file_path"], contentKeys: ["content"], dialect: .anthropic),
        "MultiEdit": .init(pathKeys: ["file_path"], contentKeys: ["new_string"], dialect: .anthropic),
        "NotebookEdit": .init(pathKeys: ["notebook_path", "file_path"], contentKeys: ["new_string", "content"], dialect: .anthropic),
        "Update": .init(pathKeys: ["file_path", "path"], contentKeys: ["new_string", "content"], dialect: .anthropic),
    ]

    /// Cursor file-editing tools (same Anthropic-style `tool_use.input` shape).
    public static let cursor: [String: Keys] = [
        "ApplyPatch": .init(pathKeys: ["path", "file_path"], contentKeys: ["new_string", "content", "patch"], dialect: .anthropic),
        "Update": .init(pathKeys: ["path", "file_path"], contentKeys: ["new_string", "content"], dialect: .anthropic),
    ]

    /// Antigravity file-editing tools.
    public static let antigravity: [String: Keys] = [
        "write_to_file": .init(pathKeys: ["AbsolutePath", "TargetFile"], contentKeys: ["Contents", "content"], dialect: .antigravity),
        "replace_file_content": .init(pathKeys: ["AbsolutePath", "TargetFile"], contentKeys: ["TargetContent", "new_string", "content"], dialect: .antigravity),
        "multi_replace_file_content": .init(pathKeys: ["AbsolutePath", "TargetFile"], contentKeys: ["TargetContent", "new_string", "content"], dialect: .antigravity),
    ]

    /// Lookup by tool name across all dialects (names do not collide).
    public static func keys(forToolName name: String) -> Keys? {
        claude[name] ?? cursor[name] ?? antigravity[name]
    }

    public static func isEditTool(_ name: String) -> Bool {
        keys(forToolName: name) != nil
    }

    /// Markers scanned in rendered conversation text for `isEditHeavy`.
    /// Claude/Cursor tools that render as `Name(arg)` use a trailing `(`; bare names cover tools
    /// that may render without args. `multi_replace_file_content` is covered by the
    /// `replace_file_content` substring (letter-boundary check still counts it once).
    public static var editToolMarkers: [String] {
        var markers: [String] = []
        for name in claude.keys.sorted() {
            markers.append("\(name)(")
        }
        for name in cursor.keys.sorted() where name != "Update" {
            // ApplyPatch may render with or without an arg — match the bare name.
            markers.append(name)
        }
        // Update already covered via Claude's `Update(`.
        markers.append("write_to_file")
        markers.append("replace_file_content")
        return markers
    }

    /// Extract path + snippet from a tool's input/args. Returns nils when the tool isn't an edit
    /// tool or the path key is missing.
    public static func extract(toolName: String, input: JSONValue?) -> (path: String?, snippet: String?) {
        guard let keys = keys(forToolName: toolName), let input else { return (nil, nil) }
        let path = firstString(keys: keys.pathKeys, in: input, dialect: keys.dialect)
        let snippet = firstString(keys: keys.contentKeys, in: input, dialect: keys.dialect)
            .map { truncate($0, to: snippetLimit) }
        return (path, snippet)
    }

    public static let snippetLimit = 200

    // MARK: - Helpers

    private static func firstString(keys: [String], in input: JSONValue, dialect: Dialect) -> String? {
        for key in keys {
            guard let raw = input[key]?.stringValue, !raw.isEmpty else { continue }
            let value = dialect == .antigravity
                ? TranscriptParser.unquoteAntigravityArg(raw)
                : raw
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
