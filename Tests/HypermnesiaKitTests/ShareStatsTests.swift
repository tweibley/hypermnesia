import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("ShareStats")
struct ShareStatsTests {

    private func node(
        _ type: MemoryType = .fact,
        status: MemoryStatus = .confirmed,
        confidence: Double = 1.0,
        createdDaysAgo: Int = 0,
        conversationId: String? = nil,
        timesAppliedSuccess: Int = 0,
        supersededById: String? = nil
    ) -> MemoryNode {
        MemoryNode(
            projectId: "github.com/acme/app", type: type, status: status,
            title: "t", summary: "s",
            data: .fact(.init(category: "c", key: "k", value: "v")),
            confidence: confidence,
            createdAt: Date(timeIntervalSinceNow: -Double(createdDaysAgo) * 86_400),
            supersededById: supersededById,
            conversationId: conversationId,
            timesAppliedSuccess: timesAppliedSuccess
        )
    }

    @Test("drafts, superseded, and deleted memories don't count")
    func liveFiltering() {
        var deleted = node()
        deleted.deletedAt = Date()
        let stats = ShareStats.compute(
            projectName: "acme/app",
            memories: [node(), node(status: .draft), node(supersededById: "x"), deleted],
            edges: [])
        #expect(stats.memoryCount == 1)
    }

    @Test("healthyShare counts fresh and aging memories only")
    func healthyShare() {
        let stats = ShareStats.compute(
            projectName: "acme/app",
            memories: [
                node(confidence: 1.0),    // fresh
                node(confidence: 0.6),    // aging — still healthy
                node(confidence: 0.3),    // stale — needs review
                node(confidence: 0.1),    // dormant
            ],
            edges: [])
        #expect(abs(stats.healthyShare - 0.5) < 0.0001)
    }

    @Test("sessions are distinct; applied counts sum; nil sessions ignored")
    func evidence() {
        let stats = ShareStats.compute(
            projectName: "acme/app",
            memories: [
                node(conversationId: "a", timesAppliedSuccess: 2),
                node(conversationId: "a", timesAppliedSuccess: 3),
                node(conversationId: "b"),
                node(conversationId: nil),
            ],
            edges: [])
        #expect(stats.sessionCount == 2)
        #expect(stats.appliedCount == 5)
    }

    @Test("memory age is 1-based and nil for an empty corpus")
    func memoryAge() {
        let fresh = ShareStats.compute(projectName: "p", memories: [node()], edges: [])
        #expect(fresh.memoryAgeDays == 1)
        let aged = ShareStats.compute(projectName: "p", memories: [node(createdDaysAgo: 10)], edges: [])
        #expect(aged.memoryAgeDays == 11)
        let empty = ShareStats.compute(projectName: "p", memories: [], edges: [])
        #expect(empty.memoryAgeDays == nil)
    }

    @Test("type counts include only present types, in allCases order")
    func typeCounts() {
        let stats = ShareStats.compute(
            projectName: "p",
            memories: [node(.concern), node(.decision), node(.decision)],
            edges: [])
        #expect(stats.typeCounts.map(\.type) == [.decision, .concern])
        #expect(stats.typeCounts.map(\.count) == [2, 1])
    }
}
