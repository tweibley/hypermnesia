import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Classifier")
struct ClassifierTests {

    @Test("ClassifiedMemory defaults confidence to 0.8 when omitted")
    func confidenceDefault() throws {
        let json = """
        { "type": "fact", "title": "Store", "summary": "Uses SQLite" }
        """
        let mem = try JSONDecoder().decode(ClassifiedMemory.self, from: Data(json.utf8))
        #expect(mem.confidence == 0.8)
        #expect(mem.type == .fact)
    }

    @Test("large/non-finite numeric context values don't crash stringValue")
    func numericContextNoCrash() {
        #expect(JSONValue.number(1e20).stringValue != nil)        // would previously trap on Int(1e20)
        #expect(JSONValue.number(.infinity).stringValue != nil)
        #expect(JSONValue.number(42).stringValue == "42")
        #expect(JSONValue.number(3.5).stringValue == "3.5")
    }

    @Test("convention examples are preserved through mapping (original dropped them)")
    func conventionExamplesPreserved() {
        let mem = ClassifiedMemory(
            type: .convention, confidence: 0.9, title: "Async only",
            summary: "Always use async/await",
            context: [
                "rule": .string("Always use async/await, never callbacks"),
                "examples": .array([.object(["bad": .string("cb()"), "good": .string("await f()")])]),
            ],
            relatedFiles: ["Net.swift"]
        )
        guard case .convention(let data) = mem.toMemoryData() else { Issue.record("wrong type"); return }
        #expect(data.rule == "Always use async/await, never callbacks")
        #expect(data.examples == [.init(bad: "cb()", good: "await f()")])
        #expect(data.relatedFiles == ["Net.swift"])
    }

    @Test("intent behaviors are preserved through mapping")
    func intentBehaviorsPreserved() {
        let mem = ClassifiedMemory(
            type: .intent, title: "Fast start", summary: "Cold start under 200ms",
            context: [
                "goal": .string("Fast cold start"),
                "behaviors": .array([.object([
                    "given": .string("app launch"), "when": .string("no cache"), "then": .string("show skeleton"),
                ])]),
                "constraints": .array([.string("< 200ms")]),
            ]
        )
        guard case .intent(let data) = mem.toMemoryData() else { Issue.record("wrong type"); return }
        #expect(data.behaviors.first?.then == "show skeleton")
        #expect(data.constraints == ["< 200ms"])
    }

    @Test("toDraftNode backdates timestamps and carries provenance")
    func draftNode() {
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        let mem = ClassifiedMemory(type: .decision, title: "Use REST", summary: "Chose REST",
                                   context: ["chosen": .string("REST")])
        let node = mem.toDraftNode(projectId: "github.com/acme/app", sessionId: "sess-42",
                                   createdAt: when, commitSha: "deadbeef", branch: "main")
        #expect(node.status == .draft)
        #expect(node.createdAt == when)
        #expect(node.lastValidatedAt == when)
        #expect(node.conversationId == "sess-42")
        #expect(node.commitSha == "deadbeef")
    }

    // MARK: - Envelope parsing

    @Test("parses memories nested in the --output-format json result string")
    func parseEnvelopeResultString() throws {
        let inner = #"{"memories":[{"type":"fact","title":"DB","summary":"Postgres","confidence":0.9}]}"#
        let envelope = """
        { "type": "result", "subtype": "success", "is_error": false, "result": \(jsonString(inner)) }
        """
        let mems = try ClaudeHeadlessClassifier.parse(envelope)
        #expect(mems.count == 1)
        #expect(mems.first?.title == "DB")
    }

    @Test("parses a result string wrapped in markdown fences")
    func parseFencedResult() throws {
        let fenced = "```json\n{\"memories\":[{\"type\":\"decision\",\"title\":\"Use REST\",\"summary\":\"Chose REST\",\"confidence\":0.9}]}\n```"
        let envelope = "{ \"type\":\"result\", \"is_error\":false, \"result\": \(jsonString(fenced)) }"
        let mems = try ClaudeHeadlessClassifier.parse(envelope)
        #expect(mems.count == 1)
        #expect(mems.first?.type == .decision)
        // and the raw extractor strips fences
        #expect(ClassifierJSON.extractObject(fenced).hasPrefix("{"))
    }

    @Test("parses a bare structured object and surfaces is_error")
    func parseDirectAndError() throws {
        let direct = #"{"memories":[{"type":"backlog","title":"Dark mode","summary":"later"}]}"#
        #expect(try ClaudeHeadlessClassifier.parse(direct).first?.type == .backlog)

        let errorEnvelope = #"{"type":"result","is_error":true,"result":"rate limited"}"#
        #expect(throws: ClassifierError.self) { try ClaudeHeadlessClassifier.parse(errorEnvelope) }
    }

    @Test("one malformed memory is skipped, not the whole batch")
    func malformedMemorySkipped() throws {
        // The middle element has an out-of-enum type; the two valid memories must still survive.
        let json = #"""
        {"memories":[
          {"type":"decision","title":"Use REST","summary":"Chose REST","confidence":0.9},
          {"type":"nonsense_type","title":"Bad","summary":"drift"},
          {"type":"fact","title":"DB","summary":"Postgres"}
        ]}
        """#
        let mems = try ClassifierJSON.memories(fromModelText: json)
        #expect(mems.count == 2)
        #expect(mems.map(\.type) == [.decision, .fact])
    }

    /// Encode a string as a JSON string literal (for embedding in the envelope fixture).
    private func jsonString(_ s: String) -> String {
        String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
    }
}
