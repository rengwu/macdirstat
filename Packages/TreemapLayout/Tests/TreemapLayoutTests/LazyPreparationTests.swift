import XCTest
@testable import TreemapLayout

/// §6.2's cost promise, made checkable: **relayout is bounded by the boxes on
/// screen, not by the tree.**
///
/// It used to be false. The engine built a parallel tree of class instances
/// over every positive-byte node before placing anything, so a directory that
/// folded into a 3 pt aggregate still cost a full walk of everything inside it
/// — 2.27 s at the Large rung, on the main thread, on every snapshot
/// (ticket 14). These tests hold the seam and count what the layout asks it,
/// because "bounded by rendered boxes" is a claim about questions asked, and
/// nothing else can see them.
final class LazyPreparationTests: XCTestCase {
    // MARK: - An instrumented tree

    /// What the layout asked the seam.
    final class SeamReads {
        var childListings = 0
        var itemCounts = 0
        var childrenListed: Set<String> = []
        var itemCountsAsked: [String] = []
    }

    /// A conformer that records its reads and answers
    /// `treemapPresentedItemCount` in constant time — the shape the scan
    /// engine's adapter has, and the one the bound depends on.
    final class Instrumented {
        let name: String
        let kind: TreemapEntryKind
        let bytes: Int64
        let children: [Instrumented]
        /// This entry plus every positive-byte entry beneath it, computed once
        /// at construction the way `ScanCore` rolls it up during the scan.
        let itemCount: Int

        init(_ name: String, bytes: Int64) {
            self.name = name
            self.kind = .file
            self.bytes = bytes
            self.children = []
            self.itemCount = bytes > 0 ? 1 : 0
        }

        init(directory name: String, _ children: [Instrumented]) {
            self.name = name
            self.kind = .directory
            self.bytes = children.reduce(0) { $0 + $1.bytes }
            self.children = children
            let below = children.reduce(0) { $0 + $1.itemCount }
            self.itemCount = below > 0 ? below + 1 : 0
        }
    }

    struct Node: TreemapInputNode {
        let entry: Instrumented
        let reads: SeamReads

        var treemapName: String { entry.name }
        var treemapKind: TreemapEntryKind { entry.kind }
        var treemapReadState: TreemapReadState { .complete }
        var treemapAttributedBytes: Int64 { entry.bytes }

        var treemapPresentedChildren: [Node] {
            reads.childListings += 1
            reads.childrenListed.insert(entry.name)
            return entry.children.map { Node(entry: $0, reads: reads) }
        }

        var treemapPresentedItemCount: Int {
            reads.itemCounts += 1
            reads.itemCountsAsked.append(entry.name)
            return entry.itemCount
        }
    }

    /// One dominant file beside a directory of tiny ones whose *combined* total
    /// is still far below 2×2 pt at any sane viewport. The directory therefore
    /// folds whole — and everything inside it is exactly the work that must not
    /// be done.
    private func hugeFileBesideACrowdedDirectory(crowd: Int = 10_000) -> Instrumented {
        var tiny: [Instrumented] = []
        for index in 0..<crowd {
            tiny.append(Instrumented(String(format: "tiny-%05d.dat", index), bytes: 1))
        }
        return Instrumented(directory: "root", [
            Instrumented("huge.iso", bytes: 400 * 1_073_741_824),
            Instrumented(directory: "crowd", tiny),
        ])
    }

    // MARK: - The bound

    func test_aFoldedSubtreeIsNeverListed() {
        let reads = SeamReads()
        let tree = hugeFileBesideACrowdedDirectory()
        let root = Node(entry: tree, reads: reads)

        let result = TreemapLayout.layout(tree: root, viewport: TreemapSize(width: 1_440, height: 900))

        // Two boxes are drawn: the dominant file and the aggregate standing for
        // the directory. The directory itself is never opened.
        XCTAssertEqual(result.statistics.visibleBoxCount, 2)
        XCTAssertEqual(result.statistics.aggregateBoxCount, 1)
        XCTAssertFalse(
            reads.childrenListed.contains("crowd"),
            "the layout listed a directory it had already folded away"
        )
        XCTAssertEqual(
            reads.childListings, 2,
            "one listing per box with a rectangle — the root and the surviving file, and nothing else"
        )
        XCTAssertEqual(reads.childrenListed, ["root", "huge.iso"])
        XCTAssertEqual(result.statistics.preparedChildCount, 2, "two children read, out of 10,002 entries")
        XCTAssertEqual(result.statistics.visitedDirectoryCount, 1)

        // And it is still exact about what it hid: the directory and every one
        // of the ten thousand files inside it.
        XCTAssertEqual(result.statistics.mergedItemCount, 10_001)
        XCTAssertEqual(result.statistics.placedNodeCount, 10_003, "the root, the file, the directory, the crowd")
    }

    /// The number that used to be the whole cost. `preparedChildCount` is the
    /// entries the layout read; it must scale with the viewport, not with the
    /// tree — so a tree ten times larger at the same viewport must not cost ten
    /// times the reads.
    func test_readsScaleWithTheViewportAndNotWithTheTree() {
        let viewport = TreemapSize(width: 1_440, height: 900)

        func reads(crowd: Int) -> (prepared: Int, placed: Int) {
            let seam = SeamReads()
            let result = TreemapLayout.layout(
                tree: Node(entry: hugeFileBesideACrowdedDirectory(crowd: crowd), reads: seam),
                viewport: viewport
            )
            return (result.statistics.preparedChildCount, result.statistics.placedNodeCount)
        }

        let small = reads(crowd: 1_000)
        let large = reads(crowd: 100_000)

        XCTAssertEqual(large.placed, small.placed + 99_000, "the trees really do differ by a hundredfold")
        XCTAssertEqual(large.prepared, small.prepared, "a hundred times the tree cost the same reads")
        XCTAssertLessThan(large.prepared, large.placed / 1_000)
    }

    /// Every folded child is asked for its item count **once**, not once per
    /// merge round — which matters because for a conformer without a maintained
    /// count that question is a subtree walk, and the fixpoint runs up to eight
    /// rounds.
    func test_eachFoldedChildIsAskedForItsItemCountExactlyOnce() {
        let reads = SeamReads()
        var children: [Instrumented] = [Instrumented("bulk.bin", bytes: 10_000_000)]
        for index in 0..<400 {
            children.append(Instrumented(String(format: "tail-%03d.log", index), bytes: 500))
        }
        let root = Node(entry: Instrumented(directory: "root", children), reads: reads)

        let result = TreemapLayout.layout(tree: root, viewport: TreemapSize(width: 300, height: 200))

        XCTAssertGreaterThan(result.statistics.maximumMergeRounds, 1, "this shape must actually iterate")
        let asked = reads.itemCountsAsked.filter { $0 != "root" }
        XCTAssertEqual(asked.count, Set(asked).count, "a folded child was asked for its item count twice")
        XCTAssertEqual(asked.count, result.statistics.mergedItemCount, "these children are all leaves")
    }

    /// The invariant ticket 06 settled, now that neither side is computed by
    /// the same walk: individually drawn entries plus merged item counts equals
    /// every positive-byte entry in the tree.
    func test_drawnPlusFoldedStillAccountsForEveryEntry() {
        for viewport in [
            TreemapSize(width: 2_560, height: 1_600),
            TreemapSize(width: 520, height: 390),
            TreemapSize(width: 60, height: 40),
        ] {
            let reads = SeamReads()
            let root = Node(entry: hugeFileBesideACrowdedDirectory(crowd: 2_000), reads: reads)
            let result = TreemapLayout.layout(tree: root, viewport: viewport)

            let drawn = result.filledBoxes.filter { !$0.isAggregate }.count
            XCTAssertEqual(
                drawn + result.statistics.mergedItemCount,
                result.statistics.placedNodeCount - 1,
                "at \(Int(viewport.width))×\(Int(viewport.height)): the root is subdivided, not drawn"
            )
            XCTAssertLessThanOrEqual(result.statistics.preparedChildCount, result.statistics.placedNodeCount)
        }
    }

    // MARK: - The seam's default

    /// The protocol's own implementation, for conformers that cannot maintain a
    /// count — fixtures, previews, anything holding a plain value tree. It is
    /// O(subtree) and that is the cost the seam exists to let a real conformer
    /// avoid; what it must not be is *wrong*.
    func test_theDefaultItemCountAgreesWithAMaintainedOne() {
        let tree = hugeFileBesideACrowdedDirectory(crowd: 50)
        let maintained = tree.itemCount

        let plain = TreemapTree(directory: "root", children: [
            TreemapTree(name: "huge.iso", bytes: 40 * 1_073_741_824),
            TreemapTree(directory: "crowd", children: (0..<50).map {
                TreemapTree(name: String(format: "tiny-%05d.dat", $0), bytes: 4_096)
            }),
        ])

        XCTAssertEqual(plain.treemapPresentedItemCount, maintained)
        XCTAssertEqual(plain.treemapPresentedItemCount, 53, "root, huge.iso, crowd and fifty files")
    }

    func test_theDefaultItemCountSkipsZeroByteEntriesAndCollapsedPackages() {
        let withZeroes = TreemapTree(directory: "root", children: [
            TreemapTree(name: "real.bin", bytes: 4_096),
            TreemapTree(name: "empty.txt", bytes: 0),
            TreemapTree(name: "link", bytes: 0, kind: .symbolicLink),
            TreemapTree(directory: "hollow", children: [TreemapTree(name: "nothing", bytes: 0)]),
        ])
        XCTAssertEqual(withZeroes.treemapPresentedItemCount, 2, "the root and the one entry with bytes")

        // A collapsed package presents no children, so it is one entry — what
        // it holds is not on the map to be folded (spec §3.4).
        let collapsed = TreemapTree(collapsedPackage: "Thing.app", bytes: 12_000_000)
        XCTAssertEqual(collapsed.treemapPresentedItemCount, 1)
        XCTAssertEqual(TreemapTree(name: "gone", bytes: 0).treemapPresentedItemCount, 0)
    }

    /// The default must not be bounded by the stack any more than the walk is.
    func test_theDefaultItemCountSurvivesAChainDeeperThanTheStack() {
        var chain = TreemapTree(name: "leaf.bin", bytes: 4_096)
        for level in 0..<5_000 {
            chain = TreemapTree(directory: "level-\(level)", children: [chain])
        }
        XCTAssertEqual(chain.treemapPresentedItemCount, 5_001)
    }
}
