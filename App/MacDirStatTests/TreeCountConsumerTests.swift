import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

/// The three places the app used to walk a subtree to answer a question about
/// names — the tree's Items cell, the Items comparator, and the inspector's
/// "Contains" row — now read a count the scan folded before it published the
/// tree.
///
/// What is being pinned here is that **nothing on screen changed**. The engine's
/// own suite proves the counts against independent folds; this file proves the
/// app is reading the right one of them in each place, because the whole risk of
/// the change is a plausible-looking number with the wrong semantics behind it.
@MainActor
final class TreeCountConsumerTests: XCTestCase {
    // MARK: - Oracles: the walks this work replaced, kept as test-only code

    /// The tree's old Items walk, verbatim: presentation semantics, stopping
    /// below a package.
    private func presentedDescendants(of node: ScanNode) -> Int {
        var count = 0
        var stack = node.children
        while let current = stack.popLast() {
            count += 1
            if current.kind != .package { stack.append(contentsOf: current.children) }
        }
        return count
    }

    /// The inspector's old folder walk, verbatim: scanner semantics, walking
    /// straight through a package.
    private func folderDescendants(of node: ScanNode) -> Int64 {
        var folders: Int64 = 0
        var stack = node.children
        while let current = stack.popLast() {
            if current.isDirectoryLike { folders += 1 }
            stack.append(contentsOf: current.children)
        }
        return folders
    }

    /// A tree with the two shapes that make the semantics diverge: a package
    /// with folders inside it, and an ordinary folder nested two deep.
    ///
    /// ```
    /// root
    ///   Editor.app/          package
    ///     Contents/
    ///       Info.plist
    ///       Resources/
    ///         art.png
    ///   docs/
    ///     a.txt
    ///     b.txt
    ///     nested/
    ///       deep.bin
    ///   empty/
    ///   solo.bin
    /// ```
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            let package = try makeDirectory("Editor.app", in: root)
            let contents = try makeDirectory("Contents", in: package)
            try writeFile("Info.plist", bytes: 512, in: contents)
            let resources = try makeDirectory("Resources", in: contents)
            try writeFile("art.png", bytes: 256, in: resources)

            let docs = try makeDirectory("docs", in: root)
            try writeFile("a.txt", bytes: 10, in: docs)
            try writeFile("b.txt", bytes: 20, in: docs)
            let nested = try makeDirectory("nested", in: docs)
            try writeFile("deep.bin", bytes: 300, in: nested)

            _ = try makeDirectory("empty", in: root)
            try writeFile("solo.bin", bytes: 40, in: root)
        }
    }

    private func itemsCellText(
        _ tree: DirectoryTreeViewController,
        for node: ScanNode
    ) throws -> String {
        let outline = tree.outlineView
        let column = try XCTUnwrap(
            outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(TreeColumn.items.rawValue))
        )
        let cell = try XCTUnwrap(tree.outlineView(outline, viewFor: column, item: node) as? NSTableCellView)
        return try XCTUnwrap(cell.textField?.stringValue)
    }

    // MARK: - The Items column

    func test_itemsCellsShowTheSameCountTheOldSubtreeWalkProduced() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let formatter = DisplayFormatter(locale: Locale(identifier: "en_US"))

        var stack = [fixture.rootNode]
        var checked = 0
        while let node = stack.popLast() {
            let text = try itemsCellText(tree, for: node)
            if node.isDirectoryLike {
                XCTAssertEqual(
                    text, formatter.count(Int64(presentedDescendants(of: node))),
                    "\(node.name)'s Items cell no longer matches the walk it replaced"
                )
                checked += 1
            } else {
                XCTAssertEqual(text, "—", "\(node.name) is not directory-like and shows no count")
            }
            stack.append(contentsOf: node.children)
        }
        XCTAssertGreaterThanOrEqual(checked, 6, "the fixture must actually exercise several directories")
    }

    /// The numbers themselves, hand-counted, so a change to the semantics fails
    /// here and not only against an oracle that changed with it.
    func test_aPackageIsOneItemToItsParentAndStillDescribesItsOwnContents() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController

        // Editor.app, docs (+4 below it), empty, solo.bin — the package's
        // interior is not among them.
        XCTAssertEqual(try itemsCellText(tree, for: fixture.rootNode), "8")
        // The package row still says what is inside it: Contents, Info.plist,
        // Resources, art.png.
        XCTAssertEqual(try itemsCellText(tree, for: try fixture.node(named: "Editor.app")), "4")
        XCTAssertEqual(try itemsCellText(tree, for: try fixture.node(named: "docs")), "4")
        XCTAssertEqual(try itemsCellText(tree, for: try fixture.node(named: "nested")), "1")
        XCTAssertEqual(try itemsCellText(tree, for: try fixture.node(named: "empty")), "0")
    }

    /// Sorting by Items uses the stored count in the chosen direction and keeps
    /// the `NameOrder` tie-break — the same rule that decides which of two
    /// equal siblings the treemap draws first, so a row and its rectangle can
    /// never disagree.
    func test_itemsSortingOrdersByTheStoredCountAndTiesBreakOnName() async throws {
        // Four direct children with counts 3, 3, 1, 0 — two of them tied, and
        // named so that name order and any incidental order disagree.
        let fixture = try await ScannedFixture.make(in: self) { root in
            let zebra = try makeDirectory("zebra", in: root)
            try writeFile("x.bin", bytes: 1, in: zebra)
            try writeFile("y.bin", bytes: 1, in: zebra)
            try writeFile("z.bin", bytes: 1, in: zebra)

            let alpha = try makeDirectory("alpha", in: root)
            try writeFile("x.bin", bytes: 1, in: alpha)
            try writeFile("y.bin", bytes: 1, in: alpha)
            try writeFile("z.bin", bytes: 1, in: alpha)

            let middle = try makeDirectory("middle", in: root)
            try writeFile("only.bin", bytes: 1, in: middle)

            _ = try makeDirectory("bare", in: root)
        }
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let outline = tree.outlineView

        func childNames() -> [String] {
            (0..<tree.outlineView(outline, numberOfChildrenOfItem: fixture.rootNode)).map {
                (tree.outlineView(outline, child: $0, ofItem: fixture.rootNode) as? ScanNode)?.name ?? "?"
            }
        }

        outline.sortDescriptors = [NSSortDescriptor(key: TreeColumn.items.rawValue, ascending: true)]
        XCTAssertEqual(childNames(), ["bare", "middle", "alpha", "zebra"],
                       "ascending by count; the two threes tie and fall back to name order")

        outline.sortDescriptors = [NSSortDescriptor(key: TreeColumn.items.rawValue, ascending: false)]
        XCTAssertEqual(childNames(), ["alpha", "zebra", "middle", "bare"],
                       "descending by count; the tie-break stays ascending by name")
    }

    // MARK: - The inspector

    /// "Contains" keeps **scanner** semantics: a package's interior counts, and
    /// the walk goes through it. This is the one place where the tree's Items
    /// value and the inspector's folder count are deliberately different
    /// numbers about the same node.
    func test_inspectorContainsStillCountsPackageInteriorsUnderScannerSemantics() async throws {
        let fixture = try await makeFixture()
        let builder = InspectorContentBuilder(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))
        let context = SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)

        func containsRow(_ node: ScanNode) throws -> String {
            let content = builder.content(for: .node(node), in: context)
            return try XCTUnwrap(content.rows.first { $0.label == "Contains" }?.value)
        }

        // The package: Info.plist and art.png, inside Contents and Resources.
        XCTAssertEqual(try containsRow(try fixture.node(named: "Editor.app")), "2 files · 2 folders")
        // The root, counting straight through the package: six files, and six
        // folders — Editor.app, Contents, Resources, docs, nested, empty.
        XCTAssertEqual(try containsRow(fixture.rootNode), "6 files · 6 folders")
        XCTAssertEqual(try containsRow(try fixture.node(named: "docs")), "3 files · 1 folders")

        // And against the walk it replaced, at every directory-like node.
        var stack = [fixture.rootNode]
        while let node = stack.popLast() {
            if node.isDirectoryLike {
                XCTAssertEqual(
                    try containsRow(node),
                    "\(node.fileCount) files · \(folderDescendants(of: node)) folders",
                    "\(node.name)'s Contains row no longer matches the walk it replaced"
                )
            }
            stack.append(contentsOf: node.children)
        }
    }

    /// The two counts on one node, side by side, because the risk this whole
    /// change carries is quietly collapsing them into one.
    func test_theItemsColumnAndTheContainsRowStayDifferentQuestions() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let root = fixture.rootNode

        // The tree stops at the package: eight presented descendants.
        XCTAssertEqual(try itemsCellText(workspace.treeViewController, for: root), "8")
        // The inspector walks through it: six folders below the root.
        XCTAssertEqual(root.folderDescendantCount, 6)
        // And the scan's own file tally is a third number again.
        XCTAssertEqual(root.fileCount, 6)
    }
}
