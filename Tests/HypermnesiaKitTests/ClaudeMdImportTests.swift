import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("ClaudeMdImporter")
struct ClaudeMdImportTests {

    private let project = "github.com/acme/app"

    @Test("bullets classify by heuristic: convention, decision, concern, backlog, fact")
    func typingHeuristics() {
        let md = """
        # Project notes

        - Always use structured logging in services; never print directly.
        - We chose SQLite over Postgres instead of running a server locally.
        - Beware: the staging config is a known issue and bites new contributors.
        - TODO: migrate the settings pane to the new framework eventually.

        ## Stack
        - Database: SQLite via GRDB
        """
        let nodes = ClaudeMdImporter.parse(markdown: md, projectId: project)
        let types = nodes.map(\.type)
        #expect(types == [.convention, .decision, .concern, .backlog, .fact])
        #expect(nodes.allSatisfy { $0.status == .draft })   // review gate: imports never auto-confirm

        guard case .fact(let fact) = nodes[4].data else { Issue.record("fact payload lost"); return }
        #expect(fact.key == "Database")
        #expect(fact.value == "SQLite via GRDB")
        #expect(fact.category == "stack")
    }

    @Test("our own installed guide block is stripped, continuation lines merge, short bullets drop")
    func parsingHygiene() {
        let md = """
        <!-- hypermnesia:memory-guide -->
        BEFORE reading or editing code call the recall tool.
        <!-- /hypermnesia:memory-guide -->

        - Prefer dependency injection over singletons
          for every service type in the app.
        - Tabs.
        """
        let nodes = ClaudeMdImporter.parse(markdown: md, projectId: project)
        #expect(nodes.count == 1)   // guide text gone; "Tabs." under the 12-char floor
        #expect(nodes[0].summary.contains("for every service type"))   // continuation merged
        #expect(!nodes[0].summary.contains("recall tool"))
    }

    @Test("importProject skips near-duplicates of existing memories and writes drafts")
    func importDedupsAgainstStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("""
        - Always use structured logging in services; never print directly.
        - Route all data access through the repository layer in app/repo.py.
        """.utf8).write(to: dir.appendingPathComponent("CLAUDE.md"))

        let store = try MemoryStore(location: .inMemory)
        let existing = MemoryNode(
            projectId: project, type: .convention, status: .confirmed,
            title: "Always use structured logging in services; never print directly",
            summary: "Always use structured logging in services; never print directly.",
            data: .convention(.init(rule: "structured logging")))
        try store.upsert(existing)

        let outcome = try ClaudeMdImporter.importProject(
            projectPath: dir.path, projectId: project, store: store)
        #expect(outcome.created.count == 1)
        #expect(outcome.duplicatesSkipped == 1)
        #expect(try store.nodes(projectId: project, status: .draft).count == 1)

        // Dry run writes nothing: the draft count in the store is unchanged.
        _ = try ClaudeMdImporter.importProject(
            projectPath: dir.path, projectId: project, store: store, dryRun: true)
        #expect(try store.nodes(projectId: project, status: .draft).count == 1)
    }
}
