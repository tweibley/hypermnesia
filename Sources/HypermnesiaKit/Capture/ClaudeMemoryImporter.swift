import Foundation

/// Imports Claude Code's auto-memory — the memory-tool-backed files the agent itself maintains at
/// `~/.claude/projects/<encoded-project>/memory/*.md` — as typed DRAFT memories through the normal
/// review gate. Complements `ClaudeMdImporter` (hand-written CLAUDE.md / rules): auto-memories are
/// one fact per file with frontmatter (`name`, `description`, `metadata.type`), so each file maps
/// to exactly one candidate and the frontmatter type steers the memory type.
public enum ClaudeMemoryImporter {

    /// Claude Code's per-project auto-memory directory for a repo path.
    public static func memoryDirectory(
        projectPath: String,
        projectsDirectory: URL = ClaudeCodeSessions.projectsDirectory
    ) -> URL {
        projectsDirectory
            .appendingPathComponent(ClaudeCodeSessions.encode(path: projectPath), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// Memory files an import reads. `MEMORY.md` is the index Claude Code loads each session —
    /// one pointer line per memory, no content — so it is skipped.
    public static func sourceFiles(
        projectPath: String,
        projectsDirectory: URL = ClaudeCodeSessions.projectsDirectory
    ) -> [URL] {
        let dir = memoryDirectory(projectPath: projectPath, projectsDirectory: projectsDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Parse one auto-memory file into a draft candidate, or nil when it's too thin to keep.
    public static func parse(markdown: String, fileName: String, projectId: String) -> MemoryNode? {
        let (fields, body) = splitFrontmatter(markdown)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 12 else { return nil }   // matches the capture validator's floor

        let name = fields["name"] ?? (fileName as NSString).deletingPathExtension
        let title = ClaudeMdImporter.titleFrom(fields["description"] ?? text)

        // The auto-memory type vocabulary maps onto ours directly where the intent is clear;
        // `project` memories are free-form working knowledge, so they go through the same
        // heuristics that classify CLAUDE.md prose.
        let data: MemoryData
        switch fields["metadata.type"] {
        case "feedback":
            data = .convention(.init(rule: text))
        case "user":
            data = .fact(.init(category: "user", key: name, value: text))
        case "reference":
            data = .fact(.init(category: "reference", key: name, value: text))
        default:
            var classified = ClaudeMdImporter.node(for: text, heading: "", projectId: projectId)
            classified.title = title
            return classified
        }
        return MemoryNode(
            projectId: projectId, type: data.type, status: .draft,
            title: title, summary: text, data: data,
            confidence: 0.75,   // agent-written, unverified by any session here
            belief: 0.75,
            sourceQuote: nil
        )
    }

    /// Import into the store: parse every memory file, skip near-duplicates of existing memories
    /// (and of each other), insert the remainder as drafts.
    public static func importProject(
        projectPath: String, projectId: String, store: MemoryStore, dryRun: Bool = false,
        projectsDirectory: URL = ClaudeCodeSessions.projectsDirectory
    ) throws -> ClaudeMdImporter.Outcome {
        var pool = (try? store.allNodes(projectId: projectId)) ?? []
        var created: [MemoryNode] = []
        var duplicates = 0
        for file in sourceFiles(projectPath: projectPath, projectsDirectory: projectsDirectory) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let candidate = parse(markdown: text, fileName: file.lastPathComponent, projectId: projectId)
            else { continue }
            if DedupEngine.duplicate(of: candidate, in: pool) != nil {
                duplicates += 1
                continue
            }
            created.append(candidate)
            pool.append(candidate)
        }
        if !dryRun, !created.isEmpty {
            try store.upsert(created)
        }
        return ClaudeMdImporter.Outcome(created: created, duplicatesSkipped: duplicates)
    }

    // MARK: - Frontmatter

    /// Tolerant `---`-fenced frontmatter split. Returns top-level `key: value` pairs (quotes
    /// stripped), with one level of nesting flattened as `parent.key` (the files carry a
    /// `metadata:` map), plus the body after the closing fence. No fence → everything is body.
    static func splitFrontmatter(_ markdown: String) -> (fields: [String: String], body: String) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], markdown) }
        var fields: [String: String] = [:]
        var parent: String?
        for (index, rawLine) in lines.dropFirst().enumerated() {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let body = lines.dropFirst(index + 2).joined(separator: "\n")
                return (fields, body)
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let rawKey = String(line[..<colon])
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            let nested = rawKey.first?.isWhitespace == true
            if nested, let parent {
                fields["\(parent).\(key)"] = value
            } else {
                fields[key] = value
                parent = value.isEmpty ? key : nil   // a bare "metadata:" line opens a nested map
            }
        }
        return ([:], markdown)   // unterminated fence: treat the whole file as body
    }
}
