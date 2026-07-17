import Foundation

/// A minimal [Model Context Protocol](https://modelcontextprotocol.io) server over JSON-RPC 2.0.
/// Exposes the local memory to any MCP client (Cursor, Claude Desktop, custom agents) via three
/// tools: `recall`, `ask`, and `remember`. The stdio read/write loop lives in the CLI; this type is
/// pure request→response so it can be unit-tested.
public struct MCPHandler: Sendable {
    let store: MemoryStore
    let serverName = "hypermnesia"
    let serverVersion = Hypermnesia.version

    public init(store: MemoryStore) { self.store = store }

    /// Handle one JSON-RPC message. Returns the response object, or `nil` for notifications.
    public func handle(_ message: [String: Any]) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        // A JSON-RPC notification is defined by the ABSENCE of `id` (and conventionally `notifications/*`);
        // the server MUST NOT respond to one.
        let isNotification = id == nil || method.hasPrefix("notifications/")
        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": (params(message)["protocolVersion"] as? String) ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion],
                // Protocol-native usage hint. Clients MAY surface this to the model. On its own it's a
                // weak nudge (eval: mcp_only recall ~0→17%); a CLAUDE.md instruction is far stronger.
                "instructions": "This server exposes this project's durable memory captured from past "
                    + "coding sessions — its decisions, conventions, and known gotchas (anti-patterns "
                    + "to avoid). BEFORE writing or editing code for a task, call `recall` with a short "
                    + "description of what you are about to do, load the relevant rules, and follow "
                    + "them. Call `remember` to store a new durable decision or convention (saved "
                    + "as a draft the user confirms before it is injected anywhere).",
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": Self.toolDefinitions])
        case "tools/call":
            return await callTool(id: id, params: params(message))
        default:
            return isNotification ? nil : error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    static var toolDefinitions: [[String: Any]] { [
        [
            "name": "recall",
            "description": "Recall the most relevant project memories (decisions, conventions, facts, concerns) for a query. Use before writing code to follow established patterns.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What you want to recall about the project."],
                    "project": ["type": "string", "description": "Repo path or project id. Defaults to the current directory."],
                    "limit": ["type": "integer", "description": "Max memories to return (default 8)."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "ask",
            "description": "Ask a natural-language question about a project; returns a synthesized answer grounded in its memories.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string"],
                    "project": ["type": "string", "description": "Repo path or project id. Defaults to the current directory."],
                ],
                "required": ["question"],
            ],
        ],
        [
            "name": "remember",
            "description": "Store a durable project memory (a decision, convention, intent, fact, concern, or backlog item). Saved as a draft; the user confirms it in the app before it is ever injected into a session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "enum": ["decision", "convention", "intent", "fact", "concern", "backlog"]],
                    "title": ["type": "string"],
                    "summary": ["type": "string"],
                    "project": ["type": "string", "description": "Repo path or project id. Defaults to the current directory."],
                ],
                "required": ["type", "title", "summary"],
            ],
        ],
    ] }

    private func callTool(id: Any?, params: [String: Any]) async -> [String: Any]? {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "recall":  return toolResult(id, await recall(args))
        case "ask":     return toolResult(id, await ask(args))
        case "remember":
            let outcome = remember(args)
            return toolResult(id, outcome.text, isError: outcome.isError)
        default:        return error(id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private func recall(_ args: [String: Any]) async -> String {
        guard let query = args["query"] as? String, !query.isEmpty else { return "Provide a `query`." }
        let startedAt = Date()
        let projectId = resolveProject(args["project"] as? String)
        // Clamp to a sane range: a negative limit would trap in `prefix`, crashing the server.
        let limit = min(max(args["limit"] as? Int ?? 8, 1), 50)
        let result = MemoryHydrator.relevantContextResult(
            store: store, projectId: projectId, query: query, limit: limit, embedder: AppleEmbedder()
        )
        if let result {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            MemoryActivityLog.append(.init(
                projectId: projectId,
                eventType: .recall,
                memoryIds: result.memories.map(\.id),
                count: result.memories.count,
                latencyMs: elapsedMs,
                metadata: ["source": "mcp"]
            ))
            return result.context
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        MemoryActivityLog.append(.init(
            projectId: projectId,
            eventType: .recall,
            memoryIds: [],
            count: 0,
            latencyMs: elapsedMs,
            metadata: ["source": "mcp", "empty": "true"]
        ))
        return "No relevant memories for \(projectId)."
    }

    private func ask(_ args: [String: Any]) async -> String {
        guard let question = args["question"] as? String, !question.isEmpty else { return "Provide a `question`." }
        let projectId = resolveProject(args["project"] as? String)
        let answer = try? await MemoryQA.ask(question, store: store, projectId: projectId,
                                             completer: Completers.makeFromConfig(), embedder: AppleEmbedder())
        return answer?.answer ?? "Couldn't answer that."
    }

    private func remember(_ args: [String: Any]) -> (text: String, isError: Bool) {
        guard let typeRaw = args["type"] as? String, let type = MemoryType(rawValue: typeRaw),
              let title = args["title"] as? String, let summary = args["summary"] as? String else {
            return ("Provide `type`, `title`, and `summary`.", true)
        }
        let projectId = resolveProject(args["project"] as? String)
        let data: MemoryData
        switch type {
        case .decision: data = .decision(.init(chosen: summary))
        case .convention: data = .convention(.init(rule: summary))
        case .intent: data = .intent(.init(goal: summary))
        case .fact: data = .fact(.init(category: "state", key: title, value: summary))
        case .concern: data = .concern(.init(issue: summary, severity: "medium"))
        case .backlog: data = .backlog(.init(idea: summary, priority: "medium"))
        case .codeRef: data = .codeRef(.init(filePath: summary))
        }
        // Draft, not confirmed: `remember` is callable by any MCP client (and by an agent steered
        // by whatever it just read), so its writes go through the same human review gate as
        // capture. Drafts are never injected into sessions until confirmed in the app.
        var node = MemoryNode(projectId: projectId, type: type, status: .draft,
                              title: title, summary: summary, data: data)
        // Link a contradicted memory (same topic, different substance) so confirming this draft
        // supersedes it — same revision flow as captured memories.
        let pool = (try? store.nodes(projectId: projectId, limit: 500)) ?? []
        if DedupEngine.duplicate(of: node, in: pool) == nil,
           let conflicting = ConflictEngine.conflict(of: node, in: pool) {
            node.supersedesId = conflicting.id
        }
        do {
            try store.upsert(node)
        } catch {
            // Surface the failure as an MCP error instead of a false "saved" — otherwise the caller
            // believes the memory persisted when the write was lost (disk full, locked db, …).
            return ("Failed to save memory: \(error.localizedDescription). Nothing was stored — please retry.", true)
        }
        MemoryActivityLog.append(.init(
            projectId: projectId,
            eventType: .capture,
            memoryIds: [node.id],
            count: 1,
            metadata: ["source": "mcp_remember"]
        ))
        return ("Saved draft \(type.rawValue) “\(title)” in \(projectId). "
            + "It will be injected into future sessions once confirmed in the review inbox.", false)
    }

    private func resolveProject(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return ProjectIdentity.resolve(cwd: FileManager.default.currentDirectoryPath)
        }
        let expanded = (value as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return ProjectIdentity.resolve(cwd: expanded) }
        return value   // already a project id
    }

    // MARK: - JSON-RPC helpers

    private func params(_ message: [String: Any]) -> [String: Any] {
        message["params"] as? [String: Any] ?? [:]
    }
    private func result(_ id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }
    private func toolResult(_ id: Any?, _ text: String, isError: Bool = false) -> [String: Any] {
        result(id, ["content": [["type": "text", "text": text]], "isError": isError])
    }
    private func error(_ id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
