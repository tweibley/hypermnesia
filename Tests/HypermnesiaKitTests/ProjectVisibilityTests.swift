import XCTest
@testable import HypermnesiaKit

final class ProjectVisibilityTests: XCTestCase {

    func testParseSplitsTrimsAndLowercases() {
        XCTAssertEqual(ProjectVisibility.parse("Acme, path:/Users/x/Secret ,,  "),
                       ["acme", "path:/users/x/secret"])
        XCTAssertEqual(ProjectVisibility.parse(nil), [])
        XCTAssertEqual(ProjectVisibility.parse(""), [])
    }

    func testHiddenMatchesCaseInsensitiveSubstringOfProjectId() {
        let tokens = ProjectVisibility.parse("acme,path:/users/x/secret")
        XCTAssertTrue(ProjectVisibility.isHidden(projectId: "github.com/Acme/app", tokens: tokens))
        XCTAssertTrue(ProjectVisibility.isHidden(projectId: "path:/Users/x/secret", tokens: tokens))
        XCTAssertFalse(ProjectVisibility.isHidden(projectId: "github.com/tweibley/hypermnesia", tokens: tokens))
        // No tokens → nothing hidden.
        XCTAssertFalse(ProjectVisibility.isHidden(projectId: "github.com/acme/app", tokens: []))
    }

    func testVisibleIsPassThroughWhenEnvUnset() {
        // The test process shouldn't run with the screenshot env var set; visible() must be identity.
        XCTAssertNil(ProcessInfo.processInfo.environment[ProjectVisibility.environmentKey])
        let ids = ["github.com/acme/app", "path:/Users/x/secret"]
        XCTAssertEqual(ProjectVisibility.visible(ids) { $0 }, ids)
    }
}
