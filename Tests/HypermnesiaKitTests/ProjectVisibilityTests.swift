import Foundation
import Testing
@testable import HypermnesiaKit

struct ProjectVisibilityTests {

    @Test func parseSplitsTrimsAndLowercases() {
        #expect(ProjectVisibility.parse("Acme, path:/Users/x/Secret ,,  ") ==
                ["acme", "path:/users/x/secret"])
        #expect(ProjectVisibility.parse(nil) == [])
        #expect(ProjectVisibility.parse("") == [])
    }

    @Test func hiddenMatchesCaseInsensitiveSubstringOfProjectId() {
        let tokens = ProjectVisibility.parse("acme,path:/users/x/secret")
        #expect(ProjectVisibility.isHidden(projectId: "github.com/Acme/app", tokens: tokens))
        #expect(ProjectVisibility.isHidden(projectId: "path:/Users/x/secret", tokens: tokens))
        #expect(!ProjectVisibility.isHidden(projectId: "github.com/tweibley/hypermnesia", tokens: tokens))
        // No tokens → nothing hidden.
        #expect(!ProjectVisibility.isHidden(projectId: "github.com/acme/app", tokens: []))
    }

    @Test func visibleIsPassThroughWhenEnvUnset() {
        // The test process shouldn't run with the screenshot env var set; visible() must be identity.
        #expect(ProcessInfo.processInfo.environment[ProjectVisibility.environmentKey] == nil)
        let ids = ["github.com/acme/app", "path:/Users/x/secret"]
        #expect(ProjectVisibility.visible(ids) { $0 } == ids)
    }
}
