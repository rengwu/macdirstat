import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

/// The standard menus, and the key equivalents that only exist because they do.
@MainActor
final class MenuBarTests: XCTestCase {
    private func menu(titled title: String) throws -> NSMenu {
        try XCTUnwrap(MainMenu.menu(titled: title, in: MainMenu.make()))
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title })
    }

    func test_theMenuBarCarriesTheStandardMenus() throws {
        let titles = MainMenu.make().items.map(\.title)
        // The application menu is titled after the process, so it is checked by
        // position; the rest are the ones macOS expects to find by name.
        XCTAssertEqual(titles.count, 6)
        XCTAssertEqual(Array(titles.dropFirst()), ["File", "Edit", "View", "Window", "Help"])
    }

    /// The bug this guards: without these menus the *keystrokes* stop working
    /// app-wide, including in an `NSOpenPanel`'s text fields. Their presence is
    /// the point, not their titles.
    func test_theStandardKeyEquivalentsExist() throws {
        let expected: [(menu: String, title: String, key: String, mask: NSEvent.ModifierFlags)] = [
            ("Window", "Close", "w", .command),
            ("Window", "Minimize", "m", .command),
            ("Edit", "Copy", "c", .command),
            ("Edit", "Cut", "x", .command),
            ("Edit", "Paste", "v", .command),
            ("Edit", "Select All", "a", .command),
        ]
        for expectation in expected {
            let found = try item(expectation.title, in: try menu(titled: expectation.menu))
            XCTAssertEqual(found.keyEquivalent, expectation.key, expectation.title)
            XCTAssertEqual(found.keyEquivalentModifierMask, expectation.mask, expectation.title)
            XCTAssertNotNil(found.action, "\(expectation.title) is a menu item that does nothing")
        }
    }

    /// ⌘O belongs to choosing a scan source, regardless of file selection.
    func test_scanningHasAMenuItemAndAKey() throws {
        let file = try menu(titled: "File")
        let scan = try item(MainMenu.scanFolderTitle, in: file)
        XCTAssertEqual(scan.keyEquivalent, "o")
        XCTAssertEqual(scan.keyEquivalentModifierMask, .command)
        XCTAssertEqual(scan.action, #selector(ScanSourceChoosing.chooseScanSource(_:)))

        let open = try item(FileActionMenu.openTitle, in: file)
        XCTAssertEqual(open.keyEquivalent, "")
        XCTAssertEqual(open.keyEquivalentModifierMask, .command)
    }

    func test_copyPathIsOnFindersOwnShortcut() throws {
        let copyPath = try item(MainMenu.copyPathTitle, in: try menu(titled: "Edit"))
        XCTAssertEqual(copyPath.keyEquivalent, "c")
        XCTAssertEqual(copyPath.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(copyPath.action, #selector(PathCopying.copySelectedPath(_:)))
    }

    func test_theDetailPaneHasAMenuItem() throws {
        let details = try item(MainMenu.hideDetailsTitle, in: try menu(titled: "View"))
        XCTAssertEqual(details.keyEquivalent, "d")
        XCTAssertEqual(details.keyEquivalentModifierMask, .command)
        XCTAssertEqual(details.action, #selector(DetailPaneToggling.toggleDetailPane(_:)))
    }

    /// The menus AppKit fills in itself do nothing until they are handed over.
    func test_theMenusAppKitFillsInCanBeFound() {
        let menu = MainMenu.make()
        XCTAssertNotNil(MainMenu.servicesMenu(in: menu))
        XCTAssertNotNil(MainMenu.menu(titled: "Window", in: menu))
        XCTAssertNotNil(MainMenu.menu(titled: "Help", in: menu))
        XCTAssertNotNil(MainMenu.recentsMenu(in: menu))
    }

    func test_theWholeMenuBarStillOffersNoMutation() {
        let titles = MainMenu.make().items.flatMap { item in
            [item.title] + (item.submenu?.items.map(\.title) ?? [])
        }
        assertNoMutationAffordance(in: titles, context: "the main menu")
    }
}

/// Open Recent, and what it is built from.
@MainActor
final class RecentScansTests: XCTestCase {
    private func makePreferences() -> Preferences {
        Preferences(store: InMemoryPreferenceStore())
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDirStat-Recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_theMostRecentScanComesFirstAndIsNotRepeated() throws {
        let preferences = makePreferences()
        let first = try makeDirectory()
        let second = try makeDirectory()

        preferences.rememberScan(first)
        preferences.rememberScan(second)
        preferences.rememberScan(first)

        XCTAssertEqual(preferences.recentScans, [first, second], "re-scanning reorders rather than duplicates")
        XCTAssertEqual(preferences.lastScan, first)
    }

    /// A recent folder can be deleted or its volume unmounted while the app is
    /// running, and an entry that scans nothing is worse than no entry.
    func test_aFolderThatIsGoneIsNotOffered() throws {
        let preferences = makePreferences()
        let kept = try makeDirectory()
        let removed = try makeDirectory()
        preferences.rememberScan(kept)
        preferences.rememberScan(removed)
        try FileManager.default.removeItem(at: removed)

        XCTAssertEqual(preferences.recentScans, [kept])
    }

    func test_theListIsCapped() throws {
        let preferences = makePreferences()
        for _ in 0...Preferences.recentScanLimit {
            preferences.rememberScan(try makeDirectory())
        }
        XCTAssertEqual(preferences.recentScans.count, Preferences.recentScanLimit)
    }

    func test_theSubmenuIsBuiltFromTheRecentsAndCanBeCleared() throws {
        let preferences = makePreferences()
        let folder = try makeDirectory()
        preferences.rememberScan(folder)

        let menu = MainMenu.makeRecentsMenu()
        MainMenu.populateRecentsMenu(menu, with: preferences.recentScans)

        let scan = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(scan.title, folder.lastPathComponent)
        XCTAssertEqual(scan.representedObject as? URL, folder)
        XCTAssertEqual(scan.action, #selector(ScanSourceChoosing.openRecentScan(_:)))

        let clear = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(clear.title, MainMenu.clearRecentTitle)
        XCTAssertTrue(clear.isEnabled)

        // Emptied, the menu keeps only a disabled Clear: an Open Recent that
        // opens onto nothing at all reads as broken.
        MainMenu.populateRecentsMenu(menu, with: [])
        XCTAssertEqual(menu.items.map(\.title), [MainMenu.clearRecentTitle])
        XCTAssertFalse(menu.items[0].isEnabled)
    }
}

/// What the app remembers between launches.
@MainActor
final class PreferencesTests: XCTestCase {
    func test_fastModeIsRememberedRatherThanReAsked() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        XCTAssertEqual(preferences.packageScanMode, .detailed, "the default is the full tree")
        preferences.packageScanMode = .summarized
        XCTAssertEqual(preferences.packageScanMode, .summarized)
    }

    /// Column autosave covers width and order and stops there.
    func test_theSortSurvivesALaunch() {
        let store = InMemoryPreferenceStore()
        XCTAssertNil(Preferences(store: store).treeSort)
        Preferences(store: store).treeSort = (.name, true)

        let reopened = try? XCTUnwrap(Preferences(store: store).treeSort)
        XCTAssertEqual(reopened?.column, .name)
        XCTAssertEqual(reopened?.ascending, true)
    }

    func test_theTreeOpensOnTheRememberedSort() {
        let store = InMemoryPreferenceStore()
        Preferences(store: store).treeSort = (.items, true)
        let tree = DirectoryTreeViewController(
            formatter: DisplayFormatter(locale: Locale(identifier: "en_US")),
            preferences: Preferences(store: store)
        )
        _ = tree.view

        let descriptor = tree.outlineView.sortDescriptors.first
        XCTAssertEqual(descriptor?.key, TreeColumn.items.rawValue)
        XCTAssertEqual(descriptor?.ascending, true)
    }

    func test_theTreeFallsBackToSizeDescending() {
        let tree = DirectoryTreeViewController(
            formatter: DisplayFormatter(locale: Locale(identifier: "en_US")),
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
        _ = tree.view

        let descriptor = tree.outlineView.sortDescriptors.first
        XCTAssertEqual(descriptor?.key, TreeColumn.size.rawValue)
        XCTAssertEqual(descriptor?.ascending, false)
    }

    /// The window frame was already remembered; the dividers inside it were not.
    func test_bothSplitViewsAutosaveTheirDividers() {
        let controller = MainWindowController(preferences: Preferences(store: InMemoryPreferenceStore()))
        let workspace = controller.workspaceViewController
        XCTAssertEqual(workspace.splitView.autosaveName, "MacDirStatWorkspaceSplit")
        XCTAssertEqual(
            workspace.listDetailViewController.splitView.autosaveName,
            "MacDirStatListDetailSplit"
        )
    }

    func test_theTreeAutosavesItsColumnsButNotItsOpenRows() {
        let controller = MainWindowController(preferences: Preferences(store: InMemoryPreferenceStore()))
        let outline = controller.workspaceViewController.treeViewController.outlineView
        XCTAssertEqual(outline.autosaveName, "MacDirStatDirectoryTree")
        XCTAssertTrue(outline.autosaveTableColumns)
        // The tree is rebuilt from a fresh scan every time, so a remembered
        // expansion refers to nodes that no longer exist.
        XCTAssertFalse(outline.autosaveExpandedItems)
    }
}

/// Copying the path, showing and hiding the detail pane, and the titlebar controls
/// that go with them.
@MainActor
final class WorkspaceCommandTests: XCTestCase {
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            try writeFile("report.pdf", bytes: 4_096, in: root)
        }
    }

    func test_copyPathWritesThePathAndNothingElse() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacDirStatTestPasteboard"))
        pasteboard.clearContents()
        workspace.pasteboard = pasteboard

        let node = try fixture.node(named: "report.pdf")
        workspace.selectionModel.select(.node(node), source: .tree)
        workspace.copySelectedPath(nil)

        XCTAssertEqual(pasteboard.string(forType: .string), fixture.root.appendingPathComponent("report.pdf").path)
        // The clipboard is not the disk: nothing was opened, revealed or moved.
        XCTAssertTrue(actions.opened.isEmpty)
        XCTAssertTrue(actions.revealed.isEmpty)
    }

    func test_copyPathIsDisabledWithNothingToCopy() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let item = NSMenuItem(
            title: MainMenu.copyPathTitle,
            action: #selector(PathCopying.copySelectedPath(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(workspace.validateMenuItem(item), "nothing is selected")

        workspace.selectionModel.select(.node(try fixture.node(named: "report.pdf")), source: .tree)
        XCTAssertTrue(workspace.validateMenuItem(item))
    }

    /// The pane collapses, and until this existed nothing brought it back.
    func test_theDetailPaneTogglesBothWays() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        XCTAssertFalse(workspace.isDetailPaneCollapsed)

        workspace.toggleDetailPane(nil)
        XCTAssertTrue(workspace.isDetailPaneCollapsed)
        XCTAssertTrue(workspace.preferences.isDetailPaneCollapsed, "and it is remembered")

        workspace.toggleDetailPane(nil)
        XCTAssertFalse(workspace.isDetailPaneCollapsed)
        XCTAssertFalse(workspace.preferences.isDetailPaneCollapsed)
    }

    func test_togglingDetailsNeverMovesOrResizesTheWindow() throws {
        let controller = MainWindowController(
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
        let window = try XCTUnwrap(controller.window)
        let workspace = controller.workspaceViewController
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.setFrame(NSRect(x: 120, y: 180, width: 720, height: 560), display: false)
        controller.contentViewController?.view.layoutSubtreeIfNeeded()
        workspace.listDetailViewController.splitView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let originalFrame = window.frame

        workspace.toggleDetailPane(nil)
        XCTAssertEqual(window.frame, originalFrame, "hiding details changed the window frame")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let collapsedFrame = window.frame
        XCTAssertEqual(collapsedFrame, originalFrame, "hiding details changed the window frame later")

        workspace.toggleDetailPane(nil)
        XCTAssertEqual(window.frame, collapsedFrame, "showing details changed the window frame")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(window.frame, collapsedFrame, "showing details changed the window frame later")
    }

    func test_theDetailMenuItemSaysWhichWayItWillGo() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let item = NSMenuItem(
            title: "",
            action: #selector(DetailPaneToggling.toggleDetailPane(_:)),
            keyEquivalent: ""
        )

        XCTAssertTrue(workspace.validateMenuItem(item))
        XCTAssertEqual(item.title, MainMenu.hideDetailsTitle)

        workspace.toggleDetailPane(nil)
        XCTAssertTrue(workspace.validateMenuItem(item))
        XCTAssertEqual(item.title, MainMenu.showDetailsTitle)
    }

    func test_theTitlebarStripIsCompactAndCanShowTheDetailPane() throws {
        let controller = MainWindowController(preferences: Preferences(store: InMemoryPreferenceStore()))
        let strip = try XCTUnwrap(controller.commandStripController)
        let toggle = strip.detailsButton

        XCTAssertNil(controller.window?.toolbar, "a toolbar would mirror scrolled rows into its glass")
        XCTAssertEqual(strip.buttons.count, 3)
        XCTAssertFalse(strip.buttons.contains { $0.action == #selector(FileActionResponding.openSelectedItem(_:)) })
        XCTAssertEqual(strip.revealButton.toolTip, "Reveal in Finder")
        XCTAssertEqual(TitlebarCommandStripViewController.buttonSize, NSSize(width: 32, height: 26))
        XCTAssertEqual(TitlebarCommandStripViewController.symbolPointSize, 12)
        XCTAssertTrue(strip.buttons.allSatisfy(\.showsBorderOnlyWhileMouseInside))
        XCTAssertTrue(strip.buttons.allSatisfy { $0.contentTintColor == .labelColor })
        if #available(macOS 26.1, *) {
            XCTAssertTrue(
                strip.preferredScrollEdgeEffectStyle === NSScrollEdgeEffectStyle.hard
            )
        }
        XCTAssertEqual(toggle.action, #selector(DetailPaneToggling.toggleDetailPane(_:)))
        assertNoMutationAffordance(
            in: strip.buttons.compactMap { $0.accessibilityLabel() },
            context: "the titlebar command strip"
        )
    }

    func test_theTitlebarFileActionsFollowTheSharedSelection() async throws {
        let fixture = try await makeFixture()
        let controller = MainWindowController(preferences: Preferences(store: InMemoryPreferenceStore()))
        let strip = try XCTUnwrap(controller.commandStripController)

        XCTAssertFalse(strip.revealButton.isEnabled)
        controller.workspaceViewController.selectionModel.select(
            .node(try fixture.node(named: "report.pdf")),
            source: .tree
        )
        XCTAssertTrue(strip.revealButton.isEnabled)
    }
}

/// The empty state's offer to pick the last scan up again.
@MainActor
final class RescanOfferTests: XCTestCase {
    func test_theEmptyStateOffersTheLastScanOnlyWhenThereIsOne() {
        let empty = EmptyStateView()
        let rescan = try? XCTUnwrap(empty.arrangedSubviews.compactMap { $0 as? NSButton }.last)
        XCTAssertEqual(rescan?.isHidden, true, "a machine that has never scanned is offered nothing")

        let folder = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        empty.lastScannedSource = folder
        XCTAssertEqual(rescan?.isHidden, false)
        XCTAssertTrue(rescan?.title.contains("Shared") ?? false)

        var asked: URL?
        empty.onRescan = { asked = $0 }
        rescan.map { _ = $0.target?.perform($0.action, with: $0) }
        XCTAssertEqual(asked, folder)
    }
}

/// The legend, which used to lose swatches off the right edge in silence.
@MainActor
final class StatusLegendTests: XCTestCase {
    private func makeLegend(width: CGFloat) -> WrappingRowView {
        let view = WrappingRowView()
        view.setItems((0..<13).map { index in
            let label = NSTextField(labelWithString: "Legend \(index)")
            label.font = .systemFont(ofSize: 10.5)
            return label
        })
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.height(forWidth: width))
        view.layout()
        return view
    }

    /// The bug: a `lessThanOrEqualTo` trailing constraint simply did not draw
    /// the swatches past the edge — no ellipsis, no scroll, no indication that
    /// a colour the treemap is using has no key.
    func test_everySwatchIsInsideTheViewHoweverNarrowItIs() {
        for width in [1_400.0, 700.0, 380.0] as [CGFloat] {
            let legend = makeLegend(width: width)
            for item in legend.subviews {
                XCTAssertLessThanOrEqual(
                    item.frame.maxX,
                    width + 0.5,
                    "a legend item runs off the edge at \(width) pt"
                )
                XCTAssertLessThanOrEqual(item.frame.maxY, legend.frame.height + 0.5)
            }
            XCTAssertEqual(legend.subviews.count, 13, "every swatch is still there")
        }
    }

    func test_aNarrowerBarIsATallerOne() {
        let wide = makeLegend(width: 1_400).frame.height
        let narrow = makeLegend(width: 380).frame.height
        XCTAssertGreaterThan(narrow, wide, "wrapping is what costs the height")
    }

    func test_theStatusBarGrowsToHoldTheRowsItWraps() {
        let statusBar = StatusBarViewController(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))
        var heights: [CGFloat] = []
        statusBar.onHeightChange = { heights.append($0) }
        _ = statusBar.view
        statusBar.view.frame = NSRect(x: 0, y: 0, width: 400, height: 26)
        statusBar.viewDidLayout()

        // Nothing scanned yet: the summary line and nothing else.
        XCTAssertTrue(heights.isEmpty || heights.allSatisfy { $0 == StatusBarViewController.summaryOnlyHeight })
    }
}

/// Reaching the rectangles from the keyboard.
@MainActor
final class TreemapKeyboardTests: XCTestCase {
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            for (index, size) in ([900_000, 700_000, 500_000, 300_000, 200_000] as [Int64]).enumerated() {
                try writeAllocatedFile("file-\(index).bin", bytes: size, in: root)
            }
        }
    }

    func test_theMapAcceptsTheKeyboardAtAll() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        XCTAssertTrue(workspace.treemapViewController.treemapView.acceptsFirstResponder)
    }

    /// With nothing selected, the first arrow starts on the biggest rectangle —
    /// the one the eye starts on too.
    func test_theFirstArrowStartsOnTheLargestRectangle() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        XCTAssertNil(workspace.selectionModel.selection)

        XCTAssertTrue(treemap.moveSelection(.right))
        XCTAssertEqual(workspace.selectionModel.selection?.node?.name, "file-0.bin")
    }

    func test_arrowsWalkFromRectangleToRectangleAndStopAtTheEdge() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        _ = treemap.moveSelection(.right)
        let start = try XCTUnwrap(workspace.selectionModel.selection?.node?.name)

        XCTAssertTrue(treemap.moveSelection(.right), "there is something to the right of the first box")
        let moved = try XCTUnwrap(workspace.selectionModel.selection?.node?.name)
        XCTAssertNotEqual(moved, start)

        // Walk to the right edge; the last press has nowhere to go and says so
        // rather than wrapping around.
        while treemap.moveSelection(.right) {}
        XCTAssertFalse(treemap.moveSelection(.right))
        XCTAssertNotNil(workspace.selectionModel.selection, "and it keeps what it had")
    }

    func test_goingRightAndBackLandsWhereItStarted() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        _ = treemap.moveSelection(.right)
        let start = try XCTUnwrap(workspace.selectionModel.selection?.node?.name)

        guard treemap.moveSelection(.right) else {
            return XCTFail("the fixture should lay out more than one rectangle in a row")
        }
        XCTAssertTrue(treemap.moveSelection(.left))
        XCTAssertEqual(workspace.selectionModel.selection?.node?.name, start)
    }

    func test_returnOpensWhatIsSelected() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        _ = treemap.moveSelection(.right)

        treemap.onActivate?()
        XCTAssertEqual(actions.opened.count, 1)
        XCTAssertTrue(actions.revealed.isEmpty)
    }
}

/// Telling the user a scan finished while they were somewhere else.
@MainActor
final class ScanCompletionNotificationTests: XCTestCase {
    private func makeController(
        notifier: RecordingScanCompletionNotifier,
        active: Bool
    ) -> (MainWindowController, ScanPresentationModel) {
        let formatter = DisplayFormatter(locale: Locale(identifier: "en_US"))
        let model = ScanPresentationModel()
        let preferences = Preferences(store: InMemoryPreferenceStore())
        let workspace = WorkspaceSplitViewController(
            model: model,
            formatter: formatter,
            preferences: preferences
        )
        let controller = MainWindowController(
            workspace: workspace,
            statusBar: StatusBarViewController(formatter: formatter),
            preferences: preferences,
            scanNotifier: notifier
        )
        controller.isApplicationActive = { active }
        return (controller, model)
    }

    /// The one that matters: frontmost means silent. The status line is right
    /// there, and a notification for something you are looking at is noise.
    func test_nothingIsPostedWhileTheAppIsFrontmost() async throws {
        let notifier = RecordingScanCompletionNotifier()
        let (controller, _) = makeController(notifier: notifier, active: true)
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("report.pdf", bytes: 4_096, in: root)
        }

        let finished = expectation(description: "scan finished")
        let workspace = controller.workspaceViewController
        let previous = workspace.onScanModelChange
        workspace.onScanModelChange = {
            previous?()
            if workspace.model.phase == .completed { finished.fulfill() }
        }
        workspace.start(root: fixture.root, mode: .folder)
        await fulfillment(of: [finished], timeout: 20)

        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func test_aBackgroundedScanPostsOnceWithTheFolderName() async throws {
        let notifier = RecordingScanCompletionNotifier()
        let (controller, _) = makeController(notifier: notifier, active: false)
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("report.pdf", bytes: 4_096, in: root)
        }

        let finished = expectation(description: "scan finished")
        let workspace = controller.workspaceViewController
        let previous = workspace.onScanModelChange
        workspace.onScanModelChange = {
            previous?()
            if workspace.model.phase == .completed { finished.fulfill() }
        }
        workspace.start(root: fixture.root, mode: .folder)
        await fulfillment(of: [finished], timeout: 20)

        XCTAssertEqual(notifier.posted.count, 1, "once per finished scan, not once per progress tick")
        XCTAssertTrue(notifier.posted[0].title.contains(fixture.root.lastPathComponent))
    }
}
