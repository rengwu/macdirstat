import Foundation

/// The squarified treemap of Bruls, Huizing and van Wijk (spec §6.1), as one
/// pure function of `(weights, rect)`.
///
/// It tiles the rectangle completely: every weight's area is
/// `rect.area × weight / Σweights`, with **no** insets, headers, log scaling,
/// or minimum-area inflation. Area is the whole encoding, so nothing may be
/// added to or taken from a rectangle after it is computed.
///
/// The output is index-aligned with the input, which is what lets the merge
/// rule map a sliver back to the child that produced it.
enum SquarifiedLayout {
    /// - Parameters:
    ///   - weights: strictly positive, already in final draw order.
    ///   - rect: the region to tile.
    /// - Returns: one rectangle per weight, in input order.
    static func tile(weights: [Double], in rect: TreemapRect) -> [TreemapRect] {
        guard !weights.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        var total = 0.0
        for weight in weights { total += weight }
        guard total > 0 else { return [] }

        // Points² per unit of weight. Fixed once for the whole rectangle, so
        // rows never renormalize and cumulative rounding cannot creep in.
        let scale = rect.area / total

        var placed: [TreemapRect] = []
        placed.reserveCapacity(weights.count)

        // Rows consume the rectangle's area exactly, so the free region should
        // land on zero — but it lands there through floating-point subtraction.
        // A residue this far below the rectangle's own scale is exhaustion, not
        // room for another row; taking it seriously would divide by it.
        let exhausted = max(rect.width, rect.height) * 1e-12

        var free = rect
        var index = 0

        while index < weights.count, free.width > exhausted, free.height > exhausted {
            let short = free.shortestSide

            // Grow the row while the worst aspect ratio in it keeps improving.
            //
            // The row's worst ratio is decided by its smallest and its largest
            // weight (see ``worstAspectRatio``), so the row carries those two
            // along with its sum instead of being rescanned per candidate. A
            // candidate's own extrema stay in locals until it is admitted: a
            // rejected weight must leave no trace in the row it failed to join.
            let rowStart = index
            var rowSum = 0.0
            var rowSmallest = 0.0
            var rowLargest = 0.0
            var best = Double.infinity
            while index < weights.count {
                let weight = weights[index]
                let startsTheRow = index == rowStart
                let candidateSum = rowSum + weight
                let candidateSmallest = startsTheRow ? weight : min(rowSmallest, weight)
                let candidateLargest = startsTheRow ? weight : max(rowLargest, weight)
                let candidate = worstAspectRatio(
                    smallestWeight: candidateSmallest, largestWeight: candidateLargest,
                    sum: candidateSum, shortSide: short, scale: scale
                )
                if !startsTheRow, candidate > best { break }
                rowSum = candidateSum
                rowSmallest = candidateSmallest
                rowLargest = candidateLargest
                best = candidate
                index += 1
            }

            let thickness = (rowSum * scale) / short
            if free.width >= free.height {
                // The short side is the height: the row is a vertical strip
                // down the left edge.
                var y = free.y
                for i in rowStart..<index {
                    let height = (weights[i] * scale) / thickness
                    placed.append(TreemapRect(x: free.x, y: y, width: thickness, height: height))
                    y += height
                }
                free = TreemapRect(
                    x: free.x + thickness, y: free.y,
                    width: max(0, free.width - thickness), height: free.height
                )
            } else {
                // The short side is the width: the row is a horizontal band
                // across the top edge.
                var x = free.x
                for i in rowStart..<index {
                    let width = (weights[i] * scale) / thickness
                    placed.append(TreemapRect(x: x, y: free.y, width: width, height: thickness))
                    x += width
                }
                free = TreemapRect(
                    x: free.x, y: free.y + thickness,
                    width: free.width, height: max(0, free.height - thickness)
                )
            }
        }

        // Unreachable on consistent input — the rows consume exactly the
        // rectangle's area — but a weight must never be silently dropped: an
        // empty rectangle folds into the merge bucket on the next round,
        // whereas a missing one would take its bytes off the map.
        while placed.count < weights.count {
            placed.append(TreemapRect(x: free.x, y: free.y, width: 0, height: 0))
        }
        return placed
    }

    /// The worst width-to-height ratio a row would have if laid out at
    /// `thickness = sum × scale / shortSide`. Lower is squarer.
    ///
    /// Only two of a row's weights can produce that ratio. At a fixed
    /// thickness, `max(length / thickness, thickness / length)` grows as a
    /// rectangle gets longer *and* as it gets shorter, so it peaks at one end
    /// of the row's range of lengths; length is monotone in weight, so those
    /// ends are the row's smallest and largest weights. Reading the row for
    /// them turned a row of `k` entries into `1 + 2 + … + k` ratio evaluations,
    /// which is why the caller carries them instead.
    ///
    /// This is a claim about **values, not positions**. The weights arriving
    /// here are not sorted: `TreemapLayout.pack` appends the merged aggregate
    /// last, and a sum of folded children can outweigh the survivors in front
    /// of it, so `[100, 1, 50]` reaches this file with its minimum in the
    /// middle. Taking the first and last entries as the extremes would miss it.
    private static func worstAspectRatio(
        smallestWeight: Double,
        largestWeight: Double,
        sum: Double,
        shortSide: Double,
        scale: Double
    ) -> Double {
        let thickness = (sum * scale) / shortSide
        guard thickness > 0 else { return .infinity }
        let shortest = (smallestWeight * scale) / thickness
        let longest = (largestWeight * scale) / thickness
        // A length that underflowed to zero would be divided by below. The
        // smallest weight is where that happens first, but both are checked
        // rather than reasoned about.
        guard shortest > 0, longest > 0 else { return .infinity }
        return max(longest / thickness, thickness / shortest)
    }
}
