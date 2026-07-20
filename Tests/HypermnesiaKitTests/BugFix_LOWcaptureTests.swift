import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression coverage for the LOW-capture cluster.
///
/// Bug: `Momentum.trailingQuestion` split the assistant's final message on every '.', so a
/// question containing a filename or version number ("settings.json", "v2.3") was truncated
/// into a garbled fragment ("json file?", "3 first?") and injected into the next session's
/// "## Previous session" block.
@Suite("BugFix_LOWcapture")
struct BugFix_LOWcaptureTests {

    @Test("A filename dot no longer truncates the trailing question")
    func filenameDotKeepsWholeQuestion() {
        #expect(Momentum.trailingQuestion("Want me to update the settings.json file?")
            == "Want me to update the settings.json file?")
    }

    @Test("A version dot no longer truncates the trailing question")
    func versionDotKeepsWholeQuestion() {
        #expect(Momentum.trailingQuestion("Should I bump to v2.3 first?")
            == "Should I bump to v2.3 first?")
    }

    @Test("A real sentence boundary still isolates the final question")
    func realSentenceBoundaryIsolatesQuestion() {
        #expect(Momentum.trailingQuestion("I fixed the parser. Should I deploy it now?")
            == "Should I deploy it now?")
    }

    @Test("Multiple dotted tokens across a boundary keep the last full sentence")
    func boundaryAfterDottedTokens() {
        #expect(Momentum.trailingQuestion("Edited auth.swift and v1.2 config. Which test should I run?")
            == "Which test should I run?")
    }

    @Test("A lowercase-token fragment is dropped rather than injected")
    func garbledFragmentIsDropped() {
        // A leading dotted token with no real interrogative should never surface.
        #expect(Momentum.trailingQuestion("settings.json?") == nil)
    }

    @Test("Non-questions still return nil")
    func nonQuestionReturnsNil() {
        #expect(Momentum.trailingQuestion("I updated settings.json and moved on.") == nil)
    }

    @Test("Trailing tool annotation without its own question is still stripped")
    func trailingAnnotationStripped() {
        #expect(Momentum.trailingQuestion("Should I run the tests? → Edit(auth.swift)")
            == "Should I run the tests?")
    }
}
