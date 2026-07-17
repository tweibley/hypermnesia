import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Models")
struct ModelTests {

    // MARK: MemoryData envelope round-trips, preserving the sub-fields the original dropped

    @Test("convention examples survive a JSON round-trip")
    func conventionExamplesRoundTrip() throws {
        let data = MemoryData.convention(.init(
            trigger: "writing a view",
            rule: "Views never import the engine's DB layer",
            examples: [.init(bad: "import GRDB", good: "inject a Store")],
            relatedFiles: ["App/Views/Foo.swift"]
        ))
        let decoded = try roundTrip(data)
        guard case .convention(let c) = decoded else { Issue.record("wrong case"); return }
        #expect(c.examples == [.init(bad: "import GRDB", good: "inject a Store")])
        #expect(decoded.type == .convention)
    }

    @Test("intent behaviors and codeRef snippet survive a round-trip")
    func intentAndCodeRefRoundTrip() throws {
        let intent = try roundTrip(.intent(.init(
            goal: "Fast cold start",
            behaviors: [.init(given: "app launch", when: "no cache", then: "show skeleton")],
            constraints: ["< 200ms"]
        )))
        guard case .intent(let i) = intent else { Issue.record("wrong case"); return }
        #expect(i.behaviors.first?.then == "show skeleton")

        let ref = try roundTrip(.codeRef(.init(filePath: "a.swift", symbolName: "foo", range: "L1-L9", snippet: "func foo() {}")))
        guard case .codeRef(let r) = ref else { Issue.record("wrong case"); return }
        #expect(r.snippet == "func foo() {}")
    }

    @Test("every type encodes with a matching {type, content} envelope")
    func envelopeShape() throws {
        let samples: [MemoryData] = [
            .decision(.init(chosen: "x")),
            .convention(.init(rule: "y")),
            .intent(.init(goal: "z")),
            .fact(.init(category: "stack", key: "db", value: "postgres")),
            .concern(.init(issue: "n+1", severity: "high")),
            .backlog(.init(idea: "later", priority: "low")),
            .codeRef(.init(filePath: "f.swift")),
        ]
        for sample in samples {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]
            #expect(json?["type"] as? String == sample.type.rawValue)
            #expect(json?["content"] != nil)
        }
    }

    // MARK: Decay banding

    @Test("confidence buckets into the right decay band")
    func decayBands() {
        #expect(DecayLevel.from(confidence: 1.00) == .fresh)
        #expect(DecayLevel.from(confidence: 0.74) == .aging)
        #expect(DecayLevel.from(confidence: 0.49) == .stale)
        #expect(DecayLevel.from(confidence: 0.24) == .dormant)
        #expect(DecayLevel.from(confidence: 0.0) == .obsolete)
        #expect(DecayLevel.from(confidence: 0.9, isSuperseded: true) == .obsolete)
        // out-of-range high values resolve to fresh, not a crash
        #expect(DecayLevel.from(confidence: 1.5) == .fresh)
    }

    @Test("only knowledge types decay with time")
    func decayingTypes() {
        #expect(MemoryType.decision.decaysWithTime)
        #expect(MemoryType.convention.decaysWithTime)
        #expect(MemoryType.intent.decaysWithTime)
        #expect(!MemoryType.fact.decaysWithTime)
        #expect(!MemoryType.concern.decaysWithTime)
        #expect(!MemoryType.backlog.decaysWithTime)
        #expect(!MemoryType.codeRef.decaysWithTime)
    }

    @Test("node derives decay level, review need, age, and override rate")
    func nodeDerived() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let node = MemoryNode(
            projectId: "acme/app",
            type: .convention,
            status: .confirmed,
            title: "Tabs",
            summary: "Use tabs",
            data: .convention(.init(rule: "Use tabs")),
            confidence: 0.49,
            createdAt: created,
            updatedAt: created,
            lastValidatedAt: created,
            timesApplied: 10,
            timesOverridden: 4
        )
        #expect(node.decayLevel == .stale)
        #expect(node.needsRevalidation)
        #expect(node.overrideRatePercent == 40)
        #expect(node.daysSinceValidation(asOf: created.addingTimeInterval(5 * 86_400)) == 5)
    }

    // MARK: Edge metadata

    @Test("edge ids are stable and rendering hints are correct")
    func edgeMetadata() {
        let e = MemoryEdge(projectId: "p", source: "a", target: "b", relationship: .supersedes)
        #expect(e.id == "a-supersedes-b")
        #expect(e.relationship.hasArrow)
        #expect(MemoryEdgeType.relatedTo.lineDash == [2, 2])
        #expect(!MemoryEdgeType.relatedTo.hasArrow)
    }

    // MARK: helper

    private func roundTrip(_ data: MemoryData) throws -> MemoryData {
        let encoded = try JSONEncoder().encode(data)
        return try JSONDecoder().decode(MemoryData.self, from: encoded)
    }
}
