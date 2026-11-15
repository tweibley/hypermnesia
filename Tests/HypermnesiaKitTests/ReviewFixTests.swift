import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("ReviewFixes")
struct ReviewFixTests {

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-review-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Audit repo path

    @Test("auditRoot resolves a subdirectory to the repo root")
    func auditRootFromSubdirectory() throws {
        let repo = try tempDir("root")
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(Shell.run("git", ["-C", repo.path, "init", "-q"]).succeeded)
        let sub = repo.appendingPathComponent("Sources/Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        #expect(MemoryAuditor.auditRoot(cwd: sub.path) == CanonicalPath.resolve(repo.path))
        #expect(MemoryAuditor.auditRoot(cwd: repo.appendingPathComponent("nope").path) == nil)
    }

    @Test("auditableRepoPath is nil when a path: project's directory is gone")
    func auditableRepoPathRequiresDirectory() throws {
        let dir = try tempDir("auditable")
        #expect(MemoryAuditor.auditableRepoPath(forProjectId: "path:\(dir.path)") == dir.path)
        try FileManager.default.removeItem(at: dir)
        #expect(MemoryAuditor.auditableRepoPath(forProjectId: "path:\(dir.path)") == nil)
        // The plain lookup still answers — code links and path relativizing don't need the directory.
        #expect(MemoryAuditor.repoPath(forProjectId: "path:\(dir.path)") == dir.path)
    }

    @Test("pathInsideRepo rejects absolute paths, .. escapes, and symlinks out of the repo")
    func pathInsideRepoContainment() throws {
        let repo = try tempDir("inside")
        let outside = try tempDir("outside")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("secret.txt")
        try "s".write(to: secret, atomically: true, encoding: .utf8)
        try "a".write(to: repo.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("link.txt"), withDestinationURL: secret)

        #expect(MemoryAuditor.pathInsideRepo("a.swift", repoPath: repo.path) != nil)
        #expect(MemoryAuditor.pathInsideRepo(
            repo.appendingPathComponent("a.swift").path, repoPath: repo.path) != nil)
        #expect(MemoryAuditor.pathInsideRepo(secret.path, repoPath: repo.path) == nil)
        #expect(MemoryAuditor.pathInsideRepo(
            "../\(outside.lastPathComponent)/secret.txt", repoPath: repo.path) == nil)
        #expect(MemoryAuditor.pathInsideRepo("link.txt", repoPath: repo.path) == nil)
    }

    final class RecordingCompleter: Completer, @unchecked Sendable {
        private(set) var prompts: [String] = []
        func complete(system: String, user: String) async throws -> String {
            prompts.append(user)
            return "STILL_TRUE\nfine"
        }
    }

    @Test("deep verify never sends a file outside the repo to the model")
    func verifySkipsOutsideFiles() async throws {
        let repo = try tempDir("verify")
        let outside = try tempDir("verify-out")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("credentials")
        try "TOP-SECRET-VALUE".write(to: secret, atomically: true, encoding: .utf8)
        try "let inRepo = true".write(
            to: repo.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let store = try MemoryStore(location: .inMemory)
        try store.upsert([
            MemoryNode(projectId: "p", type: .decision, status: .confirmed, title: "leaky", summary: "s",
                       data: .decision(.init(chosen: "x", relatedFiles: [secret.path]))),
            MemoryNode(projectId: "p", type: .decision, status: .confirmed, title: "fine", summary: "s",
                       data: .decision(.init(chosen: "y", relatedFiles: ["a.swift", secret.path]))),
        ])
        let completer = RecordingCompleter()
        _ = await MemoryAuditor.verify(
            store: store, projectId: "p", repoPath: repo.path, completer: completer)

        #expect(completer.prompts.count == 1)   // the outside-only memory is skipped entirely
        #expect(completer.prompts.allSatisfy { !$0.contains("TOP-SECRET-VALUE") })
        #expect(completer.prompts.first?.contains("let inRepo = true") == true)
    }

    // MARK: - Hook ownership

    @Test("isOurCommand matches the executable name, not any mention of it")
    func hookCommandOwnership() {
        #expect(HookInstaller.isOurCommand("'/Applications/Hypermnesia.app/Contents/Resources/hypermnesia' hydrate"))
        #expect(HookInstaller.isOurCommand("'/old/path/hyperthymesia' capture"))
        #expect(HookInstaller.isOurCommand("/usr/local/bin/hypermnesia capture; (nohup x &)"))
        #expect(HookInstaller.isOurCommand("hypermnesia session-event"))
        #expect(HookInstaller.isOurCommand("HYPERMNESIA_DEBUG=1 '/a b/hypermnesia' hydrate"))
        #expect(HookInstaller.isOurCommand("'/it'\\''s/hypermnesia' hydrate"))

        #expect(!HookInstaller.isOurCommand("cd ~/hypermnesia && ./scripts/notify.sh"))
        #expect(!HookInstaller.isOurCommand("~/hypermnesia/scripts/notify.sh"))
        #expect(!HookInstaller.isOurCommand("echo hypermnesia"))
        #expect(!HookInstaller.isOurCommand(""))
    }

    @Test("install and uninstall keep a user's hook that only mentions the name")
    func installKeepsLookalikeHooks() throws {
        let dir = try tempDir("hooks")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let mine = "cd ~/hypermnesia && ./scripts/notify.sh"
        let url = HookInstaller.settingsURL(projectPath: dir.path)
        try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": mine]]]]],
        ]).write(to: url)

        #expect(!HookInstaller.isInstalled(projectPath: dir.path))
        try HookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("notify.sh"))
        #expect(HookInstaller.isInstalled(projectPath: dir.path))

        try HookInstaller.uninstall(projectPath: dir.path)
        let after = try ConfigFile.readObject(at: url)
        let stop = try #require((after["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 1)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == mine)
        #expect(!HookInstaller.isInstalled(projectPath: dir.path))
    }

    // MARK: - Sighting auto-confirm gate

    private func convention(conversationId: String?, supersedesId: String? = nil) -> MemoryNode {
        MemoryNode(projectId: "p", type: .convention, status: .draft, title: "Use tabs",
                   summary: "Always use tabs for indentation",
                   data: .convention(.init(rule: "Always use tabs for indentation")), confidence: 0.8,
                   supersedesId: supersedesId, conversationId: conversationId)
    }
    private func sighting() -> MemoryNode {
        MemoryNode(projectId: "p", type: .convention, status: .draft, title: "Tabs",
                   summary: "Always use tabs for indentation in code",
                   data: .convention(.init(rule: "Always use tabs for indentation in code")),
                   conversationId: "s2")
    }

    @Test("a sighting does not confirm a draft that never came from a captured session")
    func sightingDoesNotConfirmRememberDraft() throws {
        let store = try MemoryStore(location: .inMemory)
        let remembered = convention(conversationId: nil)   // what MCP `remember` writes
        try store.upsert(remembered)

        let fresh = SessionIngestor.reconcile([sighting()], projectId: "p", store: store, autoConfirm: 1)
        #expect(fresh.isEmpty)
        let updated = try #require(try store.node(id: remembered.id))
        #expect(updated.status == .draft)
        #expect(updated.timesSighted == 1)   // still reinforced
    }

    @Test("a sighting does not confirm a revision draft or retire the memory it revises")
    func sightingDoesNotConfirmRevision() throws {
        let store = try MemoryStore(location: .inMemory)
        let old = MemoryNode(projectId: "p", type: .convention, status: .confirmed, title: "Indent with spaces",
                             summary: "Four spaces everywhere",
                             data: .convention(.init(rule: "Four spaces everywhere")))
        let revision = convention(conversationId: "s1", supersedesId: old.id)
        try store.upsert([old, revision])

        _ = SessionIngestor.reconcile([sighting()], projectId: "p", store: store, autoConfirm: 1)
        #expect(try store.node(id: revision.id)?.status == .draft)
        #expect(try store.node(id: old.id)?.isSuperseded == false)
    }

    // MARK: - Drain stop on a failing classifier

    final class CountingFailingClassifier: Classifier, @unchecked Sendable {
        private(set) var calls = 0
        func classify(_ conversation: Conversation, recentMemories: [RecentMemoryHint]) async throws -> [ClassifiedMemory] {
            calls += 1
            throw ClassifierError.toolFailed("Not logged in")
        }
    }

    @Test("drain stops after consecutive classifier failures and leaves the rest uncharged")
    func drainStopsOnClassifierOutage() async throws {
        let support = try tempDir("drain")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try MemoryStore(location: .inMemory)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<6 {
            let url = support.appendingPathComponent("t\(index).jsonl")
            let lines = (0..<4).map { i -> String in
                let role = i % 2 == 0 ? "user" : "assistant"
                let content = role == "user" ? "\"message \(i)\"" : "[{\"type\":\"text\",\"text\":\"reply \(i)\"}]"
                return #"{"type":"\#(role)","timestamp":"2026-06-18T10:00:0\#(i).000Z","cwd":"/repo","sessionId":"s\#(index)","message":{"role":"\#(role)","content":\#(content)}}"#
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            var item = CaptureQueueItem(
                sessionId: "s\(index)", projectId: "p", transcriptPath: url.path,
                cwd: "/repo", gitSha: nil, gitBranch: nil, isFinal: true, source: .live)
            item.enqueuedAt = base.addingTimeInterval(Double(index))   // deterministic drain order
            try store.enqueue(item)
        }

        let classifier = CountingFailingClassifier()
        let report = await SessionIngestor.drainQueue(
            store: store, classifier: classifier, limit: 10, lockDirectory: support)

        #expect(classifier.calls == SessionIngestor.classifierFailureLimit)
        #expect(report.stoppedEarly)
        #expect(report.classifierFailures == SessionIngestor.classifierFailureLimit)
        let pending = try store.pendingCaptures(limit: 10)
        #expect(pending.count == 6)   // nothing went terminal
        #expect(pending.filter { $0.attempts == 0 }.count == 6 - SessionIngestor.classifierFailureLimit)
    }

    // MARK: - Store leaks

    @Test("hardDeleteNode removes the node's embedding")
    func hardDeleteRemovesEmbedding() throws {
        let store = try MemoryStore(location: .inMemory)
        let node = MemoryNode(projectId: "p", type: .fact, status: .confirmed, title: "t", summary: "s",
                              data: .fact(.init(category: "state", key: "k", value: "v")))
        try store.upsert(node)
        try store.setEmbedding(nodeId: node.id, model: "m", vector: [1, 2, 3])
        #expect(try store.embeddings(for: [node.id]).count == 1)

        try store.hardDeleteNode(id: node.id)
        #expect(try store.embeddings(for: [node.id]).isEmpty)
    }

    @Test("reassignProject drops a journal row that collides with the target's night")
    func reassignDropsCollidingJournalRows() throws {
        let store = try MemoryStore(location: .inMemory)
        func dream(_ project: String, _ night: String) -> DreamJournalEntry {
            DreamJournalEntry(
                projectId: project, night: night, outcome: .dreamed, narrative: "n",
                payload: DreamPayload(stats: .init(
                    sessionsScanned: 1, memoriesConsidered: 1, classifier: "test", calls: 1)),
                unread: false, calls: 1)
        }
        let kept = dream("to", "2026-06-01")
        try store.upsertDreamEntry(kept)
        try store.upsertDreamEntry(dream("from", "2026-06-01"))   // collides
        try store.upsertDreamEntry(dream("from", "2026-06-02"))   // moves

        try store.reassignProject(from: "from", to: "to")

        #expect(try store.dreamEntries(projectId: "from").isEmpty)
        let nights = try store.dreamEntries(projectId: "to").map(\.night).sorted()
        #expect(nights == ["2026-06-01", "2026-06-02"])
        #expect(try store.dreamEntry(projectId: "to", night: "2026-06-01")?.id == kept.id)
    }
}
