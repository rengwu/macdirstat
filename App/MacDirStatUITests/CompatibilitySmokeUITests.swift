import XCTest

/// The compatibility-smoke workflow (spec §9.1), selected on its own by
/// `TestPlans/CompatibilitySmoke.xctestplan` and run on one host per major
/// macOS from 11 through current stable (spec §9.3).
///
/// Placeholder (ticket 02): each check is named for the workflow step it will
/// perform, so the matrix record in ticket 11 has stable row names from the
/// start. The bodies fill in as tickets 07–09 land the behaviour; every check
/// beyond launch is skipped until then, so the plan is honest about what it has
/// actually proven on a given host.
final class CompatibilitySmokeUITests: XCTestCase {
    private func launchedApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func skipUntilBehaviourLands(_ ticket: String) throws {
        throw XCTSkip("Pending \(ticket); ticket 02 is scaffold only.")
    }

    func test_launch() {
        let app = launchedApplication()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func test_folderScan() throws { try skipUntilBehaviourLands("ticket 07") }

    func test_incrementalResults() throws { try skipUntilBehaviourLands("ticket 07") }

    func test_cancelRetainsDiscoveredResults() throws { try skipUntilBehaviourLands("ticket 09") }

    func test_treemapSelectionSyncsWithTree() throws { try skipUntilBehaviourLands("ticket 08") }

    func test_openAndRevealCallOnlyTheirSpies() throws { try skipUntilBehaviourLands("ticket 09") }

    func test_partiallyFailedScanIsLegible() throws { try skipUntilBehaviourLands("ticket 09") }
}
