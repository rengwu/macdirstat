import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

/// The outline view's child order, computed once per node per sort
/// configuration.
///
/// `NSOutlineView` asks for children one index at a time, so the cost that
/// matters is **how many times an array was sorted**, not how long a sort took.
/// Everything here is asserted against the cache's own miss counter for that
/// reason: a wall-clock threshold would be a statement about the machine the
/// test ran on.
@MainActor
final class SortedChildrenCacheTests: XCTestCase {
    /// Two sibling directories with several children each, sized and named so
    /// that all four columns produce genuinely different orders and one pair
    /// ties on every column but name.
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            // Sizes several blocks apart, so the order is the sizes' doing and
            // not the host volume's block size — except for the deliberate
            // one-block tie between bravo and charlie.
            let wide = try makeDirectory("wide", in: root)
            try writeFile("delta.bin", bytes: 30_000, in: wide)
            try writeFile("alpha.bin", bytes: 90_000, in: wide)
            try writeFile("charlie.bin", bytes: 1, in: wide)
            try writeFile("bravo.bin", bytes: 1, in: wide)
            _ = try makeDirectory("echo", in: wide)

            let other = try makeDirectory("other", in: root)
            try writeFile("one.bin", bytes: 1_000, in: other)
            try writeFile("two.bin", bytes: 50_000, in: other)
        }
    }

    private func childNames(
        _ tree: DirectoryTreeViewController,
        of node: ScanNode
    ) -> [String] {
        let outline = tree.outlineView
        return (0..<tree.outlineView(outline, numberOfChildrenOfItem: node)).map {
            (tree.outlineView(outline, child: $0, ofItem: node) as? ScanNode)?.name ?? "?"
        }
    }

    private func sort(_ tree: DirectoryTreeViewController, by column: TreeColumn, ascending: Bool) {
        tree.outlineView.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
    }

    // MARK: - How often anything is sorted

    func test_repeatedChildQueriesForOneNodeSortItOnce() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let wide = try fixture.node(named: "wide")

        let before = tree.childOrder.misses
        for _ in 0..<3 { _ = childNames(tree, of: wide) }

        XCTAssertEqual(
            tree.childOrder.misses - before, 1,
            "fifteen child queries for one directory must cost one sort, not fifteen"
        )
    }

    func test_theChildCountQuerySortsNothing() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let wide = try fixture.node(named: "wide")

        let before = tree.childOrder.misses
        let count = tree.outlineView(tree.outlineView, numberOfChildrenOfItem: wide)

        XCTAssertEqual(count, wide.children.count)
        XCTAssertEqual(tree.childOrder.misses, before,
                       "how many children a node has does not depend on their order")
    }

    func test_eachDirectoryGetsItsOwnEntry() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController

        let before = tree.childOrder.misses
        _ = childNames(tree, of: try fixture.node(named: "wide"))
        _ = childNames(tree, of: try fixture.node(named: "other"))
        _ = childNames(tree, of: try fixture.node(named: "wide"))

        XCTAssertEqual(tree.childOrder.misses - before, 2,
                       "two directories, two sorts, and no third for the repeat")
    }

    // MARK: - Invalidation

    func test_changingDirectionInvalidatesEveryEntry() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        // Two children, distinct sizes: the mirror is exact, with no tie to
        // hold its own direction against the flip.
        let other = try fixture.node(named: "other")

        sort(tree, by: .size, ascending: false)
        XCTAssertEqual(childNames(tree, of: other), ["two.bin", "one.bin"])
        let afterFirst = tree.childOrder.misses

        sort(tree, by: .size, ascending: true)
        XCTAssertEqual(childNames(tree, of: other), ["one.bin", "two.bin"])

        XCTAssertGreaterThan(tree.childOrder.misses, afterFirst, "the old order cannot be reused")
    }

    func test_changingColumnInvalidatesEveryEntry() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let wide = try fixture.node(named: "wide")

        sort(tree, by: .size, ascending: false)
        _ = childNames(tree, of: wide)
        let afterSize = tree.childOrder.misses

        sort(tree, by: .name, ascending: true)
        _ = childNames(tree, of: wide)

        XCTAssertGreaterThan(tree.childOrder.misses, afterSize)
    }

    func test_changingRootReleasesEveryEntry() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController

        _ = childNames(tree, of: try fixture.node(named: "wide"))
        XCTAssertGreaterThan(tree.childOrder.entryCount, 0)

        tree.setRoot(nil)

        XCTAssertEqual(tree.childOrder.entryCount, 0,
                       "no cached array may outlive the tree it was sorted from")
    }

    // MARK: - The orders themselves

    /// Memoising an order is only safe if it is the same order. All four
    /// columns, both directions, spelled out.
    func test_allFourColumnsReturnTheExpectedOrderInBothDirections() async throws {
        let fixture = try await makeFixture()
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let wide = try fixture.node(named: "wide")

        // alpha 90,000 · delta 30,000 · bravo and charlie one block each · echo
        // nothing. The tied pair keeps name order in **both** directions, which
        // is why descending is not simply ascending reversed.
        sort(tree, by: .size, ascending: false)
        XCTAssertEqual(childNames(tree, of: wide),
                       ["alpha.bin", "delta.bin", "bravo.bin", "charlie.bin", "echo"])
        sort(tree, by: .size, ascending: true)
        XCTAssertEqual(childNames(tree, of: wide),
                       ["echo", "bravo.bin", "charlie.bin", "delta.bin", "alpha.bin"])

        // Percent is size over a constant denominator: the same order.
        sort(tree, by: .percent, ascending: false)
        XCTAssertEqual(childNames(tree, of: wide),
                       ["alpha.bin", "delta.bin", "bravo.bin", "charlie.bin", "echo"])

        sort(tree, by: .name, ascending: true)
        XCTAssertEqual(childNames(tree, of: wide),
                       ["alpha.bin", "bravo.bin", "charlie.bin", "delta.bin", "echo"])
        sort(tree, by: .name, ascending: false)
        XCTAssertEqual(childNames(tree, of: wide),
                       ["echo", "delta.bin", "charlie.bin", "bravo.bin", "alpha.bin"])

        // Only `echo` is directory-like, and it is empty; every file counts 0.
        sort(tree, by: .items, ascending: true)
        XCTAssertEqual(childNames(tree, of: wide),
                       ["alpha.bin", "bravo.bin", "charlie.bin", "delta.bin", "echo"])
    }

    /// Ties fall back to `NameOrder.precedes`, not to `String <` or a localized
    /// comparison — the same rule the treemap orders siblings by, so a row and
    /// the rectangle it selects can never disagree about which came first.
    func test_equalValuesTieBreakOnNameOrderExactly() async throws {
        // Three names whose code-point order — the engine's — is the reverse of
        // what a localized, case-insensitive comparison would give: `M` (77) and
        // `Z` (90) precede `a` (97), where a localized sort would file `apple`
        // first. Distinct on a case-insensitive volume too, which two spellings
        // of one accented name would not be.
        let fixture = try await ScannedFixture.make(in: self) { root in
            let folder = try makeDirectory("folder", in: root)
            try writeFile("apple.bin", bytes: 1, in: folder)
            try writeFile("Zebra.bin", bytes: 1, in: folder)
            try writeFile("Mango.bin", bytes: 1, in: folder)
        }
        let (workspace, _, _) = fixture.makeWorkspace()
        let tree = workspace.treeViewController
        let folder = try fixture.node(named: "folder")

        // Every file occupies exactly one block, so Size is a three-way tie and
        // the order is entirely the tie-break's doing.
        sort(tree, by: .size, ascending: false)
        XCTAssertEqual(childNames(tree, of: folder), ["Mango.bin", "Zebra.bin", "apple.bin"])
        XCTAssertEqual(childNames(tree, of: folder),
                       folder.children.map(\.name).sorted(by: NameOrder.precedes))

        // And the tie-break does not flip with the direction.
        sort(tree, by: .size, ascending: true)
        XCTAssertEqual(childNames(tree, of: folder), ["Mango.bin", "Zebra.bin", "apple.bin"])
    }
}
