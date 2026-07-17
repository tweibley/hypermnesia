import Foundation

/// Bootstraps memory from what teams already have: hand-written CLAUDE.md conventions. Parses the
/// project's CLAUDE.md (and `.claude/rules/*.md`) into typed DRAFT memories through the normal
/// review gate — imported prose is bulk, possibly stale text, so nothing auto-confirms.
public enum ClaudeMdImporter {

    public struct Outcome: Sendable {
        public let created: [MemoryNode]
        public let duplicatesSkipped: Int
    }

    /// Files an import reads, in order, relative to the project root.
    public static func sourceFiles(projectPath: String) -> [URL] {
        let root = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
        var files: [URL] = []
        let claudeMd = root.appendingPathComponent("CLAUDE.md")
        if FileManager.default.fileExists(atPath: claudeMd.path) { files.append(claudeMd) }
        let rulesDir = root.appendingPathComponent(".claude/rules")
        if let rules = try? FileManager.default.contentsOfDirectory(at: rulesDir, includingPropertiesForKeys: nil) {
            files += rules.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return files
    }

    /// Parse one markdown document into draft candidates. Our own installed guide block is
    /// stripped first — importing our recall instructions back as "memories" would be recursion.
    public static func parse(markdown: String, projectId: String) -> [MemoryNode] {
        let cleaned = stripGuideBlock(from: markdown)
        var heading = ""
        var candidates: [MemoryNode] = []
        var currentBullet: String?

        func flush() {
            if let text = currentBullet { appendCandidate(text, heading: heading) }
            currentBullet = nil
        }
        func appendCandidate(_ raw: String, heading: String) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12 else { return }   // matches the capture validator's floor
            candidates.append(node(for: text, heading: heading, projectId: projectId))
        }

        for rawLine in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flush()
                heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let bullet = bulletContent(trimmed) {
                flush()
                currentBullet = bullet
            } else if currentBullet != nil, !trimmed.isEmpty {
                currentBullet! += " " + trimmed   // continuation line of the same bullet
            } else if trimmed.isEmpty {
                flush()
            }
        }
        flush()
        return candidates
    }

    /// Import into the store: parse all source files, skip near-duplicates of existing memories
    /// (and of each other), insert the remainder as drafts.
    public static func importProject(
        projectPath: String, projectId: String, store: MemoryStore, dryRun: Bool = false
    ) throws -> Outcome {
        var pool = (try? store.nodes(projectId: projectId, limit: 2000)) ?? []
        var created: [MemoryNode] = []
        var duplicates = 0
        for file in sourceFiles(projectPath: projectPath) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for candidate in parse(markdown: text, projectId: projectId) {
                if DedupEngine.duplicate(of: candidate, in: pool) != nil {
                    duplicates += 1
                    continue
                }
                created.append(candidate)
                pool.append(candidate)
            }
        }
        if !dryRun, !created.isEmpty {
            try store.upsert(created)
        }
        return Outcome(created: created, duplicatesSkipped: duplicates)
    }

    // MARK: - Classification heuristics

    static func node(for text: String, heading: String, projectId: String) -> MemoryNode {
        let type = classify(text, heading: heading)
        let title = titleFrom(text)
        let data: MemoryData
        switch type {
        case .concern:
            data = .concern(.init(issue: text, severity: "medium"))
        case .backlog:
            data = .backlog(.init(idea: text, priority: "medium"))
        case .decision:
            data = .decision(.init(chosen: text))
        case .fact:
            let (key, value) = factParts(text)
            data = .fact(.init(category: heading.isEmpty ? "project" : heading.lowercased(), key: key, value: value))
        default:
            data = .convention(.init(rule: text))
        }
        return MemoryNode(
            projectId: projectId, type: data.type, status: .draft,
            title: title, summary: text, data: data,
            confidence: 0.75,   // imported prose: plausible, unverified by any session
            belief: 0.75,
            sourceQuote: nil
        )
    }

    static func classify(_ text: String, heading: String) -> MemoryType {
        let lower = text.lowercased()
        let headingLower = heading.lowercased()
        func hasAny(_ needles: [String], in haystack: String) -> Bool {
            needles.contains { haystack.contains($0) }
        }
        if hasAny(["todo", "later", "eventually", "planned", "someday", "backlog"], in: lower)
            || hasAny(["backlog", "roadmap", "future"], in: headingLower) {
            return .backlog
        }
        if hasAny(["warning", "careful", "beware", "gotcha", "known issue", "footgun", "danger", "watch out"], in: lower)
            || hasAny(["gotcha", "pitfall", "warning"], in: headingLower) {
            return .concern
        }
        if hasAny(["we chose", "we decided", "decided to", "instead of", "rather than", "went with"], in: lower)
            || headingLower.contains("decision") {
            return .decision
        }
        if isKeyValue(text) || hasAny(["stack", "facts", "environment"], in: headingLower) {
            return .fact
        }
        return .convention
    }

    static func titleFrom(_ text: String) -> String {
        let firstSentence = text.split(separator: ".").first.map(String.init) ?? text
        let flat = firstSentence.replacingOccurrences(of: "`", with: "")
        return flat.count <= 80 ? flat : String(flat.prefix(77)) + "…"
    }

    private static func bulletContent(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        // Numbered bullets: "1. ", "12) "
        if let match = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            return String(line[match.upperBound...])
        }
        return nil
    }

    private static func isKeyValue(_ text: String) -> Bool {
        text.range(of: #"^[\w .\-/]{2,40}:\s+\S"#, options: .regularExpression) != nil
    }

    private static func factParts(_ text: String) -> (key: String, value: String) {
        if let colon = text.firstIndex(of: ":"), text.index(after: colon) < text.endIndex {
            let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty, key.count <= 40 { return (key, value) }
        }
        return (titleFrom(text), text)
    }

    private static func stripGuideBlock(from text: String) -> String {
        // The installer's remover handles both current and pre-rename marker generations.
        MemoryGuideInstaller.removeBlock(from: text)
    }
}
