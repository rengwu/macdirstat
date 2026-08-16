import XCTest
@testable import TreemapLayout

/// Area is the whole encoding (spec §6.1, §6.2), which is a claim about what
/// the layout *does not* do: no per-level inset, no directory header, no log
/// scaling, no minimum-area inflation, no synthetic box beyond the one exact
/// merge bucket.
///
/// The behavioural half of that is asserted here; the structural half is
/// asserted against the engine's own source, because a later session adding a
/// "just 1 pt of breathing room" would break area truthfulness by a margin too
/// small for any single fixture to notice.
final class LayoutHonestyTests: XCTestCase {
    // MARK: - Behaviour

    func test_theModuleIsBuiltAgainstTheDeploymentFloor() {
        XCTAssertEqual(TreemapLayout.minimumSupportedMacOS, "11.0")
    }

    /// A header or an inset steals a constant from every directory, so it shows
    /// up as a gap between a parent's area and its children's — at every depth,
    /// and worst where the nesting is deepest.
    func test_nestingCostsNoArea() {
        let flat = Fixture.directory("root", [Fixture.file("a.bin", 5_000), Fixture.file("b.bin", 5_000)])
        let nested = Fixture.directory("root", [
            Fixture.directory("one", [Fixture.directory("two", [Fixture.directory("three", [Fixture.file("a.bin", 5_000)])])]),
            Fixture.file("b.bin", 5_000),
        ])
        let viewport = TreemapSize(width: 400, height: 400)

        let flatResult = TreemapLayout.layout(tree: flat, viewport: viewport)
        let nestedResult = TreemapLayout.layout(tree: nested, viewport: viewport)

        XCTAssertEqual(
            flatResult.frame(ofNodeNamed: "a.bin")!.area,
            nestedResult.frame(ofNodeNamed: "a.bin")!.area,
            accuracy: 1e-9,
            "three levels of nesting cost area — something is inset"
        )
        XCTAssertEqual(nestedResult.frame(ofNodeNamed: "a.bin")!, nestedResult.frame(ofNodeNamed: "three")!)
    }

    /// Log scaling flatters small files. Doubling one child's bytes must double
    /// its area, at every magnitude, or the map is no longer readable as area.
    ///
    /// The tree's total is held fixed — a filler sibling absorbs the
    /// difference — so the only thing that changes between the two layouts is
    /// the subject's share.
    func test_doublingBytesDoublesArea() {
        // A big viewport and a floor on the subject's share, so it is the
        // encoding under test rather than the merge rule: a child small enough
        // to land in the final strip merges, and §6.2 owns that case.
        let viewport = TreemapSize(width: 2_000, height: 2_000)
        let total: Int64 = 4_000_000_000

        func area(ofSubjectSized bytes: Int64) -> Double {
            let tree = Fixture.directory("root", [
                Fixture.file("subject.bin", bytes),
                Fixture.file("filler.bin", total - bytes),
            ])
            let result = TreemapLayout.layout(tree: tree, viewport: viewport)
            return result.frame(ofNodeNamed: "subject.bin")?.area ?? .nan
        }

        for bytes: Int64 in [8_000_000, 40_000_000, 200_000_000, 1_000_000_000] {
            let single = area(ofSubjectSized: bytes)
            let double = area(ofSubjectSized: bytes * 2)
            XCTAssertEqual(double / single, 2, accuracy: 1e-6, "\(bytes) bytes are not drawn linearly")
            XCTAssertEqual(single, viewport.area * Double(bytes) / Double(total), accuracy: 1e-6)
        }
    }

    /// Minimum-area inflation would give a small survivor more room than it has
    /// bytes for — stealing it from a sibling. Right at the merge threshold is
    /// where such a fudge would hide.
    func test_aSurvivorJustAboveTheThresholdGetsExactlyItsShare() {
        // 1,000,000 pt² of viewport, so a child of n bytes in a million gets
        // exactly n pt² — and 5 pt² is comfortably under 2×2.
        let viewport = TreemapSize(width: 1_000, height: 1_000)
        let tree = Fixture.directory("root", [
            Fixture.file("bulk.bin", 999_950),
            Fixture.file("edge.bin", 50),
        ])
        let result = TreemapLayout.layout(tree: tree, viewport: viewport)

        if let edge = result.frame(ofNodeNamed: "edge.bin") {
            XCTAssertEqual(edge.area, 50, accuracy: 1e-6, "the survivor was inflated")
        } else {
            XCTAssertEqual(result.aggregates.first?.bytes, 50)
            XCTAssertEqual(result.filledBoxes.first(where: { $0.isAggregate })?.frame.area ?? 0, 50, accuracy: 1e-6,
                           "the aggregate was inflated")
        }
    }

    func test_theOnlySyntheticBoxIsTheMergeBucket() {
        let result = TreemapLayout.layout(tree: Fixture.realistic, viewport: TreemapSize(width: 700, height: 500))

        for box in result.boxes {
            switch box.content {
            case .node: continue
            case .aggregate(let aggregate):
                XCTAssertFalse(aggregate.mergedRoots.isEmpty, "an aggregate standing for nothing")
                XCTAssertGreaterThan(aggregate.bytes, 0)
            }
        }
    }

    // MARK: - Structure

    private func source(_ fileName: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TreemapLayoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TreemapLayout (package root)
            .appendingPathComponent("Sources/TreemapLayout/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code, not comments: the prose in these files says the words "inset" and
    /// "log scaling" precisely because it is promising not to do them.
    private func executableText(of fileName: String) throws -> String {
        try source(fileName)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.isEmpty }
            .joined(separator: "\n")
            .lowercased()
    }

    func test_theGeometryEngineContainsNoInsetHeaderOrRescaling() throws {
        let banned = ["inset", "padding", "margin", "gutter", "header", "log(", "log2(", "log10(", "sqrt(", "minimumarea", "minarea"]

        for fileName in ["SquarifiedLayout.swift", "TreemapLayout.swift", "PreparedTree.swift"] {
            let text = try executableText(of: fileName)
            for token in banned {
                XCTAssertFalse(text.contains(token), "\(fileName) contains \"\(token)\" — area must stay linear in bytes")
            }
        }
    }

    func test_theMergeThresholdIsTwoPointsAndIsReadFromOnePlace() throws {
        XCTAssertEqual(TreemapMetrics.mergeThresholdPoints, 2)

        let engine = try executableText(of: "TreemapLayout.swift")
        XCTAssertTrue(engine.contains("treemapmetrics.mergethresholdpoints"))
        XCTAssertFalse(
            try executableText(of: "SquarifiedLayout.swift").contains("mergethreshold"),
            "the squarifier must know nothing about merging — that is what makes it re-runnable"
        )
    }
}
