import XCTest
@testable import TreemapLayout

/// Placeholder for the geometry suite (spec §9.1). The real cases — golden
/// rectangle lists per fixture tree, the merge rule's area truthfulness, hit
/// testing, palette classification — arrive with ticket 06.
final class TreemapLayoutScaffoldTests: XCTestCase {
    func test_moduleBuildsAgainstTheDeploymentFloor() {
        XCTAssertEqual(TreemapLayout.minimumSupportedMacOS, "11.0")
    }
}
