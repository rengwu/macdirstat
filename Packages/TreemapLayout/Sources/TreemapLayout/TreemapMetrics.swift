import Foundation

/// The settled numbers of §6, in points.
///
/// They live here rather than as literals in the engine and the view so that
/// the merge trigger the layout applies and the label threshold the view honours
/// are provably the same constants the tests assert.
public enum TreemapMetrics {
    /// The merge trigger (spec §6.2). A child whose rectangle would be narrower
    /// **or** shorter than this folds into its directory's aggregate box. It is
    /// a *merge* trigger, never a drop trigger.
    ///
    /// It is a floor on what may be *drawn*, not a cap on how much: at a fixed
    /// 2 pt a window of twice the area holds twice the boxes. Where that number
    /// has to be bounded, ``TreemapLayoutBudget`` folds above this threshold —
    /// into the same aggregate, under the same rule.
    public static let mergeThresholdPoints: Double = 2

    /// Safety cap on the merge fixpoint's rounds per directory.
    ///
    /// The iteration converges on its own — every round strictly shrinks the
    /// survivor set — so this bounds *cost*, not correctness: the pathological
    /// shape is one sliver per round over thousands of children. Ticket 01
    /// measured 5 rounds as the worst case across all four bench fixtures with
    /// the aggregate pinned last, so 8 leaves headroom.
    /// ``TreemapLayoutStatistics/reachedRoundCap`` reports if it ever bound.
    public static let mergeRoundCap = 8

    /// The box cap the app lays out under (``TreemapLayoutBudget/standard``).
    ///
    /// Chosen from the two costs it bounds, both measured at 3840×2160:
    ///
    /// * **Repaint.** Fills plus hairlines — two of the six passes — cost about
    ///   125 ms at 20k boxes, 194 ms at 45k and 412 ms at 140k. Under ~30k the
    ///   full-map repaint stays inside a couple of frames, and after it the
    ///   view repaints only the rectangles that changed.
    /// * **Relayout.** The walk's cost tracks the children it reads, which the
    ///   budget bounds along with the boxes: the §8.1 large rung's 137k boxes
    ///   and 1.17 s fall by roughly the ratio the cap imposes.
    ///
    /// It is a *ceiling*, not a target: a map that resolves in fewer boxes is
    /// laid out exactly as it was before the budget existed, at 2×2 pt.
    public static let standardVisibleBoxBudget = 30_000

    /// A leaf is labelled only when its rectangle is at least this large
    /// (spec §6.3, as realized in the ticket-01 prototype).
    public static let labelMinimumSize = TreemapSize(width: 48, height: 15)
    public static let labelFontSizePoints: Double = 11

    /// Directory outlines are drawn 1 pt wide, but only for the first three
    /// levels below the root — ticket 01's decision, replacing §6.1's "every
    /// directory": on a 20-level chain the deeper strokes overdraw a strip the
    /// fills already bound, with no visible difference.
    public static let directoryOutlineWidthPoints: Double = 1
    public static let directoryOutlineMaximumDepth = 3
    /// Below this size an outline is pure overdraw on a strip.
    public static let directoryOutlineMinimumSidePoints: Double = 2

    /// Hairline between sibling leaves (spec §6.1).
    public static let siblingHairlineWidthPoints: Double = 0.5

    /// Selection: a 2 pt accent stroke inset 1 pt (spec §6.3).
    public static let selectionStrokeWidthPoints: Double = 2
    public static let selectionStrokeInsetPoints: Double = 1

    /// Hover highlight (spec §6.3).
    public static let hoverStrokeWidthPoints: Double = 1
}
