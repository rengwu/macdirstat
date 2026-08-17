import XCTest
@testable import TreemapLayout

/// Spec §6.1: recursive squarified layout, children in bytes-descending order,
/// area strictly proportional to attributed bytes, unrounded points.
final class SquarifiedGeometryTests: XCTestCase {
    private let square = TreemapSize(width: 100, height: 100)

    // MARK: - Golden rectangles

    /// 4,000 / 3,000 / 2,000 / 1,000 bytes in a 100×100 viewport is one
    /// pt² per byte, so the whole packing can be worked out by hand:
    /// `[a, b]` fill a 70 pt strip down the left, `c` and `d` stack in the
    /// 30 pt column that is left.
    func test_goldenRectanglesForAHandComputableTree() {
        let result = TreemapLayout.layout(tree: Fixture.handComputable, viewport: square)

        XCTAssertEqual(result.boxes.count, 5, "one root region plus four leaves")
        assertRectEqual(result.frame(ofNodeNamed: "a.bin")!, TreemapRect(x: 0, y: 0, width: 70, height: 400.0 / 7))
        assertRectEqual(result.frame(ofNodeNamed: "b.bin")!, TreemapRect(x: 0, y: 400.0 / 7, width: 70, height: 300.0 / 7))
        assertRectEqual(result.frame(ofNodeNamed: "c.bin")!, TreemapRect(x: 70, y: 0, width: 30, height: 200.0 / 3))
        assertRectEqual(result.frame(ofNodeNamed: "d.bin")!, TreemapRect(x: 70, y: 200.0 / 3, width: 30, height: 100.0 / 3))

        assertLayoutInvariants(result)
        assertNoSlivers(result)
    }

    /// The same tree one level down: a directory's rectangle is just another
    /// viewport, so its children reproduce the golden packing scaled into it.
    func test_layoutRecursesPerDirectory() {
        let tree = Fixture.directory("root", [
            Fixture.directory("left", [
                Fixture.file("a.bin", 4_000), Fixture.file("b.bin", 3_000),
                Fixture.file("c.bin", 2_000), Fixture.file("d.bin", 1_000),
            ]),
            Fixture.file("right.bin", 10_000),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 200, height: 100))

        let left = result.frame(ofNodeNamed: "left")!
        assertRectEqual(left, TreemapRect(x: 0, y: 0, width: 100, height: 100))
        assertRectEqual(result.frame(ofNodeNamed: "a.bin")!, TreemapRect(x: 0, y: 0, width: 70, height: 400.0 / 7))
        XCTAssertTrue(result.box(ofNodeNamed: "left")!.isSubdivided)
        XCTAssertFalse(result.box(ofNodeNamed: "a.bin")!.isSubdivided)
        assertLayoutInvariants(result)
    }

    // MARK: - Determinism

    func test_repeatedRunsAreByteIdentical() {
        for fixture in [Fixture.handComputable, Fixture.realistic, Fixture.extremeSkew] {
            let first = TreemapLayout.layout(tree: fixture, viewport: TreemapSize(width: 733, height: 419))
            for _ in 0..<5 {
                let again = TreemapLayout.layout(tree: fixture, viewport: TreemapSize(width: 733, height: 419))
                XCTAssertEqual(first.frames, again.frames, "geometry drifted between runs")
                XCTAssertEqual(first.statistics, again.statistics)
            }
        }
    }

    /// The input order must not reach the output: the spec's sort is what makes
    /// two scans of the same disk draw the same picture.
    func test_shufflingTheInputDoesNotMoveARectangle() {
        let children = (0..<40).map { Fixture.file("f-\(String(format: "%02d", $0)).bin", Int64(1_000 + $0 * 37)) }
        let ordered = TreemapLayout.layout(tree: Fixture.directory("root", children), viewport: square)
        let shuffled = TreemapLayout.layout(tree: Fixture.directory("root", children.reversed()), viewport: square)

        XCTAssertEqual(ordered.frames, shuffled.frames)
    }

    func test_equalBytesBreakTiesByNameInCodePointOrder() {
        // Uppercase sorts before lowercase in code-point order, and "Z" (0x5A)
        // before "a" (0x61) — which is exactly where a locale-aware or
        // case-insensitive comparison would disagree.
        let names = ["b", "Z", "a", "A", "É", "e"]
        let tree = Fixture.directory("root", names.map { Fixture.file($0, 1_000) })
        let result = TreemapLayout.layout(tree: tree, viewport: square)

        let laidOut = result.boxes.dropFirst().compactMap { $0.node?.treemapName }
        XCTAssertEqual(laidOut, ["A", "Z", "a", "b", "e", "É"])
    }

    /// Two spellings of one name are two names here, exactly as they are in the
    /// scanner (`ScanCore.NameOrder`): the decomposed one sorts first, because
    /// `U+0065` precedes `U+00E9`, and it does so whichever order they arrived
    /// in. Compared as bytes on purpose — `String ==` is canonical equivalence,
    /// so an assertion written over `String` could not tell them apart, and it
    /// is that same equivalence which used to send this pair to the discovery-
    /// position tie-break instead of to the name one.
    func test_twoSpellingsOfOneNameAreOrderedByCodePointAndNotByDiscovery() {
        let precomposed = "caf\u{00E9}.bin"
        let decomposed = "cafe\u{0301}.bin"

        for children in [[precomposed, decomposed], [decomposed, precomposed]] {
            let tree = Fixture.directory("root", children.map { Fixture.file($0, 1_000) })
            let result = TreemapLayout.layout(tree: tree, viewport: square)

            let laidOut = result.boxes.dropFirst().compactMap { $0.node?.treemapName }.map { Array($0.utf8) }
            XCTAssertEqual(laidOut, [Array(decomposed.utf8), Array(precomposed.utf8)],
                           "arrived as \(children == [precomposed, decomposed] ? "NFC first" : "NFD first")")
        }
    }

    func test_bytesDescendingOutranksTheNameTieBreak() {
        let tree = Fixture.directory("root", [
            Fixture.file("zzz.bin", 9_000),
            Fixture.file("aaa.bin", 1_000),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: square)
        XCTAssertEqual(result.boxes.dropFirst().compactMap { $0.node?.treemapName }, ["zzz.bin", "aaa.bin"])
    }

    // MARK: - Area is the whole encoding

    func test_areaRatiosEqualByteRatiosExactly() {
        let tree = Fixture.directory("root", [
            Fixture.file("big.bin", 7_000),
            Fixture.file("small.bin", 3_000),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: TreemapSize(width: 640, height: 400))

        let big = result.frame(ofNodeNamed: "big.bin")!.area
        let small = result.frame(ofNodeNamed: "small.bin")!.area
        XCTAssertEqual(big / small, 7.0 / 3.0, accuracy: 1e-9, "the encoding is not linear in bytes")
        XCTAssertEqual(big + small, 640 * 400, accuracy: 1e-6)
    }

    /// A log scale, a minimum-area floor, or a per-level inset would each show
    /// up here: over four orders of magnitude the smallest child's area stays
    /// exactly its share, right up to the point where it merges instead.
    func test_areaStaysProportionalAcrossFourOrdersOfMagnitude() {
        let big: Int64 = 10_000_000
        let viewport = TreemapSize(width: 1_000, height: 1_000)

        for exponent in 0...4 {
            let small = Int64(pow(10.0, Double(4 - exponent)))
            let tree = Fixture.directory("root", [Fixture.file("big.bin", big), Fixture.file("small.bin", small)])
            let result = TreemapLayout.layout(tree: tree, viewport: viewport)

            // The tail merges below a certain size; §6.2 governs that case, and
            // the aggregate's own area is asserted there.
            guard let frame = result.frame(ofNodeNamed: "small.bin") else { continue }
            XCTAssertEqual(
                frame.area, viewport.area * Double(small) / Double(big + small), accuracy: 1e-6,
                "a \(small) byte child is not drawn at its exact share"
            )
        }
    }

    func test_aDirectoryIsTiledExactlyByItsChildren() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 921, height: 577))
        assertSiblingsFillTheirParent(result, tolerance: 1e-6)
        assertLayoutInvariants(result)
    }

    // MARK: - Zero-byte entries

    func test_zeroByteEntriesGetNoRectangle() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 800, height: 600))

        XCTAssertNil(result.box(ofNodeNamed: "empty.txt"), "an empty file has no area, so no box")
        XCTAssertNil(result.box(ofNodeNamed: "alias"), "a symlink is zero-attributed (§3.4)")
        XCTAssertNil(result.box(ofNodeNamed: "locked.plist"), "an unreadable entry's size is never guessed")
        XCTAssertNotNil(result.box(ofNodeNamed: "Caches.db"), "its readable sibling still draws")
    }

    func test_aTreeWithNoBytesLaysOutNothing() {
        let tree = Fixture.directory("root", [Fixture.file("a", 0), Fixture.file("b", 0)])
        let result = TreemapLayout.layout(tree: tree, viewport: square)

        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertNil(result.box(at: TreemapPoint(x: 50, y: 50)))
    }

    func test_aDegenerateViewportLaysOutNothing() {
        for viewport in [TreemapSize(width: 0, height: 400), TreemapSize(width: 400, height: 0), TreemapSize(width: -5, height: 5)] {
            let result = TreemapLayout.layout(tree: Fixture.handComputable, viewport: viewport)
            XCTAssertTrue(result.boxes.isEmpty, "\(viewport) should produce nothing")
        }
    }

    // MARK: - Packages

    /// §3.4 / ticket 01: drilling into a package subdivides its box without
    /// changing the outer rectangle, because the bytes were counted at scan
    /// time either way.
    func test_expandingAPackageDoesNotMoveItsOuterRectangle() {
        let contents: [TreemapTree] = [
            Fixture.file("Contents", 8 * Fixture.gib),
            Fixture.file("Frameworks", 4 * Fixture.gib),
        ]
        let collapsed = Fixture.directory("root", [
            TreemapTree(collapsedPackage: "Xcode.app", bytes: 12 * Fixture.gib),
            Fixture.file("other.bin", 6 * Fixture.gib),
        ])
        let expanded = Fixture.directory("root", [
            TreemapTree(directory: "Xcode.app", kind: .package, children: contents),
            Fixture.file("other.bin", 6 * Fixture.gib),
        ])
        let viewport = TreemapSize(width: 520, height: 390)

        let a = TreemapLayout.layout(tree: collapsed, viewport: viewport)
        let b = TreemapLayout.layout(tree: expanded, viewport: viewport)

        XCTAssertEqual(a.frame(ofNodeNamed: "Xcode.app"), b.frame(ofNodeNamed: "Xcode.app"))
        XCTAssertFalse(a.box(ofNodeNamed: "Xcode.app")!.isSubdivided)
        XCTAssertTrue(b.box(ofNodeNamed: "Xcode.app")!.isSubdivided)
        XCTAssertEqual(a.frame(ofNodeNamed: "Xcode.app")!.area, 520.0 * 390 * 12 / 18, accuracy: 1e-6)
    }
}
