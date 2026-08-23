import XCTest
@testable import TreemapLayout

/// A differential suite that pins ``SquarifiedLayout/tile(weights:in:)`` to the
/// row-rescanning algorithm it was born with.
///
/// The package promises byte-identical geometry for identical input, so an
/// optimization inside the row loop is only allowed if it produces *exactly*
/// the same rectangles — not rectangles within an epsilon. `Reference` below is
/// the original algorithm, copied here before the production one was touched,
/// with its arithmetic in the original order. Every case runs both and compares
/// with `==` on `Double`.
///
/// The interesting inputs are the nonmonotonic ones. `PreparedTree` sorts real
/// children by bytes descending, but `TreemapLayout.pack` appends the combined
/// aggregate **last**, and that aggregate is a sum that can outweigh the
/// survivors it sits behind. Weights reaching `tile` are therefore not always
/// descending, and any shortcut that assumes a row's extremes sit at its ends
/// is wrong: `[100, 1, 50]` puts the minimum in the middle.
final class SquarifiedReferenceTests: XCTestCase {

    // MARK: - The reference implementation

    /// The pre-optimization squarifier, verbatim: a full rescan of the
    /// candidate row per candidate. Kept as an oracle, never optimized.
    private enum Reference {
        static func tile(weights: [Double], in rect: TreemapRect) -> [TreemapRect] {
            guard !weights.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
            var total = 0.0
            for weight in weights { total += weight }
            guard total > 0 else { return [] }

            let scale = rect.area / total

            var placed: [TreemapRect] = []
            placed.reserveCapacity(weights.count)

            let exhausted = max(rect.width, rect.height) * 1e-12

            var free = rect
            var index = 0

            while index < weights.count, free.width > exhausted, free.height > exhausted {
                let short = free.shortestSide

                let rowStart = index
                var rowSum = 0.0
                var best = Double.infinity
                while index < weights.count {
                    let candidateSum = rowSum + weights[index]
                    let candidate = worstAspectRatio(
                        weights: weights, range: rowStart..<(index + 1),
                        sum: candidateSum, shortSide: short, scale: scale
                    )
                    if index > rowStart, candidate > best { break }
                    rowSum = candidateSum
                    best = candidate
                    index += 1
                }

                let thickness = (rowSum * scale) / short
                if free.width >= free.height {
                    var y = free.y
                    for i in rowStart..<index {
                        let height = (weights[i] * scale) / thickness
                        placed.append(
                            TreemapRect(x: free.x, y: y, width: thickness, height: height)
                        )
                        y += height
                    }
                    free = TreemapRect(
                        x: free.x + thickness, y: free.y,
                        width: max(0, free.width - thickness), height: free.height
                    )
                } else {
                    var x = free.x
                    for i in rowStart..<index {
                        let width = (weights[i] * scale) / thickness
                        placed.append(
                            TreemapRect(x: x, y: free.y, width: width, height: thickness)
                        )
                        x += width
                    }
                    free = TreemapRect(
                        x: free.x, y: free.y + thickness,
                        width: free.width, height: max(0, free.height - thickness)
                    )
                }
            }

            while placed.count < weights.count {
                placed.append(TreemapRect(x: free.x, y: free.y, width: 0, height: 0))
            }
            return placed
        }

        static func worstAspectRatio(
            weights: [Double],
            range: Range<Int>,
            sum: Double,
            shortSide: Double,
            scale: Double
        ) -> Double {
            guard !range.isEmpty else { return .infinity }
            let thickness = (sum * scale) / shortSide
            guard thickness > 0 else { return .infinity }
            var worst = 0.0
            for i in range {
                let length = (weights[i] * scale) / thickness
                guard length > 0 else { return .infinity }
                worst = max(worst, max(length / thickness, thickness / length))
            }
            return worst
        }
    }

    // MARK: - Comparison

    /// Exact equality, field by field, so a failure names the rectangle and the
    /// bit that moved rather than reporting two arrays that "differ".
    private func assertIdentical(
        weights: [Double],
        in rect: TreemapRect,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let produced = SquarifiedLayout.tile(weights: weights, in: rect)
        let expected = Reference.tile(weights: weights, in: rect)

        XCTAssertEqual(
            produced.count, expected.count,
            "\(label): rectangle count", file: file, line: line
        )
        guard produced.count == expected.count else { return }
        for (index, pair) in zip(produced, expected).enumerated() {
            let (got, want) = pair
            guard got != want else { continue }
            XCTFail(
                """
                \(label): rectangle \(index) of \(produced.count) moved.
                  weight \(weights[index])
                  produced \(got)
                  expected \(want)
                """,
                file: file, line: line
            )
            return
        }
    }

    private var rectangles: [(String, TreemapRect)] {
        [
            ("square", TreemapRect(x: 0, y: 0, width: 100, height: 100)),
            ("wide", TreemapRect(x: 12, y: -30, width: 1_600, height: 90)),
            ("tall", TreemapRect(x: -5, y: 7, width: 40, height: 2_400)),
            ("retina viewport", TreemapRect(x: 0, y: 0, width: 1_512, height: 945)),
            ("very small", TreemapRect(x: 3.25, y: 9.5, width: 0.004, height: 0.0017)),
            ("thin sliver", TreemapRect(x: 0, y: 0, width: 900, height: 0.5)),
        ]
    }

    // MARK: - Degenerate and small inputs

    func test_emptyAndSingleWeightInputsMatchTheReference() {
        for (name, rect) in rectangles {
            assertIdentical(weights: [], in: rect, "empty in \(name)")
            assertIdentical(weights: [1], in: rect, "one unit weight in \(name)")
            assertIdentical(weights: [Double(Int64.max)], in: rect, "one huge weight in \(name)")
            assertIdentical(weights: [1e-9], in: rect, "one tiny weight in \(name)")
            assertIdentical(weights: [3, 1], in: rect, "a pair in \(name)")
        }
        // A rectangle with no interior places nothing, in both implementations.
        for degenerate in [
            TreemapRect(x: 0, y: 0, width: 0, height: 100),
            TreemapRect(x: 0, y: 0, width: 100, height: 0),
            TreemapRect(x: 0, y: 0, width: -10, height: -10),
        ] {
            assertIdentical(weights: [5, 4, 3], in: degenerate, "no interior")
        }
    }

    // MARK: - Ordered families

    func test_equalWeightsMatchTheReferenceFromShortRowsToThousands() {
        for count in [2, 3, 4, 7, 16, 64, 257, 1_000, 4_096] {
            let weights = Array(repeating: 7.0, count: count)
            for (name, rect) in rectangles {
                assertIdentical(weights: weights, in: rect, "\(count) equal weights in \(name)")
            }
        }
    }

    func test_strictlyDescendingWeightsMatchTheReference() {
        for count in [3, 12, 129, 1_500] {
            let weights = (0..<count).map { Double(count - $0) * 3.5 }
            for (name, rect) in rectangles {
                assertIdentical(weights: weights, in: rect, "\(count) descending in \(name)")
            }
        }
        // A descending run whose ratios collapse fast, so rows stay short.
        let geometric = (0..<40).map { pow(0.5, Double($0)) * 1_000_000 }
        for (name, rect) in rectangles {
            assertIdentical(weights: geometric, in: rect, "halving run in \(name)")
        }
    }

    // MARK: - Nonmonotonic families

    /// The case the positional first/last shortcut gets wrong: the row's
    /// smallest weight sits in the middle, so its aspect ratio is invisible to
    /// anything that only looks at the ends.
    func test_adversarialRowsWhoseExtremesAreNotAtTheEnds() {
        let adversarial: [[Double]] = [
            [100, 1, 50],
            [1, 100, 50],
            [50, 100, 1],
            [100, 1, 50, 2, 75, 3],
            [1, 1, 1, 1_000_000, 1, 1],
            [1_000_000, 1, 1, 1, 1, 1_000_000],
            [5, 5, 5, 5, 0.000_1, 5, 5],
            [2, 3, 2, 3, 2, 3, 2],
        ]
        for weights in adversarial {
            for (name, rect) in rectangles {
                assertIdentical(weights: weights, in: rect, "\(weights) in \(name)")
            }
        }
    }

    func test_arbitraryNonmonotonicWeightsMatchTheReference() {
        var generator = SeededGenerator(seed: 0x5C_1A_5E)
        for trial in 0..<400 {
            let count = 1 + Int(generator.next() % 60)
            let weights = (0..<count).map { _ in
                Double(generator.logUniform(1, 1_000_000_000))
            }
            let (name, rect) = rectangles[trial % rectangles.count]
            assertIdentical(weights: weights, in: rect, "trial \(trial) in \(name)")
        }
    }

    /// What `pack` actually hands to the tiler after a fold: survivors in
    /// descending order with one aggregate appended, whose value may be below,
    /// among or above them.
    func test_descendingSurvivorsWithAnAggregateAppendedLast() {
        let survivors: [Double] = [900, 640, 410, 275, 180, 96, 41]
        for aggregate in [0.5, 40.0, 100.0, 300.0, 899.0, 901.0, 5_000.0, 1e9] {
            let weights = survivors + [aggregate]
            for (name, rect) in rectangles {
                assertIdentical(
                    weights: weights, in: rect, "aggregate \(aggregate) last in \(name)"
                )
            }
        }
        // The same, with only one or two survivors left standing.
        for weights in [[900.0, 12_000.0], [900.0, 0.25], [900.0, 400.0, 12_000.0]] {
            for (name, rect) in rectangles {
                assertIdentical(weights: weights, in: rect, "\(weights) in \(name)")
            }
        }
    }

    func test_skewedByteScaleWeightsMatchTheReference() {
        var generator = SeededGenerator(seed: 0xB17E5)
        for trial in 0..<200 {
            let count = 2 + Int(generator.next() % 200)
            // Byte counts as they arrive from a scan: a few very large files
            // among a long tail of small ones, then an aggregate of the tail.
            var weights = (0..<count).map { _ in Double(generator.logUniform(1, 4e12)) }
            weights.sort(by: >)
            weights.append(weights.suffix(count / 3).reduce(0, +))
            let (name, rect) = rectangles[trial % rectangles.count]
            assertIdentical(weights: weights, in: rect, "skewed trial \(trial) in \(name)")
        }
    }

    /// Rows tuned to sit on the admission boundary: a candidate whose worst
    /// ratio is a hair better or worse than the row's best is exactly where a
    /// one-bit arithmetic difference would change the packing.
    func test_weightsSittingOnRowAdmissionBoundaries() {
        let square = TreemapRect(x: 0, y: 0, width: 100, height: 100)
        // A row of equal weights admits candidates until the ratio turns; the
        // turn happens at a different index for each of these counts.
        for count in 2...40 {
            assertIdentical(
                weights: Array(repeating: 1.0, count: count), in: square,
                "\(count) equal weights at the boundary"
            )
        }
        // Weights nudged by one ulp either side of an equal-weight row.
        for count in [3, 8, 21] {
            for nudge in [-2.0, -1.0, 0.0, 1.0, 2.0] {
                var weights = Array(repeating: 1.0, count: count)
                var last = weights[count - 1]
                for _ in 0..<abs(Int(nudge)) {
                    last = nudge < 0 ? last.nextDown : last.nextUp
                }
                weights[count - 1] = last
                assertIdentical(
                    weights: weights, in: square, "\(count) weights nudged \(nudge) ulp"
                )
            }
        }
        // A candidate that exactly ties the row's best ratio: the rule admits
        // on ties (`candidate > best` breaks), and both must agree it does.
        assertIdentical(weights: [4, 4, 4, 4], in: TreemapRect(x: 0, y: 0, width: 16, height: 4),
                        "an exact tie at the row boundary")
    }

    // MARK: - Through the public layout

    /// A direct `tile` call cannot reach the aggregate-last order the merge
    /// rule produces, nor the per-region allowances the budget applies. This
    /// runs the whole public layout — budgeted, folded and merged — and re-tiles
    /// every region's children with the reference implementation to check the
    /// drawn rectangles against it.
    func test_publicLayoutsThatFoldAndMergeAreStable() {
        var generator = SeededGenerator(seed: 0xF01DED)
        let viewport = TreemapSize(width: 1_512, height: 945)

        for trial in 0..<12 {
            let wide = Fixture.directory("root", (0..<3_000).map {
                Fixture.file(String(format: "item-%04d.dat", $0), generator.logUniform(1, 4e10))
            })
            for budget in [TreemapLayoutBudget.standard, .boxes(400), .boxes(64), .unbounded] {
                let result = TreemapLayout.layout(tree: wide, viewport: viewport, budget: budget)
                let again = TreemapLayout.layout(tree: wide, viewport: viewport, budget: budget)
                XCTAssertEqual(
                    result.boxes.map(\.frame), again.boxes.map(\.frame),
                    "trial \(trial) with \(budget) is not reproducible"
                )
                // Every child of every region, in the order `pack` placed it,
                // compared against the reference tiler run on the same weights.
                assertRegionsTileLikeTheReference(result, "trial \(trial) with \(budget)")
            }
        }
    }

    /// Re-tiles each region's children with the reference implementation and
    /// checks the drawn frames match. The weights are recovered from the boxes
    /// themselves — bytes in draw order, which is what `pack` passed down.
    private func assertRegionsTileLikeTheReference(
        _ result: TreemapLayoutResult<TreemapTree>,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var childrenByParent: [Int: [Int]] = [:]
        for (index, box) in result.boxes.enumerated() where index > 0 {
            childrenByParent[box.parentIndex ?? 0, default: []].append(index)
        }
        for (parent, children) in childrenByParent {
            let weights = children.map { Double(result.boxes[$0].bytes) }
            guard weights.allSatisfy({ $0 > 0 }) else { continue }
            let expected = Reference.tile(weights: weights, in: result.boxes[parent].frame)
            guard expected.count == children.count else { continue }
            for (slot, child) in children.enumerated() where result.boxes[child].frame != expected[slot] {
                XCTFail(
                    """
                    \(label): region \(parent) child \(slot) moved.
                      produced \(result.boxes[child].frame)
                      expected \(expected[slot])
                    """,
                    file: file, line: line
                )
                return
            }
        }
    }
}
