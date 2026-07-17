import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("FocusedRetry")
struct FocusedRetryTests {

    private func convo(_ contents: [String]) -> Conversation {
        Conversation(
            sessionId: "s", cwd: "/repo", gitBranch: nil,
            messages: contents.map { ConversationMessage(role: "assistant", content: $0, timestamp: nil) }
        )
    }

    // MARK: - edit-heavy detection

    @Test("two editing tool uses make a session edit-heavy")
    func twoEditsIsHeavy() {
        let c = convo(["→ Edit(app.swift), Write(model.swift)"])
        #expect(c.editToolUseCount == 2)
        #expect(c.isEditHeavy)
    }

    @Test("a single edit is not edit-heavy (threshold is 2)")
    func oneEditNotHeavy() {
        let c = convo(["→ Edit(app.swift)", "ran the tests"])
        #expect(c.editToolUseCount == 1)
        #expect(!c.isEditHeavy)
    }

    @Test("a single MultiEdit / NotebookEdit counts once, not twice via the embedded 'Edit('")
    func editSubstringNotDoubleCounted() {
        #expect(convo(["→ MultiEdit(app.swift)"]).editToolUseCount == 1)
        #expect(!convo(["→ MultiEdit(app.swift)"]).isEditHeavy)
        #expect(convo(["→ NotebookEdit(nb.ipynb)"]).editToolUseCount == 1)
        // A genuine MultiEdit + a genuine Edit is two.
        #expect(convo(["→ MultiEdit(a.swift), Edit(b.swift)"]).editToolUseCount == 2)
    }

    @Test("a read-only / no-edit session is not edit-heavy")
    func noEditsNotHeavy() {
        let c = convo(["→ Read(app.swift), Bash(pytest)", "looks good"])
        #expect(c.editToolUseCount == 0)
        #expect(!c.isEditHeavy)
    }

    // MARK: - retry decision

    @Test("no retry when the first pass already produced usable memories")
    func noRetryWhenProductive() {
        #expect(!SessionIngestor.shouldRetryExtraction(producedNothing: false, firstPassWasNonEmpty: true, editHeavy: true))
    }

    @Test("retry when the first pass had content but it was all rejected")
    func retryWhenAllRejected() {
        #expect(SessionIngestor.shouldRetryExtraction(producedNothing: true, firstPassWasNonEmpty: true, editHeavy: false))
    }

    @Test("retry when the classifier returned nothing on an edit-heavy session (the gap fix)")
    func retryWhenEmptyButEditHeavy() {
        #expect(SessionIngestor.shouldRetryExtraction(producedNothing: true, firstPassWasNonEmpty: false, editHeavy: true))
    }

    @Test("no retry for a genuinely empty, low-activity session")
    func noRetryWhenEmptyAndLowActivity() {
        #expect(!SessionIngestor.shouldRetryExtraction(producedNothing: true, firstPassWasNonEmpty: false, editHeavy: false))
    }

    // MARK: - prompt plumbing

    @Test("a focus note is appended outside the transcript; nil leaves the prompt unchanged")
    func focusNotePlacement() {
        let c = convo(["did some work"])
        let plain = ClassifierPrompts.user(c, recentMemories: [])
        let focused = ClassifierPrompts.user(c, recentMemories: [], focus: ClassifierPrompts.focusedRetryNote)
        #expect(!plain.contains("EXTRACTION NOTE"))
        #expect(focused.contains("---- EXTRACTION NOTE ----"))
        // The note must come AFTER the transcript fence, not inside it.
        let endIdx = try! #require(focused.range(of: "END SESSION TRANSCRIPT"))
        let noteIdx = try! #require(focused.range(of: "---- EXTRACTION NOTE ----"))
        #expect(endIdx.lowerBound < noteIdx.lowerBound)
    }
}
