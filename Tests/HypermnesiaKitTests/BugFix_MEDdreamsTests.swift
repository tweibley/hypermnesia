import Foundation
import Testing
@testable import HypermnesiaKit

// Regression coverage for cluster MED-dreams:
//  - DreamRunner re-dream must not orphan installed skills (carry lifecycle state forward).
//  - DreamRunner re-dream must stamp drafts with the id the entry is actually persisted under.
//  - DreamService user-scope skill usage must be scanned across ALL projects' transcripts.

// MARK: - Doubles / fixtures

private struct StubDreamCompleter: DreamCompleter {
    enum Behavior: Sendable { case respond(String), fail(String) }
    let behavior: Behavior
    func completeJSON(system: String, user: String) async throws -> String {
        switch behavior {
        case .respond(let text): return text
        case .fail(let reason): throw ClassifierError.toolFailed(reason)
        }
    }
}

private func memory(_ id: String, projectId: String = "p") -> MemoryNode {
    MemoryNode(
        id: id, projectId: projectId, type: .fact, status: .confirmed,
        title: "Memory \(id)", summary: "Summary for memory \(id) with real content",
        data: .fact(.init(category: "state", key: "key-\(id)", value: "value-\(id)")))
}

private func sessions(_ ids: [String]) -> [DreamSessionInput] {
    ids.map { DreamSessionInput(sessionId: $0, endedAt: Date(), text: "USER: work in session \($0)") }
}

private func dreamedResponse(citing ids: [String], session: String) -> String {
    let idList = ids.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
    {"narrative": "The project consolidated around its storage decisions.",
     "epiphanies": [{"kind": "theme", "title": "Storage discipline", "insight": "Both memories agree.",
                     "memoryIds": [\(idList)], "sessionIds": ["\(session)"], "score": 0.85}],
     "proposedMemories": [{"type": "fact", "confidence": 0.9, "title": "Nightly cadence",
                           "summary": "Dreams run after the first idle following wake",
                           "context": {"category": "state", "key": "dream-cadence", "value": "idle-after-wake"}}],
     "proposedSkills": []}
    """
}

private func skillProposal(slug: String, state: DreamSkillProposalState) -> DreamSkillProposal {
    DreamSkillProposal(
        slug: slug, title: "T-\(slug)", description: "d", rationale: "r",
        markdown: "---\nname: \(slug)\n---\nBody", state: state)
}

private func stats() -> DreamStats {
    DreamStats(sessionsScanned: 0, memoriesConsidered: 0, classifier: "test", calls: 1)
}

// MARK: - Bug 1: re-dream must not orphan installed-skill lifecycle state

@Suite("MED-dreams: skill lifecycle carry-forward")
struct DreamSkillCarryForwardTests {

    @Test("re-proposed slug inherits its prior non-proposed state")
    func inheritsState() {
        let merged = DreamRunner.mergeSkillProposalStates(
            new: [skillProposal(slug: "deploy", state: .proposed),
                  skillProposal(slug: "release", state: .proposed)],
            old: [skillProposal(slug: "deploy", state: .installed),
                  skillProposal(slug: "release", state: .dismissed)])
        #expect(merged.first { $0.slug == "deploy" }?.state == .installed)
        #expect(merged.first { $0.slug == "release" }?.state == .dismissed)
    }

    @Test("installed skill the new dream didn't re-propose is preserved (uninstall stays reachable)")
    func preservesOrphanedInstalled() {
        let merged = DreamRunner.mergeSkillProposalStates(
            new: [skillProposal(slug: "brand-new", state: .proposed)],
            old: [skillProposal(slug: "installed-earlier", state: .installed),
                  skillProposal(slug: "dismissed-earlier", state: .dismissed)])
        // The installed one survives; a merely-dismissed one that isn't re-proposed does not clutter.
        #expect(merged.contains { $0.slug == "installed-earlier" && $0.state == .installed })
        #expect(merged.contains { $0.slug == "brand-new" && $0.state == .proposed })
        #expect(!merged.contains { $0.slug == "dismissed-earlier" })
    }

    @Test("a re-dream over an installed skill keeps it installed in the persisted entry")
    func reDreamKeepsInstalled() async throws {
        let store = try MemoryStore(location: .inMemory)
        try store.upsert([memory("a"), memory("b")])
        let night = DreamScheduler.nightKey(for: Date())
        // Simulate: tonight already dreamed and the user installed a skill from that card.
        let priorId = "prior-entry-id"
        try store.upsertDreamEntry(DreamJournalEntry(
            id: priorId, projectId: "p", night: night, outcome: .dreamed,
            payload: DreamPayload(
                skillProposals: [skillProposal(slug: "installed-skill", state: .installed)],
                stats: stats())))

        // Re-dream: a quiet result (empty payload) must not erase the installed skill.
        let empty = #"{"narrative": "", "epiphanies": [], "proposedMemories": [], "proposedSkills": []}"#
        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .respond(empty)),
            sessions: sessions(["s1", "s2"]), skillInventory: [])

        let entry = try #require(result.entry)
        #expect(entry.id == priorId)   // reused the night's row
        #expect(entry.payload.skillProposals.contains {
            $0.slug == "installed-skill" && $0.state == .installed
        })
        // And it is durable in the store, so the journal still offers Uninstall.
        let fetched = try #require(try store.dreamEntry(projectId: "p", night: night))
        #expect(fetched.payload.skillProposals.contains {
            $0.slug == "installed-skill" && $0.state == .installed
        })
    }
}

// MARK: - Bug 3: re-dream drafts must carry the persisted entry id (report-back provenance)

@Suite("MED-dreams: re-dream memory provenance")
struct DreamReDreamProvenanceTests {

    @Test("drafts from a re-dream are stamped with the id the entry is persisted under")
    func draftsCarryPersistedId() async throws {
        let store = try MemoryStore(location: .inMemory)
        try store.upsert([memory("a"), memory("b")])
        let night = DreamScheduler.nightKey(for: Date())
        // Tonight already has an entry (as after a first dream or a quiet pass).
        let priorId = "tonights-entry-id"
        try store.upsertDreamEntry(DreamJournalEntry(
            id: priorId, projectId: "p", night: night, outcome: .quiet,
            payload: DreamPayload(stats: stats())))

        let result = await DreamRunner.run(
            projectId: "p", store: store,
            completer: StubDreamCompleter(behavior: .respond(dreamedResponse(citing: ["a", "b"], session: "s1"))),
            sessions: sessions(["s1", "s2"]), skillInventory: [])

        let entry = try #require(result.entry)
        #expect(entry.id == priorId)   // the night's row was reused, not duplicated
        let draftId = try #require(entry.payload.proposedMemoryIds.first)
        let draft = try #require(try store.node(id: draftId))
        // The provenance link MemoryStore.dreamEntryIds relies on: draft.conversationId == entry.id.
        #expect(draft.conversationId == entry.id)
        // Exactly one row for the night.
        #expect(try store.dreamEntries(projectId: "p").count == 1)
    }
}

// MARK: - Bug 2 / 5: user-scope skill usage scans all projects' transcripts

@Suite("MED-dreams: skill usage scan scope")
struct DreamSkillUsageScopeTests {

    private func writeTranscript(_ dir: URL, name: String, mentioning slug: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("agent ran /\(slug) here\n".utf8).write(to: url)
        return url
    }

    private func record(slug: String, scope: String, installedAgo: TimeInterval, now: Date)
        -> InstalledSkillRecord {
        let installedAt = now.addingTimeInterval(-installedAgo)
        return InstalledSkillRecord(
            slug: slug, title: "T-\(slug)", version: "1.0.0",
            installedAt: installedAt, updatedAt: installedAt,
            scope: scope, projectId: scope == "project" ? "p" : nil,
            primaryPath: "/tmp/none", mirrorPaths: [], lastScanAt: installedAt)
    }

    @Test("user-scope skill counts usage from another project's transcript; project-scope does not")
    func userScopeScansAllProjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meddreams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // "Other project" usage of a user-scope skill — present only in the all-projects set.
        let otherProjectFile = try writeTranscript(root, name: "other.jsonl", mentioning: "cross-skill")
        // This project's usage of a project-scope skill.
        let thisProjectFile = try writeTranscript(root, name: "this.jsonl", mentioning: "proj-skill")

        let projectTranscripts = [(sessionId: "s-this", url: thisProjectFile, modifiedAt: now)]
        let userTranscripts = [
            (sessionId: "s-this", url: thisProjectFile, modifiedAt: now),
            (sessionId: "s-other", url: otherProjectFile, modifiedAt: now),
        ]

        let userRec = record(slug: "cross-skill", scope: "user", installedAgo: 3_600, now: now)
        let projRec = record(slug: "proj-skill", scope: "project", installedAgo: 3_600, now: now)

        let (backs, updated) = DreamService.scanSkillUsage(
            records: [userRec, projRec],
            projectTranscripts: projectTranscripts,
            userTranscripts: userTranscripts,
            now: now)

        // The user-scope skill's usage lives only in the OTHER project's transcript. Scanning it
        // against this project's transcripts alone (the old bug) would have counted 0.
        #expect(updated[0].slug == "cross-skill")
        #expect(updated[0].sessionsSeenUsed == 1)
        #expect(updated[1].slug == "proj-skill")
        #expect(updated[1].sessionsSeenUsed == 1)
        #expect(backs.contains { $0.subject == "cross-skill" && $0.detail.contains("was used in 1") })
        #expect(backs.contains { $0.subject == "proj-skill" && $0.detail.contains("was used in 1") })
    }
}
