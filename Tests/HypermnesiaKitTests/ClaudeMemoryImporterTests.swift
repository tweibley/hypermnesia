import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Claude auto-memory import")
struct ClaudeMemoryImporterTests {

    private let projectPath = "/Users/dev/widgets"
    private let projectId = "github.com/acme/widgets"

    /// A fake CLAUDE_CONFIG_DIR-style projects tree with an auto-memory dir for `projectPath`.
    private func makeProjectsDir(files: [String: String]) throws -> (root: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ht-cmi-\(UUID().uuidString)", isDirectory: true)
        let memory = root
            .appendingPathComponent(ClaudeCodeSessions.encode(path: projectPath), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: memory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return (root, { try? fm.removeItem(at: root) })
    }

    private func memoryFile(type: String, name: String, description: String, body: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        metadata:
          node_type: memory
          type: \(type)
        ---

        \(body)
        """
    }

    @Test("frontmatter splits into flattened fields plus body; quotes stripped")
    func frontmatterSplit() {
        let (fields, body) = ClaudeMemoryImporter.splitFrontmatter(
            memoryFile(type: "project", name: "db-paths", description: "\"Where the DB lives\"",
                       body: "The queue database lives at ~/Library/Application Support."))
        #expect(fields["name"] == "db-paths")
        #expect(fields["description"] == "Where the DB lives")
        #expect(fields["metadata.type"] == "project")
        #expect(body.contains("queue database"))
        // No fence at all: the whole document is body.
        let (none, plain) = ClaudeMemoryImporter.splitFrontmatter("just notes, no fence")
        #expect(none.isEmpty && plain == "just notes, no fence")
    }

    @Test("frontmatter types map to memory types; description becomes the title")
    func typeMapping() throws {
        func parse(_ type: String, body: String = "Always run the linter before committing changes.") -> MemoryNode? {
            ClaudeMemoryImporter.parse(
                markdown: memoryFile(type: type, name: "lint-rule", description: "Lint before commit", body: body),
                fileName: "lint-rule.md", projectId: projectId)
        }
        let feedback = try #require(parse("feedback"))
        #expect(feedback.type == .convention && feedback.title == "Lint before commit")
        #expect(feedback.status == .draft)

        let reference = try #require(parse("reference", body: "Dashboards: https://grafana.acme.dev/widgets"))
        guard case .fact(let fact) = reference.data else { Issue.record("expected fact"); return }
        #expect(fact.category == "reference" && fact.key == "lint-rule")

        let user = try #require(parse("user", body: "Taylor prefers terse commit messages and tabs."))
        guard case .fact(let userFact) = user.data else { Issue.record("expected fact"); return }
        #expect(userFact.category == "user")

        // `project` memories go through the CLAUDE.md heuristics (this one reads as a decision).
        let project = try #require(parse("project", body: "We chose GRDB instead of raw sqlite3 bindings."))
        #expect(project.type == .decision && project.title == "Lint before commit")

        // Too-thin bodies are dropped, matching the capture validator's floor.
        #expect(parse("project", body: "tiny") == nil)
    }

    @Test("import reads the encoded memory dir, skips MEMORY.md and duplicates, inserts drafts")
    func importProject() throws {
        let (root, cleanup) = try makeProjectsDir(files: [
            "MEMORY.md": "# Memory index\n- [Lint](lint-rule.md) — lint before commit",
            "lint-rule.md": memoryFile(type: "feedback", name: "lint-rule",
                                       description: "Lint before commit",
                                       body: "Always run the linter before committing changes."),
            "db-paths.md": memoryFile(type: "project", name: "db-paths",
                                      description: "Queue DB location",
                                      body: "capture_queue: sqlite table inside memory.db under Application Support."),
        ])
        defer { cleanup() }
        let store = try MemoryStore(location: .inMemory)

        let outcome = try ClaudeMemoryImporter.importProject(
            projectPath: projectPath, projectId: projectId, store: store, projectsDirectory: root)
        #expect(outcome.created.count == 2)   // MEMORY.md index excluded
        #expect(outcome.duplicatesSkipped == 0)
        #expect(try store.allNodes(projectId: projectId).allSatisfy { $0.status == .draft })

        // Re-import: everything already known, nothing inserted twice.
        let again = try ClaudeMemoryImporter.importProject(
            projectPath: projectPath, projectId: projectId, store: store, projectsDirectory: root)
        #expect(again.created.isEmpty && again.duplicatesSkipped == 2)
    }
}
