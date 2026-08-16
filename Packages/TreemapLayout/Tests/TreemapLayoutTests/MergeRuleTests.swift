import XCTest
@testable import TreemapLayout

/// Spec §6.2 as reconciled in §11.1 and closed by ticket 01: *merge, never
/// disappear*. Everything below 2×2 pt in a directory folds into exactly one
/// aggregate box for that directory, the fold iterates to a fixpoint, and the
/// visible area still accounts for 100% of the bytes.
final class MergeRuleTests: XCTestCase {
    private let square = TreemapSize(width: 100, height: 100)

    // MARK: - Golden

    /// 9,990 bytes beside 5 + 3 + 2 in a 100×100 viewport. The tail lands as
    /// 0.1 pt strips on the first pass; folding them and re-packing leaves the
    /// survivor at 99.9 pt and the aggregate holding the last 0.1 pt column —
    /// so the merge box is exactly the ten bytes it stands for.
    func test_goldenGeometryForASingleMerge() {
        let result = TreemapLayout.layout(tree: Fixture.dominantPlusTail, viewport: square)

        XCTAssertEqual(result.boxes.count, 3, "root region, the survivor, one aggregate")
        assertRectEqual(result.frame(ofNodeNamed: "big.bin")!, TreemapRect(x: 0, y: 0, width: 99.9, height: 100))

        guard let aggregateBox = result.boxes.first(where: { $0.isAggregate }) else {
            return XCTFail("the tail should have merged")
        }
        assertRectEqual(aggregateBox.frame, TreemapRect(x: 99.9, y: 0, width: 0.1, height: 100), accuracy: 1e-9)
        XCTAssertEqual(aggregateBox.aggregate?.bytes, 10, "the aggregate reports the exact sum, never a rounded one")
        XCTAssertEqual(aggregateBox.aggregate?.itemCount, 3)
        XCTAssertEqual(aggregateBox.aggregate?.mergedRoots.map { $0.treemapName }, ["b.bin", "c.bin", "d.bin"])
        XCTAssertEqual(result.statistics.maximumMergeRounds, 2, "one pass to discover the slivers, one to settle")

        assertLayoutInvariants(result)
        assertNoSlivers(result)
    }

    func test_theAggregateIsPinnedLastInChildOrder() {
        // A halving ladder, so the packing stays squarish all the way down and
        // "small.bin" is genuinely drawable. The 200 slivers combine to 1,400
        // bytes — nearly three times "small.bin" — so sorting the aggregate by
        // its combined bytes would place it before that child. Ticket 01 pins
        // it last regardless, which is what settles the packing in two rounds
        // instead of five.
        var children = (1...11).map { Fixture.file("ladder-\(String(format: "%02d", $0)).bin", Int64(4_096_000) >> $0) }
        children.append(Fixture.file("small.bin", 500))
        children += (0..<200).map { Fixture.file("t-\(String(format: "%03d", $0)).bin", 7) }
        let result = TreemapLayout.layout(tree: Fixture.directory("root", children), viewport: TreemapSize(width: 1_200, height: 900))

        let order = result.boxes.dropFirst().map { $0.isAggregate ? "<aggregate>" : ($0.node?.treemapName ?? "?") }
        XCTAssertEqual(Array(order.suffix(2)), ["small.bin", "<aggregate>"])
        XCTAssertEqual(result.aggregates.first?.bytes, 200 * 7)
        XCTAssertGreaterThan(result.aggregates.first?.bytes ?? 0, 500, "its bytes would have sorted it earlier")
        assertNoSlivers(result)
    }

    // MARK: - The rule itself

    func test_everySurvivorClearsTwoPointsAtEveryViewportAndBackingScale() {
        let viewports = [
            TreemapSize(width: 520, height: 390),
            TreemapSize(width: 1_440, height: 900),
            TreemapSize(width: 320, height: 200),
            TreemapSize(width: 97, height: 611),
            TreemapSize(width: 60, height: 40),
        ]
        for fixture in [Fixture.realistic, Fixture.extremeSkew, Fixture.dense, Fixture.deepChain(depth: 20)] {
            for viewport in viewports {
                let result = TreemapLayout.layout(tree: fixture, viewport: viewport)
                assertNoSlivers(result)
                assertLayoutInvariants(result)

                // Backing scale is a draw-time concern: snapping must not
                // reintroduce a sliver the layout removed.
                for scale in [1.0, 2.0, 3.0] {
                    for box in result.filledBoxes where !box.isAggregate {
                        let snapped = box.frame.snapped(toBackingScale: scale)
                        XCTAssertGreaterThan(snapped.width, 0, "a survivor vanished at backing scale \(scale)")
                        XCTAssertGreaterThan(snapped.height, 0, "a survivor vanished at backing scale \(scale)")
                    }
                }
            }
        }
    }

    func test_visibleAreaAccountsForEveryNonzeroByte() {
        let viewport = TreemapSize(width: 640, height: 480)
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: viewport)

        // Area truthfulness restated as bytes: what the individual boxes stand
        // for, plus what the aggregates stand for, is the whole tree.
        var accounted: Int64 = 0
        for box in result.filledBoxes { accounted += box.bytes }
        XCTAssertEqual(accounted, Fixture.realistic.bytes, "bytes fell off the map")
        XCTAssertEqual(result.statistics.coveredArea, viewport.area, accuracy: viewport.area * 1e-9)
    }

    /// The trigger applies to a whole subtree, not just to leaves: a directory
    /// that is collectively too small folds as one, and its descendants do not
    /// appear anywhere.
    func test_aCollectivelyTinySubtreeFoldsAsOneItem() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 400, height: 300))

        XCTAssertNil(result.box(ofNodeNamed: "dust"), "the whole directory should have folded")
        XCTAssertNil(result.box(ofNodeNamed: "speck-0.dat"), "and nothing inside it may be drawn on its own")

        let holder = result.aggregates.first { $0.mergedRoots.contains { $0.treemapName == "dust" } }
        XCTAssertNotNil(holder, "the dust directory is missing from every aggregate")
        // The directory itself plus its twelve specks.
        XCTAssertGreaterThanOrEqual(holder?.itemCount ?? 0, 13)
    }

    func test_theAggregateCountsFoldedEntriesRecursively() {
        let tree = Fixture.directory("root", [
            Fixture.file("big.bin", 100_000_000),
            Fixture.directory("tiny", [
                Fixture.file("a", 3),
                Fixture.directory("deeper", [Fixture.file("b", 2), Fixture.file("c", 1)]),
            ]),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 300, height: 300))

        guard let aggregate = result.aggregates.first else { return XCTFail("expected a merge") }
        XCTAssertEqual(aggregate.bytes, 6)
        // tiny + a + deeper + b + c
        XCTAssertEqual(aggregate.itemCount, 5)
        XCTAssertEqual(aggregate.mergedRoots.map { $0.treemapName }, ["tiny"], "one root, not five")
    }

    /// The fold is per directory, so two directories that each have a tail get
    /// one aggregate each — never a shared one, and never two in the same
    /// directory.
    func test_eachDirectoryGetsItsOwnSingleAggregate() {
        func branch(_ name: String) -> TreemapTree {
            Fixture.directory(name, [Fixture.file("\(name)-big.bin", 50_000_000)]
                + (0..<80).map { Fixture.file("\(name)-t\($0).bin", 500) })
        }
        let tree = Fixture.directory("root", [branch("left"), branch("right")])
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 500, height: 400))

        XCTAssertEqual(result.statistics.aggregateBoxCount, 2)
        let parents = Set(result.boxes.filter { $0.isAggregate }.compactMap { $0.parentIndex })
        XCTAssertEqual(parents.count, 2)
        for box in result.boxes where box.isAggregate {
            let parentName = result.boxes[box.parentIndex!].node?.treemapName
            XCTAssertTrue(parentName == "left" || parentName == "right")
            XCTAssertEqual(box.aggregate?.bytes, 80 * 500)
            XCTAssertEqual(box.aggregate?.itemCount, 80)
        }
        assertLayoutInvariants(result)
        assertNoSlivers(result)
    }

    /// A rectangle too small to resolve anything at all is still truthful: the
    /// aggregate takes the whole of it rather than the directory going blank.
    func test_aDirectoryTooSmallToResolveBecomesOneAggregate() {
        // "crumbs" is comfortably drawable itself — a 14 pt column — but each
        // of its 4,000 children would be under 2.5 pt², so nothing inside it
        // can resolve.
        let tree = Fixture.directory("root", [
            Fixture.file("dominant.bin", 251_000),
            Fixture.directory("crumbs", (0..<4_000).map { Fixture.file("c\($0).bin", 1) }),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 900, height: 700))

        guard let index = result.index(ofNodeNamed: "crumbs") else { return XCTFail("crumbs itself merged away") }
        let inside = result.childBoxes(of: index)
        XCTAssertEqual(inside.count, 1, "a rectangle this small resolves to exactly one aggregate")
        XCTAssertEqual(inside.first?.aggregate?.itemCount, 4_000)
        XCTAssertEqual(inside.first?.aggregate?.bytes, 4_000)
        assertRectEqual(inside[0].frame, result.boxes[index].frame,
                        "the aggregate should take the whole directory rather than leave it blank")
        assertLayoutInvariants(result)
        assertNoSlivers(result)
    }

    /// Merging repacks the survivors, which can push a previously-safe child
    /// below the threshold — the reason ticket 01 chose the fixpoint over a
    /// single corrective pass.
    func test_theFoldIteratesUntilNothingIsASliver() {
        let result = TreemapLayout.layout(tree: Fixture.dense, viewport: TreemapSize(width: 520, height: 390))

        assertNoSlivers(result)
        XCTAssertGreaterThan(result.statistics.maximumMergeRounds, 1, "this fixture needs more than one pass")
        XCTAssertLessThanOrEqual(result.statistics.maximumMergeRounds, TreemapMetrics.mergeRoundCap)
        XCTAssertFalse(result.statistics.reachedRoundCap)
    }

    func test_nothingIsMergedWhenEverythingFits() {
        let result = TreemapLayout.layout(tree: Fixture.handComputable, viewport: TreemapSize(width: 800, height: 600))

        XCTAssertEqual(result.statistics.aggregateBoxCount, 0)
        XCTAssertEqual(result.statistics.mergedBytes, 0)
        XCTAssertEqual(result.statistics.maximumMergeRounds, 1)
        XCTAssertEqual(result.statistics.squarifyPasses, 1)
    }

    /// Shrinking the viewport may only ever fold more, never fewer, bytes —
    /// which is the invariant that keeps a divider drag from flickering
    /// individual boxes in and out for no reason.
    func test_mergingIsMonotonicAsTheViewportShrinks() {
        var previous: Int64 = -1
        for side in stride(from: 1_200.0, through: 60.0, by: -60.0) {
            let result = TreemapLayout.layout(tree: Fixture.dense, viewport: TreemapSize(width: side, height: side * 0.75))
            XCTAssertGreaterThanOrEqual(result.statistics.mergedBytes, previous, "shrinking un-merged something at \(side)")
            previous = result.statistics.mergedBytes
        }
    }
}
