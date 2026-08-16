import XCTest
@testable import MacDirStat

/// Placeholder for the presentation-model suite (spec §9.1): `@MainActor`
/// models, formatting, chooser policy, selection, and the workspace-action
/// spies that prove only Open and Reveal exist (spec §9.3).
@MainActor
final class MacDirStatScaffoldTests: XCTestCase {
    func test_mainMenuIsBuiltProgrammatically() {
        // The lifecycle is programmatic (spec §4.1): the menu comes from code,
        // not from a storyboard or nib.
        let menu = MainMenu.make()
        XCTAssertEqual(menu.numberOfItems, 1)
        XCTAssertNotNil(menu.item(at: 0)?.submenu)
    }

    func test_mainWindowOpensEmpty() {
        // Ticket 07 replaces this content view controller with the three-pane
        // split; until then "empty window" is the observable behaviour.
        let controller = MainWindowController()
        XCTAssertNotNil(controller.window)
        XCTAssertTrue(controller.window?.contentViewController?.view.subviews.isEmpty ?? false)
    }
}
