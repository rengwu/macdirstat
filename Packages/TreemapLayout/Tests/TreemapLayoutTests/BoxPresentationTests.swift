import XCTest
@testable import TreemapLayout

/// What a box tells the view about itself (spec §6.3, with the thresholds and
/// the outline cap fixed by ticket 01). The drawing is ticket 09's; deciding
/// *which* box gets a fill, a label or an outline is geometry, so it is
/// answered here where it can be tested without a window.
final class BoxPresentationTests: XCTestCase {
    func test_onlyLeavesLargeEnoughToReadAreLabelled() {
        let tree = Fixture.directory("root", [
            Fixture.file("large.mov", 900),
            Fixture.file("narrow.mov", 100),
        ])
        // 1,000 pt² per byte-thousandth: "large" is 900×1000 pt, "narrow" is
        // 100×1000 — tall enough, nowhere near 48 pt wide.
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 1_000, height: 1_000))

        XCTAssertTrue(result.box(ofNodeNamed: "large.mov")!.fitsLabel)
        XCTAssertEqual(TreemapMetrics.labelMinimumSize, TreemapSize(width: 48, height: 15))
        XCTAssertEqual(TreemapMetrics.labelFontSizePoints, 11)

        let short = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 1_000, height: 14))
        XCTAssertFalse(short.box(ofNodeNamed: "large.mov")!.fitsLabel, "14 pt is below the 15 pt floor")

        let narrow = TreemapLayout.layout(tree: Fixture.directory("root", [
            Fixture.file("a.mov", 1), Fixture.file("b.mov", 1), Fixture.file("c.mov", 1),
        ]), viewport: TreemapSize(width: 40, height: 300))
        XCTAssertTrue(narrow.filledBoxes.allSatisfy { !$0.fitsLabel }, "40 pt is below the 48 pt floor")
    }

    func test_directoriesAndAggregatesCarryNoKindHue() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 800, height: 600))

        XCTAssertNil(result.box(ofNodeNamed: "Media")?.kindGroup, "a directory's area is its children's")
        XCTAssertNil(result.boxes.first { $0.isAggregate }?.kindGroup, "the merged box takes the neutral fill")
        XCTAssertEqual(result.box(ofNodeNamed: "holiday.mov")?.kindGroup, .video)
        XCTAssertEqual(result.box(ofNodeNamed: "podcast.m4a")?.kindGroup, .audio)
    }

    /// A collapsed package is one leaf box and takes its own extension's hue;
    /// expanded, it becomes a region with no fill of its own (§3.4, §6.3).
    func test_aCollapsedPackageIsColouredLikeTheLeafItIs() {
        let collapsed = TreemapLayout.layout(
            tree: Fixture.directory("root", [TreemapTree(collapsedPackage: "Xcode.app", bytes: 12 * Fixture.gib)]),
            viewport: TreemapSize(width: 400, height: 300)
        )
        XCTAssertEqual(collapsed.box(ofNodeNamed: "Xcode.app")?.kindGroup, .app)

        let expanded = TreemapLayout.layout(
            tree: Fixture.directory("root", [
                TreemapTree(directory: "Xcode.app", kind: .package, children: [Fixture.file("Contents", 12 * Fixture.gib)]),
            ]),
            viewport: TreemapSize(width: 400, height: 300)
        )
        XCTAssertNil(expanded.box(ofNodeNamed: "Xcode.app")?.kindGroup)
    }

    func test_incompleteReadStateReachesTheBoxThatWillBeHatched() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 800, height: 600))

        XCTAssertTrue(result.box(ofNodeNamed: "Library")?.isIncomplete == true)
        XCTAssertFalse(result.box(ofNodeNamed: "Media")?.isIncomplete == true)
        XCTAssertFalse(result.boxes.first { $0.isAggregate }?.isIncomplete == true,
                       "an aggregate stands for many entries and speaks for none of their states")
    }

    /// Ticket 01 capped §6.1's "every directory below the root" at three
    /// levels: on a deep chain the deeper strokes overdraw a strip the fills
    /// already bound.
    func test_outlinesStopThreeLevelsBelowTheRoot() {
        let result = TreemapLayout.layout(tree: Fixture.deepChain(depth: 20), viewport: TreemapSize(width: 900, height: 700))

        let depths = Set(result.outlinedBoxes.map { $0.depth })
        XCTAssertEqual(depths, [1, 2, 3], "20 nested directories should draw 3 outlines, not 20")
        XCTAssertFalse(result.outlinedBoxes.contains { !$0.isSubdivided }, "a leaf is not a directory region")
        XCTAssertEqual(TreemapMetrics.directoryOutlineMaximumDepth, 3)
        XCTAssertEqual(TreemapMetrics.directoryOutlineWidthPoints, 1)
    }

    func test_anOutlineIsSkippedWhereItWouldBePureOverdraw() {
        // A strip narrower than the stroke it would carry.
        let result = TreemapLayout.layout(tree: Fixture.deepChain(depth: 20), viewport: TreemapSize(width: 40, height: 30))
        XCTAssertTrue(result.outlinedBoxes.allSatisfy { $0.frame.shortestSide >= 2 })
    }

    func test_onlyFilledBoxesAreHitTestable() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 800, height: 600))

        for box in result.boxes {
            XCTAssertEqual(box.isHitTestable, !box.isSubdivided)
        }
        XCTAssertEqual(result.filledBoxes.count, result.statistics.visibleBoxCount)
    }
}
