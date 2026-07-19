import Foundation
import Testing
@testable import HypermnesiaKit

// MARK: - Doubles

/// Hermetic stand-in for the model call — canned JSON, or a thrown error.
private struct StubDreamCompleter: DreamCompleter {
    enum Behavior: Sendable {
        case respond(String)
        case fail(String)
    }
    let behavior: Behavior

    func completeJSON(system: String, user: String) async throws -> String {
        switch behavior {
        case .respond(let text): return text
        case .fail(let reason): throw ClassifierError.toolFailed(reason)
        }
    }
}

// MARK: - Fixtures

private func memory(
    _ id: String, projectId: String = "p", type: MemoryType = .fact,
    status: MemoryStatus = .confirmed, title: String? = nil
) -> MemoryNode {
    MemoryNode(
        id: id, projectId: projectId, type: type, status: status,
        title: title ?? "Memory \(id)", summary: "Summary for memory \(id) with real content",
        data: type == .concern
            ? .concern(.init(issue: "Issue for \(id) that is detailed enough", severity: "medium"))
            : .fact(.init(category: "state", key: "key-\(id)", value: "value-\(id)")))
}

private func sessions(_ ids: [String]) -> [DreamSessionInput] {
    ids.map { DreamSessionInput(sessionId: $0, endedAt: Date(), text: "USER: work in session \($0)") }
}

// MARK: - Parser

@Suite("Dream parsing")
struct DreamParserTests {

    @Test("clean JSON parses; malformed epiphanies are skipped, not fatal")
    func lenientParse() throws {
        let text = """
        {"narrative": "Two quiet themes surfaced.",
         "epiphanies": [
            {"kind": "theme", "title": "T", "insight": "I", "memoryIds": ["a","b"], "score": 0.8},
            {"kind": "nonsense-kind", "title": "bad", "insight": "bad"},
            {"kind": "friction", "title": "F", "insight": "I",
             "quotes": [{"sessionId": "s1", "text": "do X"}], "score": 0.7}
         ],
         "proposedMemories": [
            {"type": "fact", "title": "DB", "summary": "SQLite 3.45",
             "context": {"category": "state", "key": "db", "value": "SQLite 3.45"}},
            {"type": "not-a-type", "title": "bad", "summary": "bad"}
         ],
         "proposedSkills": []}
        """
        let draft = try DreamParser.parse(text)
        #expect(draft.narrative == "Two quiet themes surfaced.")
        #expect(draft.epiphanies.count == 2)   // nonsense kind skipped
        #expect(draft.epiphanies[0].kind == .theme)
        #expect(draft.proposedMemories.count == 1)   // bad type skipped
    }

    @Test("fenced output (claude -p path) parses via extractObject")
    func fencedParse() throws {
        let text = """
        Here is the dream:
        ```json
        {"narrative": "n", "epiphanies": [], "proposedMemories": [], "proposedSkills": []}
        ```
        """
        let draft = try DreamParser.parse(text)
        #expect(draft.narrative == "n")
        #expect(draft.epiphanies.isEmpty)
    }

    @Test("garbage throws instead of fabricating an empty dream")
    func garbageThrows() {
        #expect(throws: (any Error).self) { try DreamParser.parse("no json here at all") }
    }
}

// MARK: - Evidence validation

@Suite("Dream evidence gates")
struct DreamValidatorTests {
    private let memoriesById = Dictionary(
        uniqueKeysWithValues: ["a", "b", "c"].map { ($0, memory($0)) })
    private let concernById = Dictionary(uniqueKeysWithValues: [
        ("a", memory("a")), ("k", memory("k", type: .concern)),
    ])

    private func epiphany(
        _ kind: DreamEpiphanyKind, memoryIds: [String] = [], quotes: [DreamQuote] = [],
        score: Double = 0.9
    ) -> DreamEpiphany {
        DreamEpiphany(
            kind: kind, title: "Title", insight: "Insight sentence.",
            memoryIds: memoryIds, quotes: quotes, score: score)
    }

    @Test("theme requires two EXISTING memory ids — a hallucinated id doesn't count")
    func themeEvidence() {
        let valid = DreamValidator.validEpiphanies(
            [epiphany(.theme, memoryIds: ["a", "b"]),
             epiphany(.theme, memoryIds: ["a", "hallucinated"])],
            memoriesById: memoriesById, validSessionIds: [], minScore: 0.55, cap: 5)
        #expect(valid.count == 1)
        #expect(valid[0].memoryIds == ["a", "b"])
    }

    @Test("contradiction keeps exactly the two cited memories")
    func contradictionEvidence() {
        let valid = DreamValidator.validEpiphanies(
            [epiphany(.contradiction, memoryIds: ["a", "b", "c"]),
             epiphany(.contradiction, memoryIds: ["a"])],
            memoriesById: memoriesById, validSessionIds: [], minScore: 0.55, cap: 5)
        #expect(valid.count == 1)
        #expect(valid[0].memoryIds.count == 2)
    }

    @Test("friction requires a verbatim quote from a KNOWN session")
    func frictionEvidence() {
        let valid = DreamValidator.validEpiphanies(
            [epiphany(.friction, quotes: [DreamQuote(sessionId: "s1", text: "always use tabs")]),
             epiphany(.friction, quotes: [DreamQuote(sessionId: "unknown", text: "x")]),
             epiphany(.friction, quotes: [DreamQuote(sessionId: "s1", text: "   ")])],
            memoriesById: memoriesById, validSessionIds: ["s1"], minScore: 0.55, cap: 5)
        #expect(valid.count == 1)
        #expect(valid[0].quotes.count == 1)
    }

    @Test("openThread must cite a concern/backlog/intent memory")
    func openThreadEvidence() {
        let valid = DreamValidator.validEpiphanies(
            [epiphany(.openThread, memoryIds: ["k"]),
             epiphany(.openThread, memoryIds: ["a"])],   // a fact is not an open thread
            memoriesById: concernById, validSessionIds: [], minScore: 0.55, cap: 5)
        #expect(valid.count == 1)
        #expect(valid[0].memoryIds == ["k"])
    }

    @Test("self-score below threshold is dropped before the gate, never padded")
    func scoreThreshold() {
        let valid = DreamValidator.validEpiphanies(
            [epiphany(.theme, memoryIds: ["a", "b"], score: 0.3)],
            memoriesById: memoriesById, validSessionIds: [], minScore: 0.55, cap: 5)
        #expect(valid.isEmpty)
    }

    private func skill(
        slug: String, sessions sessionIds: [String], markdown: String = "---\nname: X\n---\nBody"
    ) -> DreamSkillProposal {
        DreamSkillProposal(
            slug: slug, title: "T", description: "d", rationale: "r", markdown: markdown,
            evidence: sessionIds.map { DreamQuote(sessionId: $0, text: "verbatim from \($0)") })
    }

    @Test("skill proposals require friction in ≥2 DISTINCT sessions")
    func skillTwoSessionGate() {
        let valid = DreamValidator.validSkills(
            [skill(slug: "release-checklist", sessions: ["s1", "s2"]),
             skill(slug: "one-session-only", sessions: ["s1", "s1"])],
            validSessionIds: ["s1", "s2"], inventorySlugs: [], cap: 3)
        #expect(valid.map(\.slug) == ["release-checklist"])
    }

    @Test("existing slug becomes an update; slugs sanitize; cap holds")
    func skillSanitizeAndUpdate() {
        let valid = DreamValidator.validSkills(
            [skill(slug: "Deploy Helper!", sessions: ["s1", "s2"]),
             skill(slug: "existing-skill", sessions: ["s1", "s2"])],
            validSessionIds: ["s1", "s2"], inventorySlugs: ["existing-skill"], cap: 1)
        #expect(valid.count == 1)
        let survivors = DreamValidator.validSkills(
            [skill(slug: "Deploy Helper!", sessions: ["s1", "s2"]),
             skill(slug: "existing-skill", sessions: ["s1", "s2"])],
            validSessionIds: ["s1", "s2"], inventorySlugs: ["existing-skill"], cap: 3)
        #expect(survivors.first { $0.slug == "deploy-helper" } != nil)
        #expect(survivors.first { $0.slug == "existing-skill" }?.updatesExisting == true)
    }

    @Test("slug sanitizer: kebab-case, letters required, bounded")
    func slugSanitizer() {
        #expect(DreamValidator.sanitizeSlug("Deploy Helper!") == "deploy-helper")
        #expect(DreamValidator.sanitizeSlug("--weird__NAME--") == "weird-name")
        #expect(DreamValidator.sanitizeSlug("12345") == nil)   // no letters
        #expect(DreamValidator.sanitizeSlug("!!!") == nil)
    }
}

// MARK: - Runner (end-to-end with a stub model)

@Suite("Dream runner")
struct DreamRunnerTests {

    private func makeStore(memories: [MemoryNode]) throws -> MemoryStore {
        let store = try MemoryStore(location: .inMemory)
        try store.upsert(memories)
        return store
    }

    private func dreamedResponse(citing ids: [String], session: String) -> String {
        let idList = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {"narrative": "The project consolidated around its storage decisions.",
         "epiphanies": [{"kind": "theme", "title": "Storage discipline", "insight": "Both memories point the same way.",
                         "memoryIds": [\(idList)], "sessionIds": ["\(session)"], "score": 0.85}],
         "proposedMemories": [{"type": "fact", "confidence": 0.9, "title": "Nightly cadence",
                               "summary": "Dreams run after the first idle following wake",
                               "context": {"category": "state", "key": "dream-cadence", "value": "idle-after-wake"}}],
         "proposedSkills": []}
        """
    }

    @Test("a dreamed night persists an unread entry, creates DRAFT memories, and records cost")
    func dreamedNight() async throws {
        let store = try makeStore(memories: [memory("a"), memory("b")])
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .respond(dreamedResponse(citing: ["a", "b"], session: "s1"))),
            sessions: sessions(["s1", "s2"]),
            skillInventory: [],
            config: DreamRunConfig(classifierLabel: "gemini (test)"))

        let entry = try #require(result.entry)
        #expect(entry.outcome == .dreamed)
        #expect(entry.unread)
        #expect(entry.calls == 1)
        #expect(entry.payload.epiphanies.count == 1)
        #expect(entry.payload.stats.sessionsScanned == 2)
        #expect(result.callsMade == 1)

        // The proposed memory landed as a DRAFT (never auto-confirmed), tagged to the entry.
        #expect(entry.payload.proposedMemoryIds.count == 1)
        let draftId = try #require(entry.payload.proposedMemoryIds.first)
        let draft = try #require(try store.node(id: draftId))
        #expect(draft.status == .draft)
        #expect(draft.conversationId == entry.id)

        // And the journal row is queryable.
        let fetched = try #require(try store.dreamEntry(projectId: "p", night: entry.night))
        #expect(fetched.id == entry.id)
        #expect(try store.latestDreamNight(projectId: "p") == entry.night)
    }

    @Test("nothing clears the gate → an honest quiet night, not a padded dream")
    func quietNight() async throws {
        let store = try makeStore(memories: [memory("a")])
        let empty = #"{"narrative": "", "epiphanies": [], "proposedMemories": [], "proposedSkills": []}"#
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .respond(empty)),
            sessions: sessions(["s1", "s2"]), skillInventory: [])

        let entry = try #require(result.entry)
        #expect(entry.outcome == .quiet)
        #expect(!entry.unread)
        #expect(entry.narrative == nil)
        #expect(entry.payload.proposedMemoryIds.isEmpty)
    }

    @Test("hallucinated evidence is scrubbed; if nothing survives the night is quiet")
    func hallucinationScrubbed() async throws {
        let store = try makeStore(memories: [memory("a")])
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(
                behavior: .respond(dreamedResponse(citing: ["ghost-1", "ghost-2"], session: "s1"))),
            sessions: sessions(["s1", "s2"]), skillInventory: [])
        let entry = try #require(result.entry)
        #expect(entry.outcome == .quiet)
        // No epiphany survived → no memory drafts either (proposals ride only on a real dream).
        #expect(entry.payload.proposedMemoryIds.isEmpty)
    }

    @Test("a failed model call records a quiet night with the reason — cost is never re-burned")
    func failureIsQuietNotRetried() async throws {
        let store = try makeStore(memories: [memory("a")])
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .fail("network down")),
            sessions: sessions(["s1", "s2"]), skillInventory: [])
        let entry = try #require(result.entry)
        #expect(entry.outcome == .quiet)
        #expect(entry.payload.note?.contains("network down") == true)
        #expect(entry.calls == 1)
        // Tonight now has a row → the calendar-day gate reports not-due.
        let night = try #require(try store.latestDreamNight(projectId: "p"))
        #expect(!DreamScheduler.isDue(lastNight: night, now: Date()))
    }

    @Test("inactive project is skipped BEFORE any model call")
    func preGateSkips() async throws {
        let store = try MemoryStore(location: .inMemory)   // no sessions, no churn
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .fail("must never be called")),
            sessions: [], skillInventory: [])
        #expect(result.entry == nil)
        #expect(result.callsMade == 0)
        #expect(result.skippedReason?.contains("inactive") == true)
        #expect(try store.dreamEntries(projectId: "p").isEmpty)
    }

    @Test("re-dreaming the same night replaces the entry — one row per night")
    func sameNightReplaces() async throws {
        let store = try makeStore(memories: [memory("a"), memory("b")])
        let completer = StubDreamCompleter(
            behavior: .respond(dreamedResponse(citing: ["a", "b"], session: "s1")))
        let first = await DreamRunner.run(
            projectId: "p", store: store, completer: completer,
            sessions: sessions(["s1", "s2"]), skillInventory: [])
        let second = await DreamRunner.run(
            projectId: "p", store: store, completer: completer,
            sessions: sessions(["s1", "s2"]), skillInventory: [])
        #expect(first.entry != nil)
        #expect(second.entry != nil)
        let entries = try store.dreamEntries(projectId: "p")
        #expect(entries.count == 1)
    }

    @Test("memory drafts cap at 5 and known duplicates are not re-proposed")
    func draftCapAndDedupe() async throws {
        var known = memory("a")
        known.title = "Nightly cadence"
        known.summary = "Dreams run after the first idle following wake"
        known.data = .fact(.init(category: "state", key: "dream-cadence", value: "idle-after-wake"))
        let store = try makeStore(memories: [known, memory("b")])

        let distinct: [(String, String)] = [
            ("Deploy region", "Cloud Run deploys to us-east1"),
            ("Test runner", "Vitest executes the browser suite"),
            ("Cache backend", "Redis 7 holds session state"),
            ("Auth provider", "Clerk issues the JWT tokens"),
            ("Log format", "Bunyan emits newline JSON records"),
            ("Build tool", "Turbo orchestrates workspace builds"),
            ("Queue engine", "SQS drains the webhook backlog"),
        ]
        let manyMemories = distinct.enumerated().map { i, pair in
            """
            {"type": "fact", "confidence": 0.9, "title": "\(pair.0)",
             "summary": "\(pair.1)",
             "context": {"category": "state", "key": "fixture-\(i)", "value": "\(pair.1)"}}
            """
        }.joined(separator: ",")
        let response = """
        {"narrative": "n", "epiphanies": [{"kind": "theme", "title": "T", "insight": "I",
          "memoryIds": ["\(known.id)", "\(memory("b").id)"], "score": 0.9}],
         "proposedMemories": [
            {"type": "fact", "confidence": 0.95, "title": "Nightly cadence",
             "summary": "Dreams run after the first idle following wake",
             "context": {"category": "state", "key": "dream-cadence", "value": "idle-after-wake"}},
            \(manyMemories)],
         "proposedSkills": []}
        """
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .respond(response)),
            sessions: sessions(["s1", "s2"]), skillInventory: [])
        let entry = try #require(result.entry)
        #expect(entry.payload.proposedMemoryIds.count == 5)   // cap
        let draftTitles = try entry.payload.proposedMemoryIds
            .compactMap { try store.node(id: $0)?.title }
        #expect(!draftTitles.contains("Nightly cadence"))   // duplicate of a known memory dropped
    }
}

// MARK: - Scheduler

@Suite("Dream scheduler")
struct DreamSchedulerTests {

    @Test("night key is the local calendar day")
    func nightKey() {
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "America/New_York")!
        cal.timeZone = tz
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 23, minute: 59))!
        #expect(DreamScheduler.nightKey(for: date, calendar: cal, timeZone: tz) == "2026-07-18")
    }

    @Test("calendar-day due gate: due until tonight has a row, then not due until tomorrow")
    func dueGate() {
        let now = Date()
        let tonight = DreamScheduler.nightKey(for: now)
        #expect(DreamScheduler.isDue(lastNight: nil, now: now))
        #expect(DreamScheduler.isDue(lastNight: "2001-01-01", now: now))
        #expect(!DreamScheduler.isDue(lastNight: tonight, now: now))
    }

    @Test("guards: idle threshold, battery floor, AC exemption, desktop (no battery) passes")
    func guards() {
        #expect(!DreamScheduler.guardsPass(idleSeconds: 30, onACPower: true, batteryPercent: 90))
        #expect(DreamScheduler.guardsPass(idleSeconds: 300, onACPower: true, batteryPercent: 10))
        #expect(!DreamScheduler.guardsPass(idleSeconds: 300, onACPower: false, batteryPercent: 10))
        #expect(DreamScheduler.guardsPass(idleSeconds: 300, onACPower: false, batteryPercent: 80))
        #expect(DreamScheduler.guardsPass(idleSeconds: 300, onACPower: false, batteryPercent: nil))
    }

    @Test("per-night call cap, 0 = uncapped")
    func callCap() {
        #expect(DreamScheduler.capAllows(callsTonight: 3, cap: 4))
        #expect(!DreamScheduler.capAllows(callsTonight: 4, cap: 4))
        #expect(DreamScheduler.capAllows(callsTonight: 400, cap: 0))
    }

    @Test("projects order most-recently-active first; never-active last")
    func ordering() {
        let now = Date()
        let ordered = DreamScheduler.orderProjects([
            ("stale", now.addingTimeInterval(-86_400 * 9)),
            ("fresh", now),
            ("never", nil),
        ])
        #expect(ordered == ["fresh", "stale", "never"])
    }
}

// MARK: - Skill lifecycle

@Suite("Skill installer")
struct SkillInstallerTests {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func proposal(slug: String = "release-checklist") -> DreamSkillProposal {
        DreamSkillProposal(
            slug: slug, title: "Release checklist", description: "Run the release steps",
            rationale: "Repeated in two sessions",
            markdown: "---\nname: Release checklist\ndescription: Run the release steps\n---\n\n1. Tag\n2. Push",
            evidence: [DreamQuote(sessionId: "s1", text: "a"), DreamQuote(sessionId: "s2", text: "b")])
    }

    @Test("install writes SKILL.md + VERSION 1.0.0, mirrors ONLY detected layouts, records manifest")
    func installProjectScope() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("repo", isDirectory: true)
        // .cursor/skills exists (detected mirror); .claude/skills does not (created as primary).
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".cursor/skills"), withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest.json")

        let record = try SkillInstaller.install(
            proposal(), scope: "project", projectPath: project.path, projectId: "p",
            home: root.appendingPathComponent("home"), manifestURL: manifestURL)

        let primary = project.appendingPathComponent(".claude/skills/release-checklist")
        #expect(FileManager.default.fileExists(atPath: primary.appendingPathComponent("SKILL.md").path))
        let version = try String(
            contentsOf: primary.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(version.trimmingCharacters(in: .whitespacesAndNewlines) == "1.0.0")
        // Mirrored into the DETECTED .cursor layout.
        let mirror = project.appendingPathComponent(".cursor/skills/release-checklist/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: mirror.path))
        #expect(record.mirrorPaths.count == 1)
        // Manifest round-trips.
        let manifest = SkillInstaller.loadManifest(from: manifestURL)
        #expect(manifest.skills.map(\.slug) == ["release-checklist"])
    }

    @Test("user scope mirrors into detected ~/.gemini/skills (Antigravity), not undetected layouts")
    func userScopeGeminiMirror() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gemini/skills"), withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest.json")

        let record = try SkillInstaller.install(
            proposal(), scope: "user", projectPath: nil, projectId: nil,
            home: home, manifestURL: manifestURL)

        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/skills/release-checklist/SKILL.md").path))
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".gemini/skills/release-checklist/SKILL.md").path))
        #expect(record.mirrorPaths.count == 1)   // .cursor/skills was NOT detected → not created
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".cursor/skills").path))
    }

    @Test("no-clobber: an unmanaged same-slug skill is NEVER overwritten by install")
    func noClobber() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let foreign = project.appendingPathComponent(".claude/skills/release-checklist")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("user's own skill".utf8).write(to: foreign.appendingPathComponent("SKILL.md"))
        let manifestURL = root.appendingPathComponent("manifest.json")

        #expect(throws: SkillInstallError.existsUnmanaged(path: foreign.path)) {
            try SkillInstaller.install(
                proposal(), scope: "project", projectPath: project.path, projectId: "p",
                home: root, manifestURL: manifestURL)
        }
        let untouched = try String(
            contentsOf: foreign.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(untouched == "user's own skill")
    }

    @Test("re-installing a managed skill becomes an update: VERSION bumps, content rewrites")
    func updateBumpsVersion() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        _ = try SkillInstaller.install(
            proposal(), scope: "project", projectPath: project.path, projectId: "p",
            home: root, manifestURL: manifestURL)

        var updated = proposal()
        updated.markdown = "---\nname: Release checklist\n---\n\n1. Tag\n2. Push\n3. Announce"
        let record = try SkillInstaller.install(
            updated, scope: "project", projectPath: project.path, projectId: "p",
            home: root, manifestURL: manifestURL)

        #expect(record.version == "1.0.1")
        let dir = project.appendingPathComponent(".claude/skills/release-checklist")
        let markdown = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(markdown.contains("Announce"))
        let version = try String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(version.trimmingCharacters(in: .whitespacesAndNewlines) == "1.0.1")
    }

    @Test("uninstall removes the directory, every mirror, and the manifest record")
    func uninstall() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".cursor/skills"), withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        _ = try SkillInstaller.install(
            proposal(), scope: "project", projectPath: project.path, projectId: "p",
            home: root, manifestURL: manifestURL)

        _ = try SkillInstaller.uninstall(slug: "release-checklist", manifestURL: manifestURL)

        #expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".claude/skills/release-checklist").path))
        #expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".cursor/skills/release-checklist").path))
        #expect(SkillInstaller.loadManifest(from: manifestURL).skills.isEmpty)
    }

    @Test("usage scan honors the watermark: pre-watermark transcripts never count, scans don't double-count")
    func watermarkScan() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.jsonl")
        let fresh = root.appendingPathComponent("fresh.jsonl")
        try Data(#"{"tool":"Skill","skill":"release-checklist"}"#.utf8).write(to: old)
        try Data(#"used /release-checklist here"#.utf8).write(to: fresh)

        let installedAt = Date().addingTimeInterval(-3_600)
        let record = InstalledSkillRecord(
            slug: "release-checklist", title: "Release checklist", version: "1.0.0",
            installedAt: installedAt, updatedAt: installedAt, scope: "project", projectId: "p",
            primaryPath: "/tmp/none", mirrorPaths: [], lastScanAt: installedAt)

        let transcripts = [
            (sessionId: "s-old", url: old, modifiedAt: installedAt.addingTimeInterval(-600)),
            (sessionId: "s-new", url: fresh, modifiedAt: Date()),
        ]
        let first = SkillInstaller.scanUsage(record: record, transcripts: transcripts)
        #expect(first.newSessions == 1)              // only the post-watermark transcript
        #expect(first.record.sessionsSeenUsed == 1)

        // Second scan from the advanced watermark: nothing new → zero, no double count.
        let second = SkillInstaller.scanUsage(record: first.record, transcripts: transcripts)
        #expect(second.newSessions == 0)
        #expect(second.record.sessionsSeenUsed == 1)
    }

    @Test("slug mentions match at word boundaries only")
    func mentionBoundaries() {
        #expect(SkillInstaller.mentionsSkill("ran /release-checklist now", slug: "release-checklist"))
        #expect(SkillInstaller.mentionsSkill(#""skill":"release-checklist""#, slug: "release-checklist"))
        #expect(!SkillInstaller.mentionsSkill("pre-release-checklist-v2", slug: "release-checklist"))
        #expect(!SkillInstaller.mentionsSkill("releasechecklist", slug: "release-checklist"))
    }

    @Test("version bump + diff summary")
    func bumpAndDiff() {
        #expect(SkillInstaller.bumpPatch("1.0.0") == "1.0.1")
        #expect(SkillInstaller.bumpPatch("2.3.9") == "2.3.10")
        #expect(SkillInstaller.bumpPatch("garbage") == "1.0.1")
        let diff = SkillInstaller.diffSummary(old: "a\nb\nc", new: "a\nc\nd\ne")
        #expect(diff.added == 2)
        #expect(diff.removed == 1)
    }
}

// MARK: - Journal store

@Suite("Dream journal store")
struct DreamStoreTests {

    @Test("entries round-trip payload, unread flips, quiet + dreamed coexist per night")
    func journalRoundTrip() throws {
        let store = try MemoryStore(location: .inMemory)
        let payload = DreamPayload(
            epiphanies: [DreamEpiphany(kind: .friction, title: "T", insight: "I",
                                       quotes: [DreamQuote(sessionId: "s", text: "q")])],
            proposedMemoryIds: ["m1"],
            skillProposals: [],
            reportBacks: [DreamReportBack(kind: .skill, subject: "x", title: "X", detail: "used")],
            stats: DreamStats(sessionsScanned: 3, memoriesConsidered: 9, classifier: "test", calls: 1))
        let dreamed = DreamJournalEntry(
            projectId: "p", night: "2026-07-17", outcome: .dreamed,
            narrative: "n", payload: payload, unread: true, calls: 1, estCostUSD: 0.005)
        let quiet = DreamJournalEntry(
            projectId: "p", night: "2026-07-18", outcome: .quiet,
            payload: DreamPayload(stats: .init(
                sessionsScanned: 0, memoriesConsidered: 0, classifier: "test", calls: 1)))
        try store.upsertDreamEntry(dreamed)
        try store.upsertDreamEntry(quiet)

        let entries = try store.dreamEntries(projectId: "p")
        #expect(entries.count == 2)
        let fetched = try #require(try store.dreamEntry(id: dreamed.id))
        #expect(fetched.payload.epiphanies.first?.quotes.first?.text == "q")
        #expect(fetched.payload.reportBacks.count == 1)
        #expect(try store.latestDreamNight(projectId: "p") == "2026-07-18")

        #expect(try store.unreadDreamEntries().map(\.id) == [dreamed.id])
        try store.markDreamRead(id: dreamed.id)
        #expect(try store.unreadDreamEntries().isEmpty)
    }

    @Test("pre-gate activity queries count sealed sessions and memory churn in the window")
    func activityQueries() throws {
        let store = try MemoryStore(location: .inMemory)
        let now = Date()
        try store.markProcessed(.init(
            sessionId: "s1", projectId: "p", processedAt: now.addingTimeInterval(-3_600), source: .live))
        try store.markProcessed(.init(
            sessionId: "s2", projectId: "p", processedAt: now.addingTimeInterval(-86_400 * 9), source: .live))
        try store.upsert(memory("a"))

        let cutoff = now.addingTimeInterval(-86_400 * 3)
        #expect(try store.processedSessionCount(projectId: "p", since: cutoff) == 1)
        #expect(try store.memoriesUpdatedCount(projectId: "p", since: cutoff) == 1)
        let latest = try #require(try store.latestProcessedAt(projectId: "p"))
        #expect(abs(latest.timeIntervalSince(now.addingTimeInterval(-3_600))) < 5)
    }
}
