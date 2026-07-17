import Testing
@testable import HypermnesiaKit

@Suite("Smoke")
struct SmokeTests {
    @Test("engine version is set")
    func versionIsSet() {
        #expect(!Hypermnesia.version.isEmpty)
    }
}
