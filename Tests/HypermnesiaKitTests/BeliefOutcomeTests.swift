import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("BeliefOutcome")
struct BeliefOutcomeTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A fresh (age 5 → freshness 1.0) convention so confidence == effective belief, isolating the
    /// outcome factors from age.
    private func node(prior: Double, sighted: Int, success: Int, overrides: Int) -> MemoryNode {
        MemoryNode(
            projectId: "p", type: .convention, title: "t", summary: "s",
            data: .convention(.init(rule: "r")),
            confidence: prior, belief: prior,
            createdAt: now.addingTimeInterval(-5 * 86_400), lastValidatedAt: nil,
            timesOverridden: overrides, timesSighted: sighted, timesAppliedSuccess: success)
    }

    private func confidence(_ n: MemoryNode) -> Double { DecayEngine.decayed(n, asOf: now).confidence }

    // MARK: - Monotonic sanity (the required acceptance checks)

    @Test("repeated wrong captures ALONE do not meaningfully inflate belief")
    func recaptureDoesNotInflate() {
        let base = confidence(node(prior: 0.7, sighted: 0, success: 0, overrides: 0))
        let recaptured = confidence(node(prior: 0.7, sighted: 8, success: 0, overrides: 0))
        #expect(abs(recaptured - base) < 1e-9)   // 8 sightings, no corroborator → no gain
    }

    @Test("successful application (a real corroborator) increases belief")
    func successIncreases() {
        let base = confidence(node(prior: 0.7, sighted: 3, success: 0, overrides: 0))
        let applied = confidence(node(prior: 0.7, sighted: 3, success: 2, overrides: 0))
        #expect(applied > base)
    }

    @Test("overrides / audit drift decrease belief fast")
    func overridesDecreaseFast() {
        let base = confidence(node(prior: 0.7, sighted: 2, success: 0, overrides: 0))
        let overridden = confidence(node(prior: 0.7, sighted: 2, success: 0, overrides: 3))
        #expect(overridden < base * 0.6)   // a clear, fast drop (≥ ~40%)
    }

    // MARK: - Audit-proxy instrumentation

    @Test("recordOutcomes corroborates consistent memories and flags drifted ones")
    func recordOutcomesSplitsSignals() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("belief-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "ok".write(to: repo.appendingPathComponent("present.swift"), atomically: true, encoding: .utf8)

        let store = try MemoryStore(location: .inMemory)
        let project = "path:\(repo.path)"
        let good = MemoryNode(projectId: project, type: .convention, status: .confirmed, title: "good", summary: "s",
                              data: .convention(.init(rule: "r", relatedFiles: ["present.swift"])), belief: 0.8)
        let drifted = MemoryNode(projectId: project, type: .convention, status: .confirmed, title: "drifted", summary: "s",
                                 data: .convention(.init(rule: "r", relatedFiles: ["gone.swift"])), belief: 0.8)
        try store.upsert([good, drifted])

        var findings = MemoryAuditor.audit(store: store, projectId: project, repoPath: repo.path)
        let counts = MemoryAuditor.recordOutcomes(findings, store: store, projectId: project)
        #expect(counts.corroborated == 1)
        #expect(counts.drifted == 1)
        let goodAfter = try #require(try store.node(id: good.id))
        let driftedAfter = try #require(try store.node(id: drifted.id))
        #expect(goodAfter.timesAppliedSuccess == 1)
        #expect(driftedAfter.timesOverridden == 1)
        // The recompute fix: drift immediately drops confidence below the prior; the corroborated one stays high.
        #expect(driftedAfter.confidence < 0.8)
        #expect(goodAfter.confidence > driftedAfter.confidence)

        // Idempotent: re-running with the SAME reality doesn't compound the counters.
        let again = MemoryAuditor.recordOutcomes(findings, store: store, projectId: project)
        #expect(again.corroborated == 0)
        #expect(again.drifted == 0)
        #expect(try #require(try store.node(id: good.id)).timesAppliedSuccess == 1)
        #expect(try #require(try store.node(id: drifted.id)).timesOverridden == 1)

        // But a genuine change is recorded: once the missing file appears, the drifted memory corroborates.
        try "ok".write(to: repo.appendingPathComponent("gone.swift"), atomically: true, encoding: .utf8)
        findings = MemoryAuditor.audit(store: store, projectId: project, repoPath: repo.path)
        let recovered = MemoryAuditor.recordOutcomes(findings, store: store, projectId: project)
        #expect(recovered.corroborated == 1)   // the formerly-drifted memory flipped to consistent
        #expect(try #require(try store.node(id: drifted.id)).timesAppliedSuccess == 1)
    }

    @Test("deep OUTDATED finding cannot be corroborated in the same pass")
    func deepFindingDrifts() throws {
        let store = try MemoryStore(location: .inMemory)
        let node = MemoryNode(
            projectId: "p", type: .convention, status: .confirmed, title: "old", summary: "s",
            data: .convention(.init(rule: "Use API v1", relatedFiles: ["present.swift"]))
        )
        try store.upsert(node)
        let findings = [AuditFinding(nodeId: node.id, title: node.title, issue: .outdated, detail: "now v2")]

        let result = MemoryAuditor.recordOutcomes(findings, store: store, projectId: "p")

        #expect(result.drifted == 1)
        #expect(result.corroborated == 0)
        #expect(try #require(try store.node(id: node.id)).timesOverridden == 1)
    }
}
