import ArgumentParser
import Foundation
import HypermnesiaKit

// MARK: - Shared helpers

/// Resolve `--project` to a project id, defaulting to the cwd. Accepts either a repo path (the
/// convention `ask` uses) or an already-resolved project id (`github.com/acme/app`, `path:/…`) so
/// ids printed by `list`/`show` can be pasted straight back in.
func resolveProjectId(_ project: String?) -> String {
    guard let project, !project.isEmpty else {
        return ProjectIdentity.resolve(cwd: FileManager.default.currentDirectoryPath)
    }
    if project.hasPrefix("path:") { return project }
    let expanded = (project as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
        return ProjectIdentity.resolve(cwd: expanded)
    }
    // Not a directory on this machine — treat it as a literal project id (e.g. `github.com/acme/app`).
    return project
}

/// Pretty JSON encoder shared by the `--json` outputs (stable key order for diff-friendly exports).
func memoryJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

/// Find a memory by exact id, or by unique id prefix within the project's memories.
func resolveMemory(idOrPrefix: String, projectId: String, store: MemoryStore) throws -> MemoryNode {
    if let exact = try store.node(id: idOrPrefix) { return exact }
    let candidates = try store.nodes(projectId: projectId, includeDeleted: true, limit: 5000)
        .filter { $0.id.hasPrefix(idOrPrefix) }
    switch candidates.count {
    case 1: return candidates[0]
    case 0: throw ValidationError("No memory with id (or id prefix) '\(idOrPrefix)' in \(projectId).")
    default: throw ValidationError("Id prefix '\(idOrPrefix)' is ambiguous (\(candidates.count) matches) — use more characters.")
    }
}

extension MemoryType: ExpressibleByArgument {}
extension MemoryStatus: ExpressibleByArgument {}

private func oneLine(_ node: MemoryNode) -> String {
    let flags = [
        node.status == .draft ? "draft" : nil,
        node.isSuperseded ? "superseded" : nil,
        node.isDeleted ? "deleted" : nil,
    ].compactMap { $0 }
    let suffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
    let confidence = String(format: "%.2f", node.confidence)
    return "\(node.id.prefix(8))  \(node.type.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))  \(confidence)  \(node.title)\(suffix)"
}

// MARK: - list

/// `hypermnesia list` — the CLI counterpart of the app's memory browser.
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List a project's memories."
    )

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    @Option(name: .long, help: "Filter by type: \(MemoryType.allCases.map(\.rawValue).joined(separator: " | ")).")
    var type: MemoryType?

    @Option(name: .long, help: "Filter by status: draft | confirmed.")
    var status: MemoryStatus?

    @Option(name: .long, help: "Maximum memories to print (newest first).")
    var limit: Int = 50

    @Flag(name: .long, help: "Emit the full records as JSON instead of a table.")
    var json = false

    func run() async throws {
        guard limit > 0 else { throw ValidationError("--limit must be positive.") }
        let projectId = resolveProjectId(project)
        let store = try MemoryStore()
        let nodes = try store.nodes(projectId: projectId, type: type, status: status, limit: limit)
        if json {
            print(String(decoding: try memoryJSONEncoder().encode(nodes), as: UTF8.self))
            return
        }
        guard !nodes.isEmpty else {
            print("No memories for \(projectId).")
            return
        }
        print("\(nodes.count) memorie(s) in \(projectId):")
        for node in nodes { print("  " + oneLine(node)) }
        print("\nUse `hypermnesia show <id>` for detail (id prefixes are fine).")
    }
}

// MARK: - show

/// `hypermnesia show <id>` — full detail for one memory.
struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show one memory in full."
    )

    @Argument(help: "Memory id (a unique prefix works).")
    var id: String

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    @Flag(name: .long, help: "Emit the full record as JSON.")
    var json = false

    func run() async throws {
        let projectId = resolveProjectId(project)
        let store = try MemoryStore()
        let node = try resolveMemory(idOrPrefix: id, projectId: projectId, store: store)
        if json {
            print(String(decoding: try memoryJSONEncoder().encode(node), as: UTF8.self))
            return
        }
        print("id:         \(node.id)")
        print("project:    \(node.projectId)")
        print("type:       \(node.type.rawValue)   status: \(node.status.rawValue)   confidence: \(String(format: "%.2f", node.confidence))")
        print("title:      \(node.title)")
        print("summary:    \(node.summary)")
        print("created:    \(node.createdAt)   updated: \(node.updatedAt)")
        if let supersedes = node.supersedesId { print("supersedes: \(supersedes)") }
        if let by = node.supersededById { print("superseded by: \(by)") }
        if let quote = node.sourceQuote, !quote.isEmpty { print("source:     \(quote)") }
        if node.isDeleted { print("deleted:    yes") }
    }
}

// MARK: - delete

/// `hypermnesia delete <id>` — soft-delete a memory (same tombstone the app's Delete uses).
struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a memory (soft delete; excluded from lists, search, and injection)."
    )

    @Argument(help: "Memory id (a unique prefix works).")
    var id: String

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    func run() async throws {
        let projectId = resolveProjectId(project)
        let store = try MemoryStore()
        let node = try resolveMemory(idOrPrefix: id, projectId: projectId, store: store)
        guard !node.isDeleted else {
            print("Already deleted: \(node.title)")
            return
        }
        try store.softDeleteNode(id: node.id)
        print("Deleted “\(node.title)” (\(node.id.prefix(8))…).")
    }
}

// MARK: - export

/// `hypermnesia export` — dump memories as JSON (backup / migration / inspection).
struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export memories as JSON (stdout, or --output <path>)."
    )

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    @Flag(name: .long, help: "Export every project, not just one.")
    var all = false

    @Flag(name: .long, help: "Include soft-deleted memories.")
    var includeDeleted = false

    @Flag(name: .long, help: "Markdown project digest (confirmed memories only) instead of JSON — shareable/committable.")
    var markdown = false

    @Option(name: .long, help: "Write to a file instead of stdout.")
    var output: String?

    func validate() throws {
        if markdown && all {
            throw ValidationError("--markdown renders one project's digest; drop --all or pick --project.")
        }
        if markdown && includeDeleted {
            throw ValidationError("--markdown exports live memories only; --include-deleted applies to JSON.")
        }
    }

    func run() async throws {
        let store = try MemoryStore()
        if markdown {
            let projectId = resolveProjectId(project)
            let nodes = try store.nodes(projectId: projectId, limit: 100_000)
            let digest = MemoryMarkdown.projectDigest(projectId: projectId, nodes: nodes)
            if let output {
                let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
                try Data(digest.utf8).write(to: url)
                print("Exported project digest to \(url.path).")
            } else {
                print(digest)
            }
            return
        }
        var nodes: [MemoryNode] = []
        if all {
            for projectId in try store.allProjects() {
                nodes += try store.nodes(projectId: projectId, includeDeleted: includeDeleted, limit: 100_000)
            }
        } else {
            nodes = try store.nodes(projectId: resolveProjectId(project), includeDeleted: includeDeleted, limit: 100_000)
        }
        let data = try memoryJSONEncoder().encode(nodes)
        if let output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try data.write(to: url)
            print("Exported \(nodes.count) memorie(s) to \(url.path).")
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

// MARK: - import-claude-md

/// `hypermnesia import-claude-md` — bootstrap draft memories from the conventions a team
/// already wrote down.
struct ImportClaudeMd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-claude-md",
        abstract: "Parse CLAUDE.md (+ .claude/rules/*.md) into draft memories for review."
    )

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    @Flag(name: .long, help: "Show what would be imported without writing.")
    var dryRun = false

    func run() async throws {
        let path = project.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath
        let sources = ClaudeMdImporter.sourceFiles(projectPath: path)
        guard !sources.isEmpty else {
            print("No CLAUDE.md or .claude/rules/*.md found under \(path).")
            throw ExitCode.failure
        }
        let store = try MemoryStore()
        let outcome = try ClaudeMdImporter.importProject(
            projectPath: path, projectId: resolveProjectId(project), store: store, dryRun: dryRun)
        for node in outcome.created {
            print("  [\(node.type.rawValue)] \(node.title)")
        }
        print("\(dryRun ? "Would import" : "Imported") \(outcome.created.count) draft(s); "
              + "skipped \(outcome.duplicatesSkipped) duplicate(s) across \(sources.count) file(s).")
        if !dryRun, !outcome.created.isEmpty {
            print("Review them in the app's inbox — imported drafts are never injected until confirmed.")
        }
    }
}

// MARK: - recall

/// `hypermnesia recall <query>` — the CLI counterpart of the MCP `recall` tool, so the pull path
/// can be exercised (and scripted) without an MCP client.
struct Recall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the memories relevant to a query (what MCP recall would inject)."
    )

    @Argument(help: "What you're about to work on.")
    var query: String

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    @Option(name: .long, help: "Maximum memories to include.")
    var limit: Int = 8

    func run() async throws {
        guard (1...50).contains(limit) else { throw ValidationError("--limit must be between 1 and 50.") }
        let projectId = resolveProjectId(project)
        let store = try MemoryStore()
        let startedAt = Date()
        let result = MemoryHydrator.relevantContextResult(
            store: store, projectId: projectId, query: query, limit: limit, embedder: AppleEmbedder()
        )
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        MemoryActivityLog.append(.init(
            projectId: projectId,
            eventType: .recall,
            memoryIds: result?.memories.map(\.id) ?? [],
            count: result?.memories.count ?? 0,
            latencyMs: elapsedMs,
            metadata: ["source": "cli", "empty": result == nil ? "true" : "false"]
        ))
        print(result?.context ?? "No relevant memories for \(projectId).")
    }
}
