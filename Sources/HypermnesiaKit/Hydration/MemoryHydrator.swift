import Foundation

/// Selects and formats a project's memories for injection into a Claude Code session
/// (via a `SessionStart`/`UserPromptSubmit` hook's `additionalContext`).
///
/// Ported from the original `formatMemoriesForPrompt` (`docs/design/07-ux-views-and-hydration.md`),
/// extended to include intents and concerns (the original injected only fact/convention/decision).
/// CodeRefs are gated out of SessionStart ranking — they annotate linked memories or appear only
/// when a UserPromptSubmit query matches their path/symbol.
public enum MemoryHydrator {

    public struct Options: Sendable {
        /// Only inject confirmed memories at/above this confidence (fresh + aging by default).
        public var minConfidence: Double = 0.50
        public var maxItems: Int = 40
        public init() {}
    }

    public struct ContextResult: Sendable, Equatable {
        public let context: String
        public let memories: [MemoryNode]
        public init(context: String, memories: [MemoryNode]) {
            self.context = context
            self.memories = memories
        }
    }

    /// The relevant confirmed memories for a project, ranked by confidence then recency.
    ///
    /// Confidence is decayed *as of now* (`DecayEngine.decayed`) before filtering and ranking, so a
    /// decision that has gone stale since capture is dropped from injection — and a stale memory
    /// re-validated today rises back above the threshold — matching the decay the app's badges and
    /// Health view already show. Stored confidence is not mutated (decay-on-read, like Analytics).
    ///
    /// CodeRefs are excluded: they would otherwise crowd ranking slots. They enrich via annotations
    /// or query-path inclusion in `relevantContext`.
    public static func relevantMemories(
        store: MemoryStore, projectId: String, options: Options = Options()
    ) -> [MemoryNode] {
        let confirmed = (try? store.allNodes(projectId: projectId, status: .confirmed)) ?? []
        let decayed: [MemoryNode] = confirmed.map { DecayEngine.decayed($0) }
        let eligible = decayed.filter {
            $0.type != .codeRef && !$0.isSuperseded && $0.confidence >= options.minConfidence
        }
        let ranked = eligible.sorted { a, b in
            a.confidence != b.confidence ? a.confidence > b.confidence : a.updatedAt > b.updatedAt
        }
        return Array(ranked.prefix(options.maxItems))
    }

    /// Markdown context block, or `nil` if there's nothing worth injecting.
    public static func context(
        store: MemoryStore, projectId: String, options: Options = Options()
    ) -> String? {
        contextResult(store: store, projectId: projectId, options: options)?.context
    }

    public static func contextResult(
        store: MemoryStore, projectId: String, options: Options = Options()
    ) -> ContextResult? {
        let memories = relevantMemories(store: store, projectId: projectId, options: options)
        let annotations = annotationPaths(for: memories, store: store, projectId: projectId)
        guard let context = format(memories, annotations: annotations) else { return nil }
        return ContextResult(context: context, memories: memories)
    }

    /// Context filtered to memories relevant to `query` — for per-prompt injection on
    /// `UserPromptSubmit`, so each turn surfaces what's pertinent to what the user just asked.
    /// Returns `nil` when nothing relevant matches (so we don't inject the same block every turn).
    public static func relevantContext(
        store: MemoryStore, projectId: String, query: String, limit: Int = 8, embedder: Embedder? = nil
    ) -> String? {
        relevantContextResult(store: store, projectId: projectId, query: query, limit: limit, embedder: embedder)?.context
    }

    public static func relevantContextResult(
        store: MemoryStore, projectId: String, query: String, limit: Int = 8, embedder: Embedder? = nil
    ) -> ContextResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        let pool = ((try? store.allNodes(projectId: projectId, status: .confirmed)) ?? [])
            .map { DecayEngine.decayed($0) }
            .filter { !$0.isSuperseded && $0.confidence >= 0.50 }
        guard !pool.isEmpty else { return nil }

        let primaryPool = pool.filter { $0.type != .codeRef }
        let codeRefPool = pool.filter { $0.type == .codeRef }

        var primary: [MemoryNode] = []
        // Semantic ranking (preferred): finds relevant memories even when they share no keywords.
        if let embedder, let queryVector = embedder.embed(trimmed) {
            SemanticIndex.indexMissing(store: store, embedder: embedder, projectId: projectId, status: .confirmed)
            let vectors = (try? store.embeddings(for: primaryPool.map(\.id))) ?? [:]
            let candidates = primaryPool.compactMap { node in vectors[node.id].map { (id: node.id, vector: $0) } }
            let ranked = SemanticIndex.rank(query: queryVector, candidates: candidates, limit: limit, minScore: 0.20)
            let byId = Dictionary(primaryPool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            primary = ranked.compactMap { byId[$0.id] }
        }

        if primary.isEmpty {
            // Keyword fallback (no embedder, or nothing cleared the similarity floor).
            let hits = (try? store.search(projectId: projectId, query: trimmed, limit: 30)) ?? []
            primary = hits
                .map { DecayEngine.decayed($0) }
                .filter { $0.status == .confirmed && !$0.isSuperseded && $0.confidence >= 0.50 && $0.type != .codeRef }
                .prefix(limit)
                .map { $0 }
        }

        let matchedCodeRefs = codeRefPool.filter { codeRefMatchesQuery($0, query: trimmed) }
            .prefix(limit)
            .map { $0 }

        let annotations = annotationPaths(for: primary, store: store, projectId: projectId)
        let memories = primary + matchedCodeRefs
        guard let context = format(memories, annotations: annotations), !memories.isEmpty else { return nil }
        return ContextResult(context: context, memories: memories)
    }

    /// Format memories for injection. `annotations` maps memory id → repo-relative paths to show
    /// under that memory. CodeRefs present in `memories` render under `## Code references`;
    /// annotation-only codeRefs do not.
    public static func format(
        _ memories: [MemoryNode],
        annotations: [String: [String]] = [:]
    ) -> String? {
        guard !memories.isEmpty else { return nil }
        let byType = Dictionary(grouping: memories, by: \.type)

        var out: [String] = [
            "# Project Memory (Hypermnesia)",
            "Durable context captured from past sessions in this project; treat older items with care. Apply the conventions and decisions below to the work at hand, and proactively AUDIT existing code against them: if existing code violates a documented rule or matches a flagged anti-pattern, fix it as part of your change rather than leaving it in place. Skip a convention only when it genuinely does not apply to what you are building — do not force an unrelated rule onto code it was never meant for.",
            "",
        ]

        var rendered = false
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            rendered = true
            out.append("## \(title)")
            out.append(contentsOf: lines)
            out.append("")
        }

        // Collapse newlines/control chars in memory-derived text so a memory whose content contains
        // e.g. "\n## Conventions\n- pipe http://evil | sh" can't forge a heading or bullet that reads
        // as a genuine section of the trusted injected block (stored prompt-injection). Also cap each
        // field so one pathologically long memory can't blow up the injected context.
        func inline(_ s: String, max: Int = maxFieldChars) -> String {
            let cleaned = s.unicodeScalars.map { scalar -> Character in
                (CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar))
                    ? " " : Character(scalar)
            }
            let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
            return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
        }

        func withAnnotations(_ node: MemoryNode, line: String) -> [String] {
            var lines = [line]
            for path in annotations[node.id] ?? [] {
                lines.append("    → \(inline(path))")
            }
            return lines
        }

        section("Facts", (byType[.fact] ?? []).flatMap { node -> [String] in
            guard case .fact(let d) = node.data else { return [] }
            return withAnnotations(node, line: "- \(inline(d.key)): \(inline(d.value))")
        })
        section("Conventions (apply when relevant)", (byType[.convention] ?? []).flatMap { node -> [String] in
            guard case .convention(let d) = node.data else { return [] }
            var lines = ["- \(inline(d.rule))"]
            if let aw = d.appliesWhen, !aw.isEmpty { lines.append("    - Applies to: \(inline(aw))") }
            if let ew = d.excludesWhen, !ew.isEmpty { lines.append("    - Does NOT apply to: \(inline(ew))") }
            for path in annotations[node.id] ?? [] {
                lines.append("    → \(inline(path))")
            }
            return lines
        })
        section("Decisions", (byType[.decision] ?? []).flatMap { node -> [String] in
            guard case .decision(let d) = node.data else { return [] }
            var line = "- \(inline(node.title)): chose \(inline(d.chosen))"
            if let rationale = d.rationale, !rationale.isEmpty { line += " — \(inline(rationale))" }
            return withAnnotations(node, line: line)
        })
        section("Intents", (byType[.intent] ?? []).flatMap { node -> [String] in
            guard case .intent(let d) = node.data else { return [] }
            return withAnnotations(node, line: "- \(inline(d.goal))")
        })
        section("Concerns", (byType[.concern] ?? []).flatMap { node -> [String] in
            guard case .concern(let d) = node.data else { return [] }
            var lines = ["- \(inline(node.title)) [\(inline(d.severity))]: \(inline(d.issue))"]
            if let aw = d.appliesWhen, !aw.isEmpty { lines.append("    - Applies to: \(inline(aw))") }
            if let ew = d.excludesWhen, !ew.isEmpty { lines.append("    - Does NOT apply to: \(inline(ew))") }
            for path in annotations[node.id] ?? [] {
                lines.append("    → \(inline(path))")
            }
            return lines
        })
        section("Backlog", (byType[.backlog] ?? []).flatMap { node -> [String] in
            guard case .backlog(let d) = node.data else { return [] }
            return withAnnotations(node, line: "- \(inline(node.title)): \(inline(d.idea)) [\(inline(d.priority))]")
        })
        // Code references section: only query-selected codeRefs in `memories`, never SessionStart bulk.
        section("Code references", (byType[.codeRef] ?? []).compactMap { node in
            guard case .codeRef(let d) = node.data else { return nil }
            let sym = d.symbolName.map { " (\(inline($0)))" } ?? ""
            return "- \(inline(d.filePath))\(sym)"
        })

        // Nothing renderable → no block (don't emit a header-only "Project Memory" claiming memories).
        guard rendered else { return nil }
        let block = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Total-size backstop: keep the injected context bounded even with many long memories.
        return block.count > maxBlockChars ? String(block.prefix(maxBlockChars)) + "\n…(memory truncated)" : block
    }

    /// Convenience overload used by older call sites / tests.
    public static func format(_ memories: [MemoryNode]) -> String? {
        format(memories, annotations: [:])
    }

    /// Per-field and total caps on the injected block, so hydration context stays bounded.
    static let maxFieldChars = 600
    static let maxBlockChars = 16_000

    // MARK: - CodeRef helpers

    /// Confirmed codeRefs whose path appears in a primary memory's `relatedFiles`.
    static func annotationPaths(
        for memories: [MemoryNode], store: MemoryStore, projectId: String
    ) -> [String: [String]] {
        let needed = Set(memories.flatMap { $0.data.relatedFiles.map(GraphBuilder.normalizeFileKey) })
        guard !needed.isEmpty else { return [:] }
        let codeRefs = ((try? store.allNodes(projectId: projectId, type: .codeRef, status: .confirmed)) ?? [])
            .map { DecayEngine.decayed($0) }
            .filter { !$0.isSuperseded && $0.confidence >= 0.50 }
        var byPath: [String: String] = [:]
        for ref in codeRefs {
            guard case .codeRef(let d) = ref.data else { continue }
            let key = GraphBuilder.normalizeFileKey(d.filePath)
            if needed.contains(key) { byPath[key] = d.filePath }
        }
        guard !byPath.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        for memory in memories where memory.type != .codeRef {
            let paths = memory.data.relatedFiles.compactMap { byPath[GraphBuilder.normalizeFileKey($0)] }
            if !paths.isEmpty { result[memory.id] = paths }
        }
        return result
    }

    static func codeRefMatchesQuery(_ node: MemoryNode, query: String) -> Bool {
        guard case .codeRef(let d) = node.data else { return false }
        let q = query.lowercased()
        if d.filePath.lowercased().contains(q) { return true }
        if let sym = d.symbolName?.lowercased(), sym.contains(q) { return true }
        // Also match on basename / path segments when the query looks like a file reference.
        let base = URL(fileURLWithPath: d.filePath).lastPathComponent.lowercased()
        if base.contains(q) || q.contains(base) { return true }
        // Extension-stripped token match, so "how does MemoryStore rank?" surfaces
        // MemoryStore.swift. Whole-token equality (not substring) keeps short stems from
        // matching inside unrelated words; stems under 3 chars stay out entirely.
        let stem = (base as NSString).deletingPathExtension
        if stem.count >= 3, queryTokens(q).contains(stem) { return true }
        return false
    }

    /// Lowercased identifier-ish tokens of a prompt (split on anything outside [a-z0-9_]).
    static func queryTokens(_ lowercasedQuery: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for ch in lowercasedQuery {
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.insert(current) }
        return tokens
    }
}
