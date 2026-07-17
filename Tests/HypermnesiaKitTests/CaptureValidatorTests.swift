import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("CaptureValidator")
struct CaptureValidatorTests {

    // MARK: - .ok verdicts

    @Test("well-formed convention with a literal JSON shape is .ok")
    func okWithLiteralShape() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.9,
            title: "Error response format",
            summary: #"error bodies are {"error": {"code": "not_found", "message": "..."}} always"#
        )
        #expect(CaptureValidator.assess(m) == .ok)
    }

    @Test("well-formed decision with no contract/replacement language is .ok")
    func okPlainDecision() {
        let m = ClassifiedMemory(
            type: .decision, confidence: 0.85,
            title: "Use SQLite for local storage",
            summary: "Chose SQLite because it ships with macOS, requires no network, and keeps the footprint tiny. Revisit if multi-device sync is added."
        )
        #expect(CaptureValidator.assess(m) == .ok)
    }

    @Test("fact type bypasses contract and prohibition checks — always .ok when non-degenerate")
    func okFactType() {
        let m = ClassifiedMemory(
            type: .fact, confidence: 0.9,
            title: "Database engine",
            summary: "Project uses SQLite via GRDB on macOS 14+"
        )
        #expect(CaptureValidator.assess(m) == .ok)
    }

    @Test("convention with call-signature evidence is .ok even though 'signature' is a contract keyword")
    func okCallSignatureEvidence() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.88,
            title: "Logger call signature",
            summary: "Always call logger.log(level:message:) — the signature takes a LogLevel and a plain String."
        )
        #expect(CaptureValidator.assess(m) == .ok)
    }

    @Test("decision with replacement language AND an explicit prohibition is .ok")
    func okReplacementWithProhibition() {
        let m = ClassifiedMemory(
            type: .decision, confidence: 0.87,
            title: "Moved to async/await",
            summary: "Switched to async/await throughout; never use callback-based APIs — they cause unbounded threading issues."
        )
        #expect(CaptureValidator.assess(m) == .ok)
    }

    // MARK: - .weak(contract-missing)

    @Test("convention that references 'response format' with no literal shape is .weak")
    func weakContractMissingResponseFormat() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.9,
            title: "API response format",
            summary: "All API endpoints must follow the standard response format defined in the shared module."
        )
        let verdict = CaptureValidator.assess(m)
        guard case .weak(let reason) = verdict else {
            Issue.record("expected .weak, got \(verdict)")
            return
        }
        #expect(reason.contains("contract referenced"))
    }

    @Test("convention mentioning 'schema' with no structural token is .weak")
    func weakContractMissingSchema() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.85,
            title: "Request schema",
            summary: "Requests must conform to the JSON schema documented in the API guide."
        )
        let verdict = CaptureValidator.assess(m)
        guard case .weak(let reason) = verdict else {
            Issue.record("expected .weak, got \(verdict)")
            return
        }
        #expect(reason.contains("contract referenced"))
    }

    @Test("decision mentioning 'error body' with no literal shape is .weak")
    func weakContractMissingErrorBody() {
        let m = ClassifiedMemory(
            type: .decision, confidence: 0.8,
            title: "Standard error body",
            summary: "All errors must use the standard error body shape as specified in the design doc."
        )
        let verdict = CaptureValidator.assess(m)
        guard case .weak = verdict else {
            Issue.record("expected .weak, got \(verdict)")
            return
        }
    }

    // MARK: - .weak(prohibition-missing)

    @Test("decision with 'use X instead of Y' but no explicit prohibition is .weak")
    func weakProhibitionMissingInsteadOf() {
        let m = ClassifiedMemory(
            type: .decision, confidence: 0.85,
            title: "Async/await migration",
            summary: "Use async/await instead of completion handlers; the codebase was fully migrated in the last sprint."
        )
        let verdict = CaptureValidator.assess(m)
        guard case .weak(let reason) = verdict else {
            Issue.record("expected .weak, got \(verdict)")
            return
        }
        #expect(reason.contains("prohibition"))
    }

    @Test("convention with 'switched to' but no 'never'/'avoid' is .weak")
    func weakProhibitionMissingSwitchedTo() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.9,
            title: "Logging framework switch",
            summary: "Switched to OSLog for all logging — the old print() calls have been replaced throughout."
        )
        // "print() calls have been replaced" — replacement implied, no prohibition keyword
        let verdict = CaptureValidator.assess(m)
        guard case .weak = verdict else {
            Issue.record("expected .weak, got \(verdict)")
            return
        }
    }

    // MARK: - .weak(low-detail)

    @Test("convention with a summary shorter than 25 chars is .weak")
    func weakLowDetailShortSummary() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.8,
            title: "Use helper",
            summary: "Use the util helper."   // 20 chars — below threshold
        )
        let verdict = CaptureValidator.assess(m)
        guard case .weak = verdict else {
            Issue.record("expected .weak, got \(verdict)")
            return
        }
    }

    // MARK: - .reject (degenerate)

    @Test("empty summary is .reject")
    func rejectEmptySummary() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.9,
            title: "Some convention",
            summary: ""
        )
        let verdict = CaptureValidator.assess(m)
        guard case .reject = verdict else {
            Issue.record("expected .reject, got \(verdict)")
            return
        }
    }

    @Test("whitespace-only summary is .reject")
    func rejectWhitespaceSummary() {
        let m = ClassifiedMemory(
            type: .fact, confidence: 0.9,
            title: "Fact",
            summary: "   \t\n  "
        )
        let verdict = CaptureValidator.assess(m)
        guard case .reject = verdict else {
            Issue.record("expected .reject, got \(verdict)")
            return
        }
    }

    @Test("summary shorter than 12 chars is .reject")
    func rejectTooShort() {
        let m = ClassifiedMemory(
            type: .decision, confidence: 0.7,
            title: "Some decision",
            summary: "short"        // 5 chars
        )
        let verdict = CaptureValidator.assess(m)
        guard case .reject = verdict else {
            Issue.record("expected .reject, got \(verdict)")
            return
        }
    }

    @Test("summary that merely restates the title is .reject")
    func rejectParaphrase() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.75,
            title: "Use async/await",
            summary: "Use async/await."   // title + period
        )
        let verdict = CaptureValidator.assess(m)
        guard case .reject = verdict else {
            Issue.record("expected .reject, got \(verdict)")
            return
        }
    }

    @Test("empty title is .reject")
    func rejectEmptyTitle() {
        let m = ClassifiedMemory(
            type: .convention, confidence: 0.9,
            title: "",
            summary: "Some convention about async usage patterns in the project."
        )
        let verdict = CaptureValidator.assess(m)
        guard case .reject = verdict else {
            Issue.record("expected .reject, got \(verdict)")
            return
        }
    }

    // MARK: - weakConfidenceCeiling

    @Test("weakConfidenceCeiling is 0.55")
    func ceilingValue() {
        #expect(CaptureValidator.weakConfidenceCeiling == 0.55)
    }

    @Test("SessionIngestor.validated caps confidence on weak memories")
    func validatedCapsCeiling() {
        let high = ClassifiedMemory(
            type: .convention, confidence: 0.95,
            title: "API response format",
            // Mentions "response format" but no literal shape — will be .weak
            summary: "All endpoints must follow the standard response format from the design doc."
        )
        let result = SessionIngestor.validated([high])
        #expect(result.count == 1)
        #expect(result[0].confidence <= CaptureValidator.weakConfidenceCeiling)
    }

    @Test("SessionIngestor.validated drops rejected memories")
    func validatedDropsRejected() {
        let degenerate = ClassifiedMemory(
            type: .fact, confidence: 0.9,
            title: "Something",
            summary: ""
        )
        let result = SessionIngestor.validated([degenerate])
        #expect(result.isEmpty)
    }

    @Test("SessionIngestor.validated passes ok memories through unchanged")
    func validatedPassesOkThrough() {
        let good = ClassifiedMemory(
            type: .fact, confidence: 0.9,
            title: "Database engine",
            summary: "Project uses SQLite via GRDB on macOS 14+."
        )
        let result = SessionIngestor.validated([good])
        #expect(result.count == 1)
        #expect(result[0].confidence == 0.9)
    }
}
