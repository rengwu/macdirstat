import XCTest
@testable import TreemapLayout

// MARK: - Fixtures

/// Deterministic pseudo-random sizes. A seeded generator rather than
/// `Int.random`, because a geometry suite that cannot be re-run on the same
/// numbers proves nothing about determinism.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// A log-uniform size in `low...high` — the shape real file sizes take,
    /// and the one that puts children on both sides of the merge threshold.
    mutating func logUniform(_ low: Double, _ high: Double) -> Int64 {
        let unit = Double(next() % 1_000_000) / 1_000_000
        return Int64(low * pow(high / low, unit))
    }
}

enum Fixture {
    static let kib: Int64 = 1024
    static let mib: Int64 = 1024 * kib
    static let gib: Int64 = 1024 * mib

    static func file(_ name: String, _ bytes: Int64) -> TreemapTree {
        TreemapTree(name: name, bytes: bytes)
    }

    static func directory(_ name: String, _ children: [TreemapTree]) -> TreemapTree {
        TreemapTree(directory: name, children: children)
    }

    /// Four children, hand-computable at 100×100 with a scale of exactly
    /// 1 pt² per byte.
    static var handComputable: TreemapTree {
        directory("root", [
            file("a.bin", 4_000),
            file("b.bin", 3_000),
            file("c.bin", 2_000),
            file("d.bin", 1_000),
        ])
    }

    /// One dominant child and a tail that cannot survive at any sane viewport.
    static var dominantPlusTail: TreemapTree {
        directory("root", [
            file("big.bin", 9_990),
            file("b.bin", 5),
            file("c.bin", 3),
            file("d.bin", 2),
        ])
    }

    /// The §8.1 extreme rung: 40 GiB beside 40 entries of a few KiB.
    static var extremeSkew: TreemapTree {
        var children = [file("huge.iso", 40 * gib)]
        var generator = SeededGenerator(seed: 0xA11CE)
        for index in 0..<40 {
            children.append(file(String(format: "tail-%02d.log", index), generator.logUniform(64, 8 * 1024)))
        }
        return directory("root", children)
    }

    /// The §8.1 dense rung: one directory with 2,500 entries.
    static var dense: TreemapTree {
        var generator = SeededGenerator(seed: 0xDE45E)
        var children: [TreemapTree] = []
        for index in 0..<2_500 {
            children.append(file(String(format: "item-%04d.dat", index), generator.logUniform(512, 256 * 1024 * 1024)))
        }
        return directory("root", children)
    }

    /// A chain `depth` levels deep, each level carrying a file beside the next
    /// directory, so every level has something to draw.
    static func deepChain(depth: Int) -> TreemapTree {
        var node = directory("level-\(depth)", [file("leaf.bin", 4 * mib)])
        for level in stride(from: depth - 1, through: 1, by: -1) {
            node = directory("level-\(level)", [node, file("side-\(level).bin", 512 * kib)])
        }
        return directory("root", [node])
    }

    /// A shape with everything in it: nested directories, a collapsed package,
    /// zero-byte entries of each kind, an incomplete directory, and a subtree
    /// that is collectively too small to draw.
    static var realistic: TreemapTree {
        directory("root", [
            directory("Media", [
                file("holiday.mov", 3 * gib),
                file("podcast.m4a", 220 * mib),
                file("poster.png", 4 * mib),
            ]),
            directory("Developer", [
                directory("checkout", [
                    file("main.swift", 18 * kib),
                    file("README.md", 2 * kib),
                    file("Package.resolved", 900),
                ]),
                TreemapTree(collapsedPackage: "Xcode.app", bytes: 12 * gib),
            ]),
            TreemapTree(
                directory: "Library",
                readState: .incomplete,
                children: [
                    file("Caches.db", 90 * mib),
                    file("locked.plist", 0),
                ]
            ),
            directory("dust", (0..<12).map { file("speck-\($0).dat", Int64(11 + $0)) }),
            file("empty.txt", 0),
            TreemapTree(name: "alias", bytes: 0, kind: .symbolicLink),
        ])
    }
}

// MARK: - Invariants

extension XCTestCase {
    /// Everything §6 promises about *any* layout, asserted after every fixture.
    ///
    /// Tolerances are scale-relative because the arithmetic is: rows consume a
    /// rectangle's area by repeated subtraction, so a shared edge agrees to
    /// within the double's last few bits, never exactly.
    func assertLayoutInvariants<Node: TreemapInputNode>(
        _ result: TreemapLayoutResult<Node>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = TreemapRect(origin: TreemapPoint(x: 0, y: 0), size: result.viewport)
        let lengthTolerance = max(result.viewport.width, result.viewport.height) * 1e-9
        let areaTolerance = max(viewport.area, 1) * 1e-9

        for (index, box) in result.boxes.enumerated() {
            XCTAssertGreaterThanOrEqual(box.frame.width, 0, "box \(index) has negative width", file: file, line: line)
            XCTAssertGreaterThanOrEqual(box.frame.height, 0, "box \(index) has negative height", file: file, line: line)
            XCTAssertTrue(
                box.frame.isContained(in: viewport, tolerance: lengthTolerance),
                "box \(index) \(box.frame) escapes the viewport",
                file: file, line: line
            )
            XCTAssertTrue(box.frame.x.isFinite && box.frame.y.isFinite, file: file, line: line)
            XCTAssertTrue(box.frame.width.isFinite && box.frame.height.isFinite, file: file, line: line)

            if let parentIndex = box.parentIndex {
                XCTAssertLessThan(parentIndex, index, "a box precedes its parent in draw order", file: file, line: line)
                XCTAssertEqual(box.depth, result.boxes[parentIndex].depth + 1, file: file, line: line)
                XCTAssertTrue(
                    box.frame.isContained(in: result.boxes[parentIndex].frame, tolerance: lengthTolerance),
                    "box \(index) escapes its parent",
                    file: file, line: line
                )
            } else {
                XCTAssertEqual(index, 0, "only the root has no parent", file: file, line: line)
            }
        }

        // Filled boxes tile the viewport: none of them overlaps another, and
        // together they account for all of it.
        let filled = result.filledBoxes
        for i in filled.indices {
            for j in filled.index(after: i)..<filled.endIndex {
                XCTAssertFalse(
                    filled[i].frame.overlaps(filled[j].frame, tolerance: lengthTolerance),
                    "\(filled[i].frame) overlaps \(filled[j].frame)",
                    file: file, line: line
                )
            }
        }
        if !result.boxes.isEmpty {
            XCTAssertEqual(
                result.statistics.coveredArea, viewport.area, accuracy: areaTolerance,
                "the filled boxes do not account for 100% of the viewport",
                file: file, line: line
            )
        }

        assertSiblingsFillTheirParent(result, tolerance: areaTolerance, file: file, line: line)
        assertAtMostOneAggregatePerDirectory(result, file: file, line: line)
    }

    /// §6.2's area truthfulness, stated per directory: children plus the
    /// aggregate account for the parent exactly. No inset, header, or gutter
    /// can hide in that sum.
    func assertSiblingsFillTheirParent<Node: TreemapInputNode>(
        _ result: TreemapLayoutResult<Node>,
        tolerance: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var childArea: [Int: Double] = [:]
        for box in result.boxes {
            guard let parentIndex = box.parentIndex else { continue }
            childArea[parentIndex, default: 0] += box.frame.area
        }
        for (parentIndex, area) in childArea {
            let parent = result.boxes[parentIndex]
            XCTAssertEqual(
                area, parent.frame.area, accuracy: max(parent.frame.area, 1) * 1e-9 + tolerance,
                "children of box \(parentIndex) do not fill it",
                file: file, line: line
            )
        }
    }

    func assertAtMostOneAggregatePerDirectory<Node: TreemapInputNode>(
        _ result: TreemapLayoutResult<Node>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var aggregates: [Int: Int] = [:]
        for box in result.boxes where box.isAggregate {
            guard let parentIndex = box.parentIndex else {
                return XCTFail("an aggregate with no parent directory", file: file, line: line)
            }
            aggregates[parentIndex, default: 0] += 1
        }
        for (parentIndex, count) in aggregates {
            XCTAssertEqual(count, 1, "box \(parentIndex) has \(count) aggregates", file: file, line: line)
        }
        XCTAssertEqual(
            aggregates.count, result.statistics.aggregateBoxCount,
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            result.statistics.aggregateBoxCount, result.statistics.subdividedBoxCount,
            "more aggregates than directories to hold them",
            file: file, line: line
        )
    }

    /// No filled box may be thinner than the merge threshold in either
    /// direction — except an aggregate, which has nothing left to fold into.
    func assertNoSlivers<Node: TreemapInputNode>(
        _ result: TreemapLayoutResult<Node>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for box in result.filledBoxes where !box.isAggregate {
            XCTAssertGreaterThanOrEqual(
                box.frame.shortestSide, TreemapMetrics.mergeThresholdPoints,
                "\(box.node?.treemapName ?? "?") survived as a \(box.frame.shortestSide) pt sliver",
                file: file, line: line
            )
        }
        XCTAssertFalse(result.statistics.reachedRoundCap, "the merge fixpoint did not settle", file: file, line: line)
    }

    func assertRectEqual(
        _ actual: TreemapRect,
        _ expected: TreemapRect,
        accuracy: Double = 1e-9,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(message) x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(message) y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "\(message) width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "\(message) height", file: file, line: line)
    }
}

// MARK: - Reading a result

extension TreemapLayoutResult {
    /// The frame of the first box for a node of this name, whatever its depth.
    func frame(ofNodeNamed name: String) -> TreemapRect? {
        boxes.first { $0.node?.treemapName == name }?.frame
    }

    func box(ofNodeNamed name: String) -> TreemapBox<Node>? {
        boxes.first { $0.node?.treemapName == name }
    }

    func index(ofNodeNamed name: String) -> Int? {
        boxes.firstIndex { $0.node?.treemapName == name }
    }

    /// The boxes tiling the box at `index`.
    func childBoxes(of index: Int) -> [TreemapBox<Node>] {
        boxes.filter { $0.parentIndex == index }
    }

    var aggregates: [TreemapAggregate<Node>] {
        boxes.compactMap { $0.aggregate }
    }

    /// Every frame in draw order — the comparison a determinism test makes.
    var frames: [TreemapRect] {
        boxes.map { $0.frame }
    }
}
