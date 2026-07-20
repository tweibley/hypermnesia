import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("CodeRefExtractor")
struct CodeRefExtractorTests {

    private let root = "/Users/x/proj"
    private let projectId = "path:/Users/x/proj"

    private func event(cwd: String? = "/Users/x/proj", uses: [ToolUse]) -> TranscriptEvent {
        TranscriptEvent(
            role: .assistant, timestamp: Date(), cwd: cwd, gitBranch: "main",
            isSidechain: false, textBlocks: [], toolUses: uses, toolResults: []
        )
    }

    private func edit(_ path: String, snippet: String? = "body", name: String = "Edit") -> ToolUse {
        ToolUse(id: nil, name: name, label: "\(name)(\(URL(fileURLWithPath: path).lastPathComponent))",
                editedFilePath: path, editSnippet: snippet)
    }

    @Test("normalizes absolute paths under project root; drops outside paths")
    func pathNormalization() {
        #expect(CodeRefExtractor.normalize(
            path: "/Users/x/proj/Sources/DB.swift", projectRoot: root, cwd: root
        ) == "Sources/DB.swift")
        #expect(CodeRefExtractor.normalize(
            path: "/tmp/scratch.swift", projectRoot: root, cwd: root
        ) == nil)
        #expect(CodeRefExtractor.normalize(
            path: "Sources/DB.swift", projectRoot: root, cwd: root
        ) == "Sources/DB.swift")
        #expect(CodeRefExtractor.normalize(
            path: "../other/x.swift", projectRoot: root, cwd: root
        ) == nil)
    }

    @Test("denylist skips lockfiles, generated files, and secrets — but not dot-dirs like .github")
    func denylist() {
        #expect(CodeRefExtractor.isDenied("package-lock.json"))
        #expect(CodeRefExtractor.isDenied("node_modules/lodash/index.js"))
        #expect(CodeRefExtractor.isDenied("Sources/Foo.generated.swift"))
        #expect(CodeRefExtractor.isDenied(".env"))
        #expect(CodeRefExtractor.isDenied("config/.env.local"))
        #expect(CodeRefExtractor.isDenied(".npmrc"))
        #expect(CodeRefExtractor.isDenied("Sources/.cache/x.swift"))
        #expect(!CodeRefExtractor.isDenied("Sources/DB.swift"))
        // Dot-prefixed project code is real code — gitignore, not a blanket rule, judges it.
        #expect(!CodeRefExtractor.isDenied(".github/workflows/release.yml"))
        #expect(!CodeRefExtractor.isDenied(".gitignore"))
    }

    @Test("relative paths resolve against a subdirectory cwd, not the repo root")
    func subdirectoryCwdNormalization() {
        #expect(CodeRefExtractor.normalize(
            path: "public/index.html", projectRoot: root, cwd: "/Users/x/proj/site"
        ) == "site/public/index.html")
        // cwd-joined escapes above the root are rejected.
        #expect(CodeRefExtractor.normalize(
            path: "../../other/x.swift", projectRoot: root, cwd: "/Users/x/proj/site"
        ) == nil)
    }

    @Test("gitIgnored respects the repo's .gitignore; fails open without a repo")
    func gitignoreFilter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: [String]) throws {
            let r = Shell.run("git", ["-C", dir.path] + args, cwd: dir.path)
            guard r.succeeded else { throw NSError(domain: "git", code: Int(r.status)) }
        }
        try git(["init"])
        try Data(".claude/\nlocal-notes.md\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))

        let ignored = CodeRefExtractor.gitIgnored(
            [".claude/settings.json", "local-notes.md", "Sources/DB.swift", ".github/ci.yml"],
            repoRoot: dir.path
        )
        #expect(ignored == [".claude/settings.json", "local-notes.md"])
        // Nonexistent root → no git noise judgment, static rules stand alone.
        #expect(CodeRefExtractor.gitIgnored(["a.swift"], repoRoot: "/nonexistent/xyz").isEmpty)
        #expect(CodeRefExtractor.gitIgnored(["a.swift"], repoRoot: nil).isEmpty)
    }

    @Test("extracts one node per distinct path with title=basename and summary=relative path")
    func extractsDistinctPaths() {
        let events = [
            event(uses: [
                edit("/Users/x/proj/Sources/DB.swift", snippet: "struct DB {}"),
                edit("/Users/x/proj/Sources/DB.swift", snippet: "struct DB { var x: Int }"),
                edit("/Users/x/proj/Sources/Schema.swift"),
            ])
        ]
        let nodes = CodeRefExtractor.extract(
            from: events, projectId: projectId, sessionId: "s1",
            createdAt: Date(), commitSha: "abc", branch: "main", projectRoot: root
        )
        #expect(nodes.count == 2)
        let db = nodes.first { $0.summary == "Sources/DB.swift" }
        #expect(db?.title == "DB.swift")
        #expect(db?.status == .draft)
        #expect(db?.belief == CodeRefExtractor.observedConfidence)
        if case .codeRef(let d) = db?.data {
            #expect(d.filePath == "Sources/DB.swift")
            #expect(d.snippet == "struct DB { var x: Int }")
        } else {
            Issue.record("expected codeRef payload")
        }
    }

    @Test("caps distinct files per session, preferring most-edited")
    func capsPreferMostEdited() {
        var uses: [ToolUse] = []
        // 12 files, first one edited 5× so it must survive the cap.
        uses.append(contentsOf: (0..<5).map { _ in edit("/Users/x/proj/Hot.swift") })
        for i in 1...11 {
            uses.append(edit("/Users/x/proj/File\(i).swift"))
        }
        let nodes = CodeRefExtractor.extract(
            from: [event(uses: uses)], projectId: projectId, sessionId: "s",
            createdAt: Date(), projectRoot: root
        )
        #expect(nodes.count == CodeRefExtractor.maxFilesPerSession)
        #expect(nodes.contains { $0.summary == "Hot.swift" })
    }

    @Test("env override parses truthy values")
    func envGate() {
        #expect(!CodeRefExtractor.isEnabled(nil))
        #expect(!CodeRefExtractor.isEnabled(""))
        #expect(!CodeRefExtractor.isEnabled("0"))
        #expect(!CodeRefExtractor.isEnabled("false"))
        #expect(CodeRefExtractor.isEnabled("1"))
        #expect(CodeRefExtractor.isEnabled("true"))
    }

    @Test("the captureCodeRefs setting decides; a set env var overrides it either way")
    func settingWithEnvOverride() {
        let on = AppConfig(captureCodeRefs: true)
        let off = AppConfig(captureCodeRefs: false)
        // No env: the persisted setting decides.
        #expect(CodeRefExtractor.isEnabled(env: nil, config: on))
        #expect(!CodeRefExtractor.isEnabled(env: nil, config: off))
        #expect(!CodeRefExtractor.isEnabled(env: "  ", config: off))   // blank = unset
        // Env set: it wins in both directions (dev escape hatch).
        #expect(CodeRefExtractor.isEnabled(env: "1", config: off))
        #expect(!CodeRefExtractor.isEnabled(env: "0", config: on))
    }

    @Test("DedupEngine matches codeRefs by exact filePath, not Jaccard title")
    func pathKeyedDedup() {
        let a = MemoryNode(
            projectId: projectId, type: .codeRef, title: "Foo.swift", summary: "Sources/Foo.swift",
            data: .codeRef(.init(filePath: "Sources/Foo.swift"))
        )
        let same = MemoryNode(
            projectId: projectId, type: .codeRef, title: "Foo.swift", summary: "Sources/Foo.swift",
            data: .codeRef(.init(filePath: "Sources/Foo.swift"))
        )
        let other = MemoryNode(
            projectId: projectId, type: .codeRef, title: "Foo.swift", summary: "Tests/Foo.swift",
            data: .codeRef(.init(filePath: "Tests/Foo.swift"))
        )
        #expect(DedupEngine.isDuplicate(a, same))
        #expect(!DedupEngine.isDuplicate(a, other))
    }

    @Test("reconcile: first codeRef stays draft despite high confidence; second sighting confirms")
    func autoConfirmViaSightings() throws {
        let store = try MemoryStore(location: .inMemory)
        let when = Date()
        let draft = MemoryNode(
            projectId: projectId, type: .codeRef, status: .draft,
            title: "DB.swift", summary: "Sources/DB.swift",
            data: .codeRef(.init(filePath: "Sources/DB.swift", snippet: "v1")),
            confidence: 0.9, belief: 0.9, createdAt: when, commitSha: "aaa"
        )
        let fresh = SessionIngestor.reconcile(
            [draft], projectId: projectId, store: store,
            autoConfirm: 1, confirmConfident: true, observationAt: when
        )
        #expect(fresh.count == 1)
        #expect(fresh[0].status == .draft)
        try store.upsert(fresh)

        let again = MemoryNode(
            projectId: projectId, type: .codeRef, status: .draft,
            title: "DB.swift", summary: "Sources/DB.swift",
            data: .codeRef(.init(filePath: "Sources/DB.swift", snippet: "v2")),
            confidence: 0.9, belief: 0.9, createdAt: when, commitSha: "bbb"
        )
        let second = SessionIngestor.reconcile(
            [again], projectId: projectId, store: store,
            autoConfirm: 1, confirmConfident: true, observationAt: when
        )
        #expect(second.isEmpty)
        let stored = try #require(try store.allNodes(projectId: projectId, type: .codeRef).first)
        #expect(stored.status == .confirmed)
        #expect(stored.timesSighted == 1)
        #expect(stored.commitSha == "bbb")
        if case .codeRef(let d) = stored.data {
            #expect(d.snippet == "v2")
        } else {
            Issue.record("expected codeRef")
        }
    }

    @Test("re-ingest same path does not create a second node")
    func idempotentSighting() throws {
        let store = try MemoryStore(location: .inMemory)
        let when = Date()
        func candidate() -> MemoryNode {
            MemoryNode(
                projectId: projectId, type: .codeRef, status: .draft,
                title: "DB.swift", summary: "Sources/DB.swift",
                data: .codeRef(.init(filePath: "Sources/DB.swift")),
                confidence: 0.9, createdAt: when
            )
        }
        try store.upsert(SessionIngestor.reconcile(
            [candidate()], projectId: projectId, store: store,
            autoConfirm: 2, observationAt: when
        ))
        _ = SessionIngestor.reconcile(
            [candidate()], projectId: projectId, store: store,
            autoConfirm: 2, observationAt: when
        )
        let all = try store.allNodes(projectId: projectId, type: .codeRef)
        #expect(all.count == 1)
        #expect(all[0].timesSighted == 1)
        #expect(all[0].status == .draft) // autoConfirm=2; only one reinforcement so far
    }
}
