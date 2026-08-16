import XCTest

/// Placeholder for the UI suite (spec §9.1): lifecycle states, three-pane
/// wiring, keyboard, resizing, and the accessibility surface (spec §9.4).
final class MacDirStatUIScaffoldTests: XCTestCase {
    func test_applicationLaunchesToAWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
