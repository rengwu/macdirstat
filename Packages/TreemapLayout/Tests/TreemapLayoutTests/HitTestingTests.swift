import XCTest
@testable import TreemapLayout

/// Spec §6.4: the deepest rendered node whose frame contains the point wins;
/// a merge box's interior returns the aggregate; zero-byte entries are not
/// reachable in the map at all.
final class HitTestingTests: XCTestCase {
    private let square = TreemapSize(width: 100, height: 100)

    func test_aPointReturnsTheLeafItLandsIn() {
        let result = TreemapLayout.layout(tree: Fixture.handComputable, viewport: square)

        XCTAssertEqual(result.node(at: TreemapPoint(x: 35, y: 10))?.treemapName, "a.bin")
        XCTAssertEqual(result.node(at: TreemapPoint(x: 35, y: 80))?.treemapName, "b.bin")
        XCTAssertEqual(result.node(at: TreemapPoint(x: 85, y: 10))?.treemapName, "c.bin")
        XCTAssertEqual(result.node(at: TreemapPoint(x: 85, y: 90))?.treemapName, "d.bin")
    }

    func test_aDirectoryRegionYieldsToTheChildThatCoversIt() {
        let tree = Fixture.directory("root", [
            Fixture.directory("left", [Fixture.file("a.bin", 4_000), Fixture.file("b.bin", 6_000)]),
            Fixture.file("right.bin", 10_000),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 200, height: 100))

        // Every point inside "left" belongs to one of its leaves, never to the
        // directory itself — directories are selected from the tree.
        for point in [TreemapPoint(x: 10, y: 10), TreemapPoint(x: 90, y: 90), TreemapPoint(x: 50, y: 50)] {
            let hit = result.box(at: point)
            XCTAssertNotNil(hit)
            XCTAssertFalse(hit!.isSubdivided)
            XCTAssertNotEqual(hit?.node?.treemapName, "left")
            XCTAssertNotEqual(hit?.node?.treemapName, "root")
        }
    }

    func test_everyPointOnAGridLandsOnExactlyOneBox() {
        let viewport = TreemapSize(width: 400, height: 300)
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: viewport)

        var misses = 0
        for x in stride(from: 0.5, to: viewport.width, by: 3.0) {
            for y in stride(from: 0.5, to: viewport.height, by: 3.0) {
                let point = TreemapPoint(x: x, y: y)
                guard result.box(at: point) != nil else { misses += 1; continue }
                let containing = result.filledBoxes.filter { $0.frame.contains(point) }
                XCTAssertEqual(containing.count, 1, "\(containing.count) boxes claim (\(x), \(y))")
            }
        }
        XCTAssertEqual(misses, 0, "the map has holes")
    }

    func test_anAggregateInteriorReturnsTheAggregate() {
        let result = TreemapLayout.layout(tree: Fixture.dominantPlusTail, viewport: square)

        guard let aggregateBox = result.boxes.first(where: { $0.isAggregate }) else {
            return XCTFail("expected a merge")
        }
        let inside = TreemapPoint(x: aggregateBox.frame.minX + aggregateBox.frame.width / 2, y: 50)
        let hit = result.box(at: inside)

        XCTAssertTrue(hit?.isAggregate == true)
        XCTAssertEqual(hit?.aggregate?.bytes, 10)
        XCTAssertNil(result.node(at: inside), "an aggregate is not a file — it has no node to open or reveal")
    }

    func test_hitTestingIsDeterministicAcrossRuns() {
        let viewport = TreemapSize(width: 640, height: 480)
        let points = stride(from: 1.0, to: 640.0, by: 17.0).flatMap { x in
            stride(from: 1.0, to: 480.0, by: 13.0).map { TreemapPoint(x: x, y: $0) }
        }
        let first = TreemapLayout.layout(tree: Fixture.realistic, viewport: viewport)
        let second = TreemapLayout.layout(tree: Fixture.realistic, viewport: viewport)

        for point in points {
            XCTAssertEqual(first.box(at: point)?.frame, second.box(at: point)?.frame)
            XCTAssertEqual(first.node(at: point)?.treemapName, second.node(at: point)?.treemapName)
        }
    }

    func test_pointsOutsideTheViewportHitNothing() {
        let result = TreemapLayout.layout(tree: Fixture.handComputable, viewport: square)

        XCTAssertNil(result.box(at: TreemapPoint(x: -1, y: 50)))
        XCTAssertNil(result.box(at: TreemapPoint(x: 100, y: 50)), "the far edge is exclusive")
        XCTAssertNil(result.box(at: TreemapPoint(x: 50, y: 100)))
        XCTAssertNotNil(result.box(at: TreemapPoint(x: 0, y: 0)), "the near edge is inclusive")
    }

    func test_theDeepestBoxWinsAtEveryDepth() {
        let result = TreemapLayout.layout(tree: Fixture.deepChain(depth: 32), viewport: TreemapSize(width: 900, height: 700))
        let deepest = result.filledBoxes.max { $0.depth < $1.depth }!

        let centre = TreemapPoint(
            x: deepest.frame.minX + deepest.frame.width / 2,
            y: deepest.frame.minY + deepest.frame.height / 2
        )
        let hit = result.box(at: centre)
        XCTAssertEqual(hit?.depth, deepest.depth)
        XCTAssertEqual(hit?.frame, deepest.frame)
    }
}
