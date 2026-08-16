import XCTest

/// The compatibility-smoke workflow (spec §9.1), selected on its own by
/// `TestPlans/CompatibilitySmoke.xctestplan` and run on one host per major
/// macOS from 11 through current stable (spec §9.3).
///
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

    func test_folderScan() throws {
        let fixture = try makeFixture(fileCount: 1, bytesPerFile: 1_537)
        let app = launchedApplication()

        try chooseFolder(fixture, in: app)

        XCTAssertTrue(app.outlines.staticTexts[fixture.lastPathComponent].waitForExistence(timeout: 10))
    }

    func test_incrementalResults() throws {
        throw XCTSkip("Cross-host incremental fixture activation remains ticket 11; ticket 07 covers the live UI boundary in MacDirStatTests.")
    }

    func test_cancelRetainsDiscoveredResults() throws { try skipUntilBehaviourLands("ticket 09") }

    func test_treemapSelectionSyncsWithTree() throws { try skipUntilBehaviourLands("ticket 08") }

    func test_openAndRevealCallOnlyTheirSpies() throws { try skipUntilBehaviourLands("ticket 09") }

    func test_partiallyFailedScanIsLegible() throws { try skipUntilBehaviourLands("ticket 09") }

    private func makeFixture(fileCount: Int, bytesPerFile: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDirStat-UISmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let payload = Data(repeating: 0x4D, count: bytesPerFile)
        for index in 0..<fileCount {
            try payload.write(to: folder.appendingPathComponent(String(format: "%05d.bin", index)))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func chooseFolder(_ folder: URL, in app: XCUIApplication) throws {
        let choose = app.buttons["Choose…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.click()

        let chooseFolder = app.buttons["Choose Folder…"]
        XCTAssertTrue(chooseFolder.waitForExistence(timeout: 3))
        chooseFolder.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))

        app.typeKey("g", modifierFlags: [.command, .shift])
        let location = app.textFields.firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 3))
        location.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])

        // The system may also expose a Touch Bar button titled "Scan".
        // Scope the query to NSOpenPanel's actual OK button.
        let scan = app.sheets.firstMatch.buttons.matching(identifier: "OKButton").firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 3))
        scan.click()
    }
}
