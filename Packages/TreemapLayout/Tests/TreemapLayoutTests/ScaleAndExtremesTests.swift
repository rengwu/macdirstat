import XCTest
@testable import TreemapLayout

/// Spec §6.4 and §8.1's workload shapes: the distributions that break naive
/// treemaps — one dominant file, thousands of siblings, and chains deep enough
/// to degrade into strips — stay deterministic, bounded and crash-free.
final class ScaleAndExtremesTests: XCTestCase {
    private let viewport = TreemapSize(width: 520, height: 390)

    func test_fortyGibibytesBesideATinyTail() {
        let result = TreemapLayout.layout(tree: Fixture.extremeSkew, viewport: viewport)

        assertLayoutInvariants(result)
        assertNoSlivers(result)

        // 10⁴:1 skew and worse: the dominant file keeps a sane aspect ratio
        // rather than becoming a hairline.
        let huge = result.frame(ofNodeNamed: "huge.iso")!
        XCTAssertLessThan(max(huge.width / huge.height, huge.height / huge.width), 2)
        XCTAssertEqual(huge.area / viewport.area, 1.0, accuracy: 1e-3, "40 GiB is essentially the whole map")

        XCTAssertEqual(result.statistics.aggregateBoxCount, 1)
        XCTAssertEqual(result.statistics.mergedItemCount + result.filledBoxes.count - 1, 41)
    }

    func test_twoAndAHalfThousandSiblings() {
        let result = TreemapLayout.layout(tree: Fixture.dense, viewport: viewport)

        assertLayoutInvariants(result)
        assertNoSlivers(result)

        // §6.2's bound: what is drawn is individual boxes plus one aggregate
        // per affected directory — never one box per entry.
        XCTAssertLessThanOrEqual(
            result.statistics.visibleBoxCount,
            result.statistics.placedNodeCount + result.statistics.aggregateBoxCount
        )
        XCTAssertEqual(result.statistics.aggregateBoxCount, 1, "one directory, one aggregate")
        XCTAssertLessThan(result.statistics.visibleBoxCount, 2_500, "nothing this dense fits at 520×390")

        // Every entry is still accounted for: drawn individually or folded.
        let drawn = result.filledBoxes.filter { !$0.isAggregate }.count
        XCTAssertEqual(drawn + result.statistics.mergedItemCount, 2_500)
    }

    func test_aSixtyFourLevelChain() {
        let result = TreemapLayout.layout(tree: Fixture.deepChain(depth: 64), viewport: TreemapSize(width: 1_200, height: 800))

        assertLayoutInvariants(result)
        XCTAssertEqual(result.boxes.map { $0.depth }.max(), 65, "64 directory levels, and the leaf inside the last one")
        XCTAssertFalse(result.statistics.reachedRoundCap)

        // Deep chains degrade into strips (§6.4): truthful, and every level
        // still tiles the one above it exactly.
        assertSiblingsFillTheirParent(result, tolerance: 1e-6)
    }

    func test_aDeeplyNestedChainDoesNotRecurseOnTheStack() {
        // Well past PATH_MAX's practical depth, and past the ~1,000-level ARC
        // teardown ceiling recorded on the map: the layout walk is iterative,
        // so its own bound is memory, not stack.
        let result = TreemapLayout.layout(tree: Fixture.deepChain(depth: 2_000), viewport: viewport)

        XCTAssertEqual(result.boxes.map { $0.depth }.max(), 2_001)
        XCTAssertEqual(result.statistics.coveredArea, viewport.area, accuracy: viewport.area * 1e-9)
    }

    func test_extremeShapesStayDeterministicAtEveryViewport() {
        let viewports = [
            TreemapSize(width: 320, height: 200),
            TreemapSize(width: 520, height: 390),
            TreemapSize(width: 1_440, height: 900),
            TreemapSize(width: 2_560, height: 1_600),
        ]
        for fixture in [Fixture.extremeSkew, Fixture.dense, Fixture.deepChain(depth: 64)] {
            for viewport in viewports {
                let a = TreemapLayout.layout(tree: fixture, viewport: viewport)
                let b = TreemapLayout.layout(tree: fixture, viewport: viewport)
                XCTAssertEqual(a.frames, b.frames)
                XCTAssertEqual(a.statistics, b.statistics)
            }
        }
    }

    /// The fixpoint's cost, not just its result: ticket 01 measured ≤81
    /// squarify passes for a whole tree. A regression that made it quadratic
    /// would show up here long before it showed up as a dropped frame.
    func test_theFixpointSettlesInAFewPasses() {
        for (name, fixture) in [("realistic", Fixture.realistic), ("dense", Fixture.dense), ("skew", Fixture.extremeSkew)] {
            let result = TreemapLayout.layout(tree: fixture, viewport: viewport)
            XCTAssertLessThanOrEqual(result.statistics.maximumMergeRounds, 5, "\(name) needed too many rounds")
            XCTAssertLessThanOrEqual(
                result.statistics.squarifyPasses,
                result.statistics.subdividedBoxCount * TreemapMetrics.mergeRoundCap,
                "\(name) squarified more often than the round cap allows"
            )
        }
    }

    func test_aSingleFileRootFillsTheViewport() {
        let result = TreemapLayout.layout(tree: Fixture.file("only.bin", 4_096), viewport: viewport)

        XCTAssertEqual(result.boxes.count, 1)
        XCTAssertFalse(result.boxes[0].isSubdivided)
        XCTAssertEqual(result.boxes[0].frame, TreemapRect(x: 0, y: 0, width: 520, height: 390))
        XCTAssertEqual(result.node(at: TreemapPoint(x: 1, y: 1))?.treemapName, "only.bin")
    }

    func test_aViewportSmallerThanTheMergeThresholdIsStillTruthful() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 1.5, height: 1.5))

        assertLayoutInvariants(result)
        XCTAssertEqual(result.statistics.coveredArea, 2.25, accuracy: 1e-9)
        XCTAssertEqual(result.filledBoxes.count, 1, "nothing resolves, so one aggregate stands for everything")
        XCTAssertTrue(result.filledBoxes[0].isAggregate)
    }
}
