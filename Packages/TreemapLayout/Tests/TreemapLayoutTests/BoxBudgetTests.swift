import XCTest
@testable import TreemapLayout

/// §6 with a ceiling on it (ticket 17): what a ``TreemapLayoutBudget`` may
/// change about a map, and what it may not.
///
/// The bar these hold is that a budget only ever changes *how much* is
/// resolved. Area truthfulness, containment, one aggregate per directory and
/// determinism are the same promises at any cap, and `assertLayoutInvariants`
/// is the same assertion here as everywhere else in the suite.
final class BoxBudgetTests: XCTestCase {
    /// A tree wide enough that a cap has something to bite: 6 × 6 × 6
    /// directories of 24 log-uniform files, all of them positive bytes.
    private var wide: TreemapTree {
        var generator = SeededGenerator(seed: 0xB0DE7)
        func level(_ depth: Int, _ index: Int) -> TreemapTree {
            guard depth > 0 else {
                let files = (0..<24).map { ordinal in
                    Fixture.file(
                        String(format: "f-%d-%02d.dat", index, ordinal),
                        generator.logUniform(4 * 1024, 512 * 1024 * 1024)
                    )
                }
                return Fixture.directory("leaf-\(index)", files)
            }
            return Fixture.directory(
                "dir-\(depth)-\(index)",
                (0..<6).map { level(depth - 1, index * 6 + $0) }
            )
        }
        return level(3, 0)
    }

    private let large = TreemapSize(width: 3_840, height: 2_160)

    // MARK: - What a budget must not change

    func testABudgetThatCannotBindLeavesTheMapAlone() throws {
        let viewport = TreemapSize(width: 1_200, height: 900)
        let unbudgeted = TreemapLayout.layout(tree: Fixture.realistic, viewport: viewport)
        let budgeted = TreemapLayout.layout(
            tree: Fixture.realistic, viewport: viewport, budget: .boxes(100_000)
        )

        assertLayoutInvariants(unbudgeted)
        assertLayoutInvariants(budgeted)
        XCTAssertFalse(budgeted.statistics.reachedBoxBudget)
        XCTAssertEqual(budgeted.statistics.budgetFoldedChildCount, 0)
        XCTAssertEqual(
            budgeted.statistics.visibleBoxCount, unbudgeted.statistics.visibleBoxCount
        )
        // Same rectangles for the same nodes. Only their order in the draw list
        // differs, because a budgeted walk goes largest-first.
        XCTAssertEqual(
            Set(budgeted.boxes.map { Placement(box: $0) }),
            Set(unbudgeted.boxes.map { Placement(box: $0) })
        )
    }

    func testTheSameBudgetTwiceIsTheSameMap() {
        let first = TreemapLayout.layout(tree: wide, viewport: large, budget: .boxes(400))
        let second = TreemapLayout.layout(tree: wide, viewport: large, budget: .boxes(400))
        XCTAssertEqual(first.boxes.map(\.frame), second.boxes.map(\.frame))
        XCTAssertEqual(first.boxes.map(\.depth), second.boxes.map(\.depth))
    }

    // MARK: - What a budget does

    func testATightBudgetBoundsTheBoxesAndStillTilesTheViewport() {
        let capped = TreemapLayout.layout(tree: wide, viewport: large, budget: .boxes(400))

        assertLayoutInvariants(capped)
        XCTAssertTrue(capped.statistics.reachedBoxBudget)
        XCTAssertGreaterThan(capped.statistics.unopenedBoxCount, 0)
        // The directory that exhausts the budget is finished rather than
        // abandoned, so the cap is a bound on work and not an equality.
        XCTAssertLessThanOrEqual(capped.statistics.visibleBoxCount, 800)
        XCTAssertGreaterThan(capped.statistics.visibleBoxCount, 100)

        let uncapped = TreemapLayout.layout(tree: wide, viewport: large)
        XCTAssertGreaterThan(uncapped.statistics.visibleBoxCount, 1_500)
    }

    func testABudgetedWalkReadsFarLessOfTheTree() {
        let capped = TreemapLayout.layout(tree: wide, viewport: large, budget: .boxes(400))
        // The cost that matters is the children read, not the nodes that exist:
        // a region left unopened is never asked for its contents.
        XCTAssertLessThan(
            capped.statistics.preparedChildCount, capped.statistics.placedNodeCount / 3
        )
        XCTAssertLessThan(capped.statistics.visitedDirectoryCount, 400)
    }

    func testNothingIsDroppedToMeetTheBudget() throws {
        let capped = TreemapLayout.layout(tree: wide, viewport: large, budget: .boxes(400))
        let root = try XCTUnwrap(capped.boxes.first)

        // Every byte in the tree is still on screen: the filled boxes tile the
        // viewport, and their bytes add back up to the root's.
        let drawn = capped.filledBoxes.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(drawn, root.bytes)
        XCTAssertGreaterThan(capped.statistics.budgetFoldedChildCount, 0)
        // What folded reports itself honestly, as any §6.2 fold must.
        XCTAssertGreaterThan(capped.statistics.mergedItemCount, 0)
        XCTAssertGreaterThan(capped.statistics.mergedBytes, 0)
    }

    func testAnAllowanceNeverFallsBelowOneBox() {
        // A region rounding to nothing must still be allowed to resolve, or a
        // deep tree would fold away at the first level that rounds to zero.
        let budget = TreemapLayoutBudget.boxes(10)
        let sliver = TreemapRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(budget.allowance(forRect: sliver, viewportArea: large.area), 1)
        XCTAssertEqual(
            budget.allowance(forRect: TreemapRect(origin: .init(x: 0, y: 0), size: large),
                             viewportArea: large.area),
            10
        )
        XCTAssertNil(
            TreemapLayoutBudget.unbounded.allowance(forRect: sliver, viewportArea: large.area)
        )
    }

    /// A box's identity for comparing two draw lists that may be in different
    /// order: what it stands for, where it landed, and how deep it sits.
    private struct Placement: Hashable {
        let name: String
        let isAggregate: Bool
        let frame: TreemapRect
        let depth: Int
        let bytes: Int64

        init(box: TreemapBox<TreemapTree>) {
            self.name = box.node?.treemapName ?? "«aggregate»"
            self.isAggregate = box.isAggregate
            self.frame = box.frame
            self.depth = box.depth
            self.bytes = box.bytes
        }
    }
}
