import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("MemoryQA")
struct MemoryQATests {

    /// Records whether it was invoked; returns a canned answer.
    private final class StubCompleter: Completer, @unchecked Sendable {
        private let lock = NSLock()
        private var invoked = false
        var wasInvoked: Bool { lock.lock(); defer { lock.unlock() }; return invoked }
        private func markInvoked() { lock.lock(); invoked = true; lock.unlock() }
        func complete(system: String, user: String) async throws -> String {
            markInvoked()
            return "stubbed answer"
        }
    }

    private func node(
        project: String, title: String, supersededById: String? = nil
    ) -> MemoryNode {
        MemoryNode(
            projectId: project, type: .convention, status: .confirmed,
            title: title, summary: "summary",
            data: .convention(.init(rule: title)),
            supersededById: supersededById
        )
    }

    @Test("recent-confirmed top-up excludes superseded memories")
    func topUpExcludesSuperseded() async throws {
        let store = try MemoryStore(location: .inMemory)
        let project = "github.com/acme/app"
        let active = node(project: project, title: "Use tabs for indentation")
        let superseded = node(project: project, title: "Use spaces for indentation",
                              supersededById: active.id)
        try store.upsert(active)
        try store.upsert(superseded)

        // A question with no lexical overlap, so FTS retrieval finds nothing and the answer pool
        // is filled entirely by the recent-confirmed top-up — the path under test.
        let answer = try await MemoryQA.ask(
            "zzz unrelated query qqq", store: store, projectId: project, completer: StubCompleter()
        )

        let sourceIds = Set(answer.sources.map(\.id))
        #expect(sourceIds.contains(active.id))
        #expect(!sourceIds.contains(superseded.id))
    }

    @Test("a project whose only memories are superseded answers 'no memories' without calling the model")
    func allSupersededMeansNoSources() async throws {
        let store = try MemoryStore(location: .inMemory)
        let project = "github.com/acme/app"
        let superseded = node(project: project, title: "Old rule", supersededById: "some-newer-id")
        try store.upsert(superseded)

        let completer = StubCompleter()
        let answer = try await MemoryQA.ask(
            "what are the conventions?", store: store, projectId: project, completer: completer
        )

        #expect(answer.sources.isEmpty)
        #expect(!completer.wasInvoked)
    }
}
