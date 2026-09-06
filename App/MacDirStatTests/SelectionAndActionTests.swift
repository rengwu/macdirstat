import AppKit
import ScanCore
import TreemapLayout
import XCTest
@testable import MacDirStat

@MainActor
final class SelectionModelTests: XCTestCase {
    func test_oneWriteNotifiesEveryPaneAndCarriesWhoWroteIt() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("a.bin", bytes: 10, in: root)
        }
        let model = SelectionModel()
        var seen: [SelectionSource] = []
        model.addObserver { seen.append($0.source) }
        model.addObserver { _ in }

        model.select(.node(try fixture.node(named: "a.bin")), source: .treemap)

        XCTAssertEqual(seen, [.treemap])
        XCTAssertNotNil(model.selection)
    }

    func test_reselectingTheSameThingNotifiesNobody() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("a.bin", bytes: 10, in: root)
        }
        let node = try fixture.node(named: "a.bin")
        let model = SelectionModel()
        var notifications = 0
        model.addObserver { _ in notifications += 1 }

        model.select(.node(node), source: .treemap)
        model.select(.node(node), source: .tree)

        XCTAssertEqual(notifications, 1, "an echo must not bounce back between the panes")
    }

    func test_twoSiblingsOfTheSameNameAndSizeAreStillDifferentSelections() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let left = try makeDirectory("left", in: root)
            let right = try makeDirectory("right", in: root)
            try writeFile("same.bin", bytes: 128, in: left)
            try writeFile("same.bin", bytes: 128, in: right)
        }
        let left = try XCTUnwrap(fixture.node(named: "left").children.first)
        let right = try XCTUnwrap(fixture.node(named: "right").children.first)

        XCTAssertEqual(left.name, right.name)
        XCTAssertEqual(left.subtreeDiskBytes, right.subtreeDiskBytes)
        XCTAssertNotEqual(WorkspaceSelection.node(left), WorkspaceSelection.node(right))
    }
}

@MainActor
final class BidirectionalSelectionTests: XCTestCase {
    /// One large file plus one small folder, in a viewport big enough that
    /// nothing merges — so every entry has its own rectangle.
    private func makeSimpleFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            try writeFile("large.mp4", bytes: 800_000, in: root)
            let folder = try makeDirectory("docs", in: root)
            try writeFile("paper.pdf", bytes: 200_000, in: folder)
            try writeFile("empty.txt", bytes: 0, in: root)
        }
    }

    func test_selectingATreeRowStrokesItsRectangleAndFillsTheInspector() async throws {
        let fixture = try await makeSimpleFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let node = try fixture.node(named: "large.mp4")

        workspace.selectionModel.select(.node(node), source: .tree)

        let treemap = workspace.treemapViewController.treemapView
        let layout = try XCTUnwrap(treemap.currentLayout())
        XCTAssertTrue(
            layout.boxes.contains { $0.node?.node === node },
            "the selected node must have a rectangle to stroke"
        )
        XCTAssertEqual(workspace.inspectorViewController.content?.title, "large.mp4")
    }

    func test_clickingARectangleSelectsAndScrollsTheTreeRow() async throws {
        let fixture = try await makeSimpleFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        let outline = workspace.treeViewController.outlineView

        let layout = try XCTUnwrap(treemap.currentLayout())
        let target = try XCTUnwrap(layout.boxes.first { $0.node?.node.name == "paper.pdf" })
        let midpoint = NSPoint(
            x: target.frame.x + target.frame.width / 2,
            y: target.frame.y + target.frame.height / 2
        )
        let index = try XCTUnwrap(treemap.boxIndex(at: midpoint))
        let selection = try XCTUnwrap(treemap.selection(atBoxIndex: index))
        workspace.selectionModel.select(selection, source: .treemap)

        let selectedRow = outline.selectedRow
        XCTAssertGreaterThanOrEqual(selectedRow, 0, "the tree must select the row the rectangle stands for")
        XCTAssertEqual((outline.item(atRow: selectedRow) as? ScanNode)?.name, "paper.pdf")
        XCTAssertEqual(workspace.inspectorViewController.content?.title, "paper.pdf")
    }

    func test_aZeroByteSelectionLeavesNoFalseRectangle() async throws {
        let fixture = try await makeSimpleFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let empty = try fixture.node(named: "empty.txt")
        XCTAssertEqual(empty.subtreeDiskBytes, 0)

        workspace.selectionModel.select(.node(empty), source: .tree)

        let layout = try XCTUnwrap(workspace.treemapViewController.treemapView.currentLayout())
        XCTAssertFalse(
            layout.boxes.contains { $0.node?.node === empty },
            "a zero-byte entry has no area, so it must not acquire a rectangle when selected"
        )
        // It is still fully described — §6.2's "never vanish from the product".
        XCTAssertEqual(workspace.inspectorViewController.content?.title, "empty.txt")
        XCTAssertEqual(workspace.inspectorViewController.content?.exactBytesText, "0 bytes")
    }

    func test_selectingAnAggregateDescribesTheBucketWithoutInventingANode() async throws {
        // A dominant file plus a long tail of tiny ones: at this viewport the
        // tail cannot be drawn individually, so it folds into one box.
        let fixture = try await ScannedFixture.make(in: self) { root in
            // Half a gigabyte of blocks against sixty single-block files. It
            // has to be this lopsided now that the app measures blocks: a
            // 16-byte file still occupies a whole block, so a tail folds into
            // an aggregate only beside something genuinely enormous.
            try writeAllocatedFile("dominant.mp4", bytes: 512 * 1_024 * 1_024, in: root)
            for index in 1...60 {
                try writeFile("tiny-\(index).bin", bytes: 16, in: root)
            }
        }
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        let layout = try XCTUnwrap(treemap.currentLayout())
        let aggregateIndex = try XCTUnwrap(layout.boxes.firstIndex { $0.isAggregate })
        let selection = try XCTUnwrap(treemap.selection(atBoxIndex: aggregateIndex))

        workspace.selectionModel.select(selection, source: .treemap)

        let descriptor = try XCTUnwrap(workspace.selectionModel.selection?.aggregate)
        XCTAssertNil(workspace.selectionModel.selection?.node, "the bucket must not be given a stand-in node")
        XCTAssertTrue(descriptor.directory === fixture.rootNode)
        XCTAssertGreaterThan(descriptor.itemCount, 1)
        XCTAssertEqual(workspace.treeViewController.outlineView.selectedRow, -1, "no tree row stands for a bucket")

        let content = try XCTUnwrap(workspace.inspectorViewController.content)
        XCTAssertTrue(content.title.hasSuffix("merged items"))
        XCTAssertFalse(content.showsActions)
        XCTAssertNil(workspace.selectedURL, "an aggregate has no URL to act on")
    }

    func test_selectionPersistsThroughRelayout() async throws {
        let fixture = try await makeSimpleFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        let node = try fixture.node(named: "paper.pdf")
        workspace.selectionModel.select(.node(node), source: .tree)

        let before = try XCTUnwrap(treemap.currentLayout())
        treemap.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        let after = try XCTUnwrap(treemap.currentLayout())

        XCTAssertNotEqual(
            before.boxes.first?.frame.width,
            after.boxes.first?.frame.width,
            "the resize must have produced a different layout for this to prove anything"
        )
        XCTAssertTrue(workspace.selectionModel.selection?.node === node)
        XCTAssertTrue(after.boxes.contains { $0.node?.node === node })
        XCTAssertEqual(workspace.inspectorViewController.content?.title, "paper.pdf")
    }

    func test_expandingAPackageInTheTreeSubdividesItsBoxWithoutChangingItsArea() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let package = try makeDirectory("Editor.app", in: root)
            let contents = try makeDirectory("Contents", in: package)
            try writeFile("binary.dylib", bytes: 400_000, in: contents)
            try writeFile("art.png", bytes: 200_000, in: contents)
            try writeFile("sibling.mp4", bytes: 600_000, in: root)
        }
        let package = try fixture.node(named: "Editor.app")
        try XCTSkipIf(package.kind != .package, "this host did not classify Editor.app as a package")

        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView

        let collapsed = try XCTUnwrap(treemap.currentLayout())
        let collapsedBox = try XCTUnwrap(collapsed.boxes.first { $0.node?.node === package })
        XCTAssertFalse(collapsedBox.isSubdivided, "a package presents as one box until it is drilled into")

        treemap.setPackage(package, expanded: true)

        let expanded = try XCTUnwrap(treemap.currentLayout())
        let expandedBox = try XCTUnwrap(expanded.boxes.first { $0.node?.node === package })
        XCTAssertTrue(expandedBox.isSubdivided, "drilling in subdivides it exactly like a folder")
        XCTAssertEqual(expandedBox.frame.area, collapsedBox.frame.area, accuracy: 0.001,
                       "the outer rectangle's area never changes — the bytes were counted at scan time")
    }
}

@MainActor
final class ReadOnlyActionTests: XCTestCase {
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            let folder = try makeDirectory("nested", in: root)
            try writeFile("report.pdf", bytes: 4_096, in: folder)
        }
    }

    func test_openAndRevealCallOnlyTheSpyWithTheExactReconstructedURL() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()
        let node = try fixture.node(named: "report.pdf")
        let expected = fixture.root
            .appendingPathComponent("nested")
            .appendingPathComponent("report.pdf")

        workspace.selectionModel.select(.node(node), source: .tree)
        workspace.openSelectedItem(nil)
        workspace.revealSelectedItem(nil)

        XCTAssertEqual(actions.opened, [expected])
        XCTAssertEqual(actions.revealed, [expected])
        XCTAssertEqual(actions.callCount, 2, "nothing else may reach the workspace seam")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), "the URL must name a real file")
    }

    func test_noSelectionMeansNoCallAndADisabledCommand() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()

        let item = NSMenuItem(
            title: FileActionMenu.openTitle,
            action: #selector(FileActionResponding.openSelectedItem(_:)),
            keyEquivalent: "o"
        )
        XCTAssertFalse(workspace.validateMenuItem(item))

        workspace.openSelectedItem(nil)
        workspace.revealSelectedItem(nil)
        XCTAssertEqual(actions.callCount, 0)

        workspace.selectionModel.select(.node(try fixture.node(named: "report.pdf")), source: .tree)
        XCTAssertTrue(workspace.validateMenuItem(item))
    }

    func test_theInspectorButtonsCallTheSameSeam() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()
        workspace.selectionModel.select(.node(try fixture.node(named: "report.pdf")), source: .tree)

        workspace.inspectorViewController.state.onOpen()
        workspace.inspectorViewController.state.onReveal()

        XCTAssertEqual(actions.opened.count, 1)
        XCTAssertEqual(actions.revealed.count, 1)
    }

    func test_returnExpandsADirectoryAndOpensAFile() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let folder = try fixture.node(named: "nested")

        workspace.selectionModel.select(.node(folder), source: .treemap)
        tree.activateSelectedRow()
        XCTAssertTrue(tree.outlineView.isItemExpanded(folder), "Return expands a directory row")
        XCTAssertEqual(actions.callCount, 0, "expanding is not opening")

        workspace.selectionModel.select(.node(try fixture.node(named: "report.pdf")), source: .treemap)
        tree.activateSelectedRow()
        XCTAssertEqual(actions.opened.count, 1, "Return opens a leaf row")
    }

    func test_onlyRevealHasAFileActionShortcut() {
        let menu = MainMenu.make()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        let open = items.first { $0.title == FileActionMenu.openTitle }
        let reveal = items.first { $0.title == FileActionMenu.revealTitle }

        XCTAssertEqual(open?.keyEquivalent, "")
        XCTAssertEqual(open?.keyEquivalentModifierMask, .command)
        XCTAssertEqual(reveal?.keyEquivalent, "r")
        XCTAssertEqual(reveal?.keyEquivalentModifierMask, .command)
    }

    func test_rightClickingARectangleSelectsItFirstAndOffersOnlyOpenAndReveal() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            // Half a gigabyte of blocks against sixty single-block files. It
            // has to be this lopsided now that the app measures blocks: a
            // 16-byte file still occupies a whole block, so a tail folds into
            // an aggregate only beside something genuinely enormous.
            try writeAllocatedFile("dominant.mp4", bytes: 512 * 1_024 * 1_024, in: root)
            for index in 1...60 {
                try writeFile("tiny-\(index).bin", bytes: 16, in: root)
            }
        }
        let (workspace, _, _) = fixture.makeWorkspace()
        let treemap = workspace.treemapViewController.treemapView
        let layout = try XCTUnwrap(treemap.currentLayout())

        let file = try XCTUnwrap(layout.boxes.first { $0.node?.node.name == "dominant.mp4" })
        let menu = try XCTUnwrap(
            treemap.contextMenu(
                at: NSPoint(x: file.frame.x + file.frame.width / 2, y: file.frame.y + file.frame.height / 2)
            )
        )
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [FileActionMenu.openTitle, FileActionMenu.revealTitle, FileActionMenu.copyPathTitle]
        )
        XCTAssertEqual(
            workspace.selectionModel.selection?.node?.name,
            "dominant.mp4",
            "the menu must act on what it points at, so the right-click selects first"
        )

        let aggregate = try XCTUnwrap(layout.boxes.first { $0.isAggregate })
        XCTAssertNil(
            treemap.contextMenu(
                at: NSPoint(
                    x: aggregate.frame.x + aggregate.frame.width / 2,
                    y: aggregate.frame.y + aggregate.frame.height / 2
                )
            ),
            "an aggregate is not a file, so it gets no menu at all"
        )
    }

    func test_everyMenuCommandStripAndContextMenuCarriesOnlyTheTwoReadOnlyActions() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()

        let contextMenu = FileActionMenu.make()
        XCTAssertEqual(
            contextMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [FileActionMenu.openTitle, FileActionMenu.revealTitle, FileActionMenu.copyPathTitle],
            "the context menu is these three and never gains a fourth"
        )
        // The point of ticket 01, decision 3 restated as what it protects:
        // every item here either reads a file or reads a path. None writes.
        XCTAssertTrue(
            contextMenu.items.filter { !$0.isSeparatorItem }.allSatisfy { item in
                [
                    #selector(FileActionResponding.openSelectedItem(_:)),
                    #selector(FileActionResponding.revealSelectedItem(_:)),
                    #selector(PathCopying.copySelectedPath(_:)),
                ].contains(item.action)
            },
            "a context-menu item that sends anything but the three read-only actions"
        )

        let mainMenuTitles = MainMenu.make().items.flatMap { item in
            [item.title] + (item.submenu?.items.map(\.title) ?? [])
        }
        assertNoMutationAffordance(in: mainMenuTitles, context: "the main menu")
        assertNoMutationAffordance(in: contextMenu.items.map(\.title), context: "the context menu")

        let controller = MainWindowController()
        let commandLabels = try XCTUnwrap(controller.commandStripController).buttons.compactMap {
            $0.accessibilityLabel()
        }
        assertNoMutationAffordance(in: commandLabels, context: "the titlebar command strip")
        XCTAssertFalse(commandLabels.contains(FileActionMenu.openTitle))
        XCTAssertTrue(commandLabels.contains(MainMenu.scanFolderTitle))
        XCTAssertTrue(commandLabels.contains(FileActionMenu.revealTitle))

        workspace.selectionModel.select(.node(try fixture.node(named: "report.pdf")), source: .tree)
        let elements = workspace.treemapViewController.treemapView.accessibilityRectangleElements()
        assertNoMutationAffordance(
            in: elements.compactMap { $0.accessibilityLabel() },
            context: "the treemap accessibility tree"
        )
    }
}

@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    /// The window rendered **blank** during this ticket: a full-size window,
    /// window chrome and status bar drawn, and the three panes not drawn —
    /// while every one of them was laid out correctly and answering
    /// accessibility queries. Nothing failed; it only looked wrong.
    ///
    /// Bisected to one thing: a background view in the status bar that painted
    /// by overriding `draw(_:)`. Painting the same colour through the layer
    /// instead fixes it. These two tests lock the shapes that fix depends on.
    /// Neither would have *found* the bug — only looking at the screen did,
    /// which is the reason ticket 09's release checklist walks the states by
    /// eye rather than by query.
    func test_backgroundsPaintThroughTheirLayerRatherThanDrawRect() {
        let background = BackgroundView(color: .windowBackgroundColor)

        XCTAssertTrue(background.wantsLayer)
        XCTAssertTrue(
            background.wantsUpdateLayer,
            "a custom-drawing background in this hierarchy stops the split view painting entirely"
        )
    }

    /// The window's content view collapsed to ~40 pt inside a full-size window
    /// once the inspector was hosted: the hosted view is pinned edge-to-edge
    /// and hugs its content, and a constraint-driven content view *sizes the
    /// window*. Lowering the hug is what keeps the demand from travelling up.
    func test_theInspectorsHostedViewDoesNotHugItsContent() {
        let inspector = InspectorViewController()
        _ = inspector.view
        let hosted = inspector.view.subviews.first

        XCTAssertEqual(hosted?.contentHuggingPriority(for: .vertical), .defaultLow)
        XCTAssertEqual(hosted?.contentHuggingPriority(for: .horizontal), .defaultLow)
    }

    /// And the panes then fill the space the window gives them: the two rows
    /// span the workspace's height between them, and the top row's own two
    /// panes are each as tall as that row.
    func test_theWorkspacePanesFillTheContainer() throws {
        let controller = MainWindowController()
        let container = try XCTUnwrap(controller.contentViewController?.view)
        container.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        container.layoutSubtreeIfNeeded()

        let statusHeight = controller.statusBarController.view.frame.height
        XCTAssertGreaterThan(statusHeight, 0)
        let workspace = controller.workspaceViewController
        XCTAssertEqual(
            workspace.view.frame.height,
            700 - statusHeight - WorkspaceContainerViewController.titlebarContentSeparation,
            accuracy: 0.5
        )

        let rows = workspace.splitView.arrangedSubviews.map(\.frame)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertGreaterThan(row.height, 0, "a row squeezed to nothing is a row nobody can read")
        }
        let spanned = (rows.map(\.maxY).max() ?? 0) - (rows.map(\.minY).min() ?? 0)
        XCTAssertEqual(spanned, workspace.splitView.bounds.height, accuracy: 1)

        let row = workspace.listDetailViewController
        for item in row.splitViewItems {
            XCTAssertEqual(
                item.viewController.view.frame.height,
                row.view.frame.height,
                accuracy: 0.5,
                "\(type(of: item.viewController)) is \(item.viewController.view.frame.height) pt tall"
            )
        }
    }
}
