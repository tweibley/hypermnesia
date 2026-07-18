import Foundation

/// A model that can produce a free-form text answer. Both classifier adapters conform, so NL query
/// uses whatever engine is configured.
public protocol Completer: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// Picks a `Completer` from saved configuration (mirrors `Classifiers.makeFromConfig`).
public enum Completers {
    public static func makeFromConfig(_ config: AppConfig = AppConfigStore.loadBestEffort()) -> Completer {
        switch Classifiers.Kind(rawValue: config.classifier) ?? .auto {
        case .gemini:
            return GeminiClassifier(apiKey: AppConfigStore.resolvedGeminiKey(config) ?? "", model: config.geminiModel)
        case .claude:
            return ClaudeHeadlessClassifier(claudePath: CLIPath.claude(), model: config.claudeModel)
        case .auto:
            if let key = AppConfigStore.resolvedGeminiKey(config) {
                return GeminiClassifier(apiKey: key, model: config.geminiModel)
            }
            return ClaudeHeadlessClassifier(claudePath: CLIPath.claude(), model: config.claudeModel)
        }
    }
}

public struct MemoryAnswer: Sendable {
    public let question: String
    public let answer: String
    public let sources: [MemoryNode]

    public init(question: String, answer: String, sources: [MemoryNode]) {
        self.question = question
        self.answer = answer
        self.sources = sources
    }
}

/// Answers natural-language questions about a project using its memories (retrieve → synthesize).
public enum MemoryQA {
    public static func ask(
        _ question: String, store: MemoryStore, projectId: String, completer: Completer, embedder: Embedder? = nil
    ) async throws -> MemoryAnswer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MemoryAnswer(question: question, answer: "Ask a question about this project.", sources: [])
        }

        // Retrieve relevant memories — semantic when an embedder is available, else FTS — then top up
        // with recent confirmed memories for context.
        // Only confirmed, non-superseded memories are answerable — unconfirmed drafts must not leak
        // through Ask (that would defeat the same human-review gate `remember`/recall enforce).
        var pool: [MemoryNode] = []
        if let embedder, let queryVector = embedder.embed(trimmed) {
            SemanticIndex.indexMissing(store: store, embedder: embedder, projectId: projectId, status: .confirmed)
            let all = ((try? store.nodes(projectId: projectId, status: .confirmed, limit: 400)) ?? [])
                .filter { !$0.isSuperseded }
            let vectors = (try? store.embeddings(for: all.map(\.id))) ?? [:]
            let candidates = all.compactMap { node in vectors[node.id].map { (id: node.id, vector: $0) } }
            let ranked = SemanticIndex.rank(query: queryVector, candidates: candidates, limit: 20, minScore: 0.15)
            let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            pool = ranked.compactMap { byId[$0.id] }
        }
        if pool.isEmpty {
            pool = ((try? store.search(projectId: projectId, query: trimmed, limit: 20)) ?? [])
                .filter { $0.status == .confirmed && !$0.isSuperseded }
        }
        let seen = Set(pool.map(\.id))
        let confirmed = (try? store.nodes(projectId: projectId, status: .confirmed, limit: 40)) ?? []
        pool += confirmed.filter { !seen.contains($0.id) && !$0.isSuperseded }
        let sources = Array(pool.prefix(30))

        guard !sources.isEmpty else {
            return MemoryAnswer(question: question, answer: "There are no memories for this project yet.", sources: [])
        }

        let context = MemoryHydrator.format(sources) ?? ""
        let system = """
        You answer questions about a software project using ONLY the provided project memories. Be \
        concise and concrete. If the memories don't contain the answer, say so plainly rather than \
        guessing. Refer to specific decisions, conventions, or facts where relevant.
        """
        let user = "PROJECT MEMORIES:\n\(context)\n\nQUESTION: \(trimmed)\n\nANSWER:"
        let answer = try await completer.complete(system: system, user: user)
        return MemoryAnswer(question: question, answer: answer, sources: sources)
    }
}
