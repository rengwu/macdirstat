import XCTest

final class MacDirStatUIScaffoldTests: XCTestCase {
    func test_applicationLaunchesToAWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["See what’s using space"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists)
    }

    func test_realChooserListsMountedSourcesEscapesAndOpensFolderPanel() {
        let app = XCUIApplication()
        app.launch()
        let choose = app.buttons["Choose…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10))

        choose.click()
        let chooserTitle = app.staticTexts["Choose a Source"]
        XCTAssertTrue(chooserTitle.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(chooserTitle.waitForExistence(timeout: 1))

        choose.click()
        let chooseFolder = app.buttons["Choose Folder…"]
        XCTAssertTrue(chooseFolder.waitForExistence(timeout: 3))
        chooseFolder.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }
}
