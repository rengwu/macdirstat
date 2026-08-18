import Foundation

/// How much picture one layout may draw — and so what a relayout costs,
/// whatever the tree and the display are.
///
/// Unbudgeted, the box count is set by the viewport: the merge rule keeps every
/// drawn rectangle at 2×2 pt or larger (spec §6.2), so a window of twice the
/// area holds twice the boxes and both the layout and the repaint follow. That
/// is affordable at 1440×900 and is not at 4K maximized, where the §8.1 large
/// rung lands 137,056 boxes and 1.17 s of layout — the map is then paying to
/// place rectangles the eye cannot separate anyway.
///
/// A budget is a cap on *boxes*, not on nodes, because boxes are what both
/// costs scale with. It is spent two ways, and neither binds until the picture
/// is genuinely over budget:
///
/// 1. **Per directory, by area share** (``allowance(forRect:viewportArea:)``).
///    A region gets the fraction of the budget its rectangle takes of the
///    viewport, and children beyond that fold into the same aggregate box the
///    sliver rule uses. Shares telescope — a directory's children's rectangles
///    sum to its own — so a whole tiling level sums back to the budget.
/// 2. **Across the walk.** The walk runs largest-rectangle-first once budgeted,
///    and stops opening directories when the cap is reached. What is left
///    unopened stays on screen as one box for its whole subtree, at its exact
///    attributed area.
///
/// Area truthfulness is untouched either way: nothing is dropped, so the filled
/// boxes still tile the viewport exactly (spec §6.1).
public struct TreemapLayoutBudget: Hashable, Sendable {
    /// The most filled boxes a layout may produce, or `nil` for no cap.
    ///
    /// It is a target rather than a hard ceiling in one narrow way: the
    /// directory that exhausts the budget is finished rather than abandoned, so
    /// the result can exceed the cap by that directory's own allowance plus its
    /// one aggregate. Bounded work, which is the point; not a bounded number to
    /// assert equality on.
    public let visibleBoxes: Int?

    public init(visibleBoxes: Int?) {
        self.visibleBoxes = visibleBoxes.map { Swift.max(1, $0) }
    }

    /// No cap: the geometry the layout has always produced, box for box.
    public static let unbounded = TreemapLayoutBudget(visibleBoxes: nil)

    public static func boxes(_ count: Int) -> TreemapLayoutBudget {
        TreemapLayoutBudget(visibleBoxes: count)
    }

    /// What the app runs with — see ``TreemapMetrics/standardVisibleBoxBudget``.
    public static let standard = TreemapLayoutBudget(
        visibleBoxes: TreemapMetrics.standardVisibleBoxBudget
    )

    public var isBounded: Bool { visibleBoxes != nil }

    /// How many boxes a region may spend: its share of the budget by area.
    ///
    /// By area rather than by bytes, because area is what the budget buys — and
    /// because area shares are exactly what nests. Never below 1: a region that
    /// is drawn at all may always resolve into *something*, which is what keeps
    /// a deep tree from folding away at the first level that rounds to zero.
    func allowance(forRect rect: TreemapRect, viewportArea: Double) -> Int? {
        guard let visibleBoxes else { return nil }
        guard viewportArea > 0, rect.area > 0 else { return 1 }
        let share = (Double(visibleBoxes) * (rect.area / viewportArea)).rounded(.down)
        guard share.isFinite else { return visibleBoxes }
        return Int(Swift.min(Double(visibleBoxes), Swift.max(1, share)))
    }
}
