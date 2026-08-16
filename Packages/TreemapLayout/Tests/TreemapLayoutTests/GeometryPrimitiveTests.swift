import XCTest
@testable import TreemapLayout

/// The package's own geometry types (spec §4.2: no CoreGraphics), and the one
/// place rounding is allowed to happen — draw time (§6.1).
final class GeometryPrimitiveTests: XCTestCase {
    func test_containmentIsHalfOpenSoAbuttingRectsNeverBothClaimAPoint() {
        let left = TreemapRect(x: 0, y: 0, width: 10, height: 10)
        let right = TreemapRect(x: 10, y: 0, width: 10, height: 10)

        XCTAssertTrue(left.contains(TreemapPoint(x: 0, y: 0)))
        XCTAssertTrue(left.contains(TreemapPoint(x: 9.999, y: 9.999)))
        XCTAssertFalse(left.contains(TreemapPoint(x: 10, y: 5)))
        XCTAssertTrue(right.contains(TreemapPoint(x: 10, y: 5)))
        XCTAssertFalse(right.contains(TreemapPoint(x: 20, y: 5)))
    }

    func test_overlapIgnoresASharedEdgeButNotSharedInterior() {
        let a = TreemapRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertFalse(a.overlaps(TreemapRect(x: 10, y: 0, width: 5, height: 10)))
        XCTAssertTrue(a.overlaps(TreemapRect(x: 9, y: 0, width: 5, height: 10)))
        XCTAssertFalse(a.overlaps(TreemapRect(x: 9.9999, y: 0, width: 5, height: 10), tolerance: 1e-3))
    }

    func test_snappingRoundsBothEdgesSoNeighboursStayFlush() {
        let left = TreemapRect(x: 0, y: 0, width: 10.4, height: 8)
        let right = TreemapRect(x: 10.4, y: 0, width: 9.6, height: 8)

        for scale in [1.0, 2.0, 3.0] {
            let snappedLeft = left.snapped(toBackingScale: scale)
            let snappedRight = right.snapped(toBackingScale: scale)
            XCTAssertEqual(
                snappedLeft.maxX, snappedRight.minX, accuracy: 1e-12,
                "a seam opened at backing scale \(scale)"
            )
            XCTAssertEqual(snappedLeft.minX, 0)
            XCTAssertEqual(snappedRight.maxX, 20)
            for edge in [snappedLeft.minX, snappedLeft.maxX, snappedRight.maxX] {
                XCTAssertEqual((edge * scale).rounded(), edge * scale, accuracy: 1e-12,
                               "edge \(edge) is off the pixel grid at scale \(scale)")
            }
        }
    }

    func test_snappingAtScaleTwoLandsOnHalfPoints() {
        let rect = TreemapRect(x: 1.3, y: 2.1, width: 4.4, height: 0.9)
        XCTAssertEqual(rect.snapped(toBackingScale: 2), TreemapRect(x: 1.5, y: 2, width: 4, height: 1))
    }

    func test_snappingNeverProducesNegativeExtent() {
        let sliver = TreemapRect(x: 5.4, y: 0, width: 0.01, height: 0.01)
        let snapped = sliver.snapped(toBackingScale: 1)
        XCTAssertEqual(snapped.width, 0)
        XCTAssertEqual(snapped.height, 0)
    }

    func test_snappingIsANoOpForANonsensicalScale() {
        let rect = TreemapRect(x: 1.3, y: 2.1, width: 4.4, height: 0.9)
        XCTAssertEqual(rect.snapped(toBackingScale: 0), rect)
        XCTAssertEqual(rect.snapped(toBackingScale: -2), rect)
        XCTAssertEqual(rect.snapped(toBackingScale: .infinity), rect)
    }

    func test_theLayoutItselfNeverSnaps() {
        // Same tree, viewport chosen so the exact edges are irrational-looking
        // thirds and sevenths: if anything rounded on the way out, they would
        // land on whole or half points.
        let result = TreemapLayout.layout(tree: Fixture.handComputable, viewport: TreemapSize(width: 100, height: 100))
        let interesting = result.filledBoxes.map { $0.frame.height }
        XCTAssertTrue(
            interesting.contains { abs($0 - $0.rounded()) > 0.01 },
            "every extent landed on a whole point — something is snapping before draw time"
        )
    }
}
