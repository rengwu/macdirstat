import Foundation

/// The treemap layout: a pure function of `(tree, viewport)` producing the
/// rectangles the treemap view draws and hit-tests (spec §6).
///
/// Foundation-only and side-effect-free, so the whole of §6 is testable without
/// a window: identical trees at an identical viewport produce byte-identical
/// geometry, on any machine, in any locale, on every run.
///
/// Three rules do all the work:
///
/// 1. **Area is bytes.** Every rectangle's area is exactly proportional to the
///    attributed logical bytes beneath it (§3.1, §6.1). No log scaling, no
///    minimum-area inflation, no insets, no directory headers.
/// 2. **Merge, never disappear** (§6.2). A child whose rectangle would fall
///    below 2×2 pt folds into its directory's single aggregate box, which
///    reports the exact combined bytes. Removing children repacks the
///    survivors, so this iterates to a fixpoint — see
///    ``TreemapMetrics/mergeRoundCap``.
/// 3. **Zero bytes, no rectangle.** Empty files, symlinks, hard-link
///    non-owners and unreadable entries of unknowable size have no area to
///    draw, so they get no box. They stay listed in the tree.
/// 4. **A budget, when one is given** (``TreemapLayoutBudget``). Rules 1–3 fix
///    the box count at the viewport's area over 4 pt², which on a maximized 4K
///    window is more rectangles than either the layout or the repaint can
///    afford, and more than the eye can read. A budget caps them: regions
///    beyond a directory's area share fold into the aggregate it already has,
///    and once the cap is reached the walk stops opening directories, leaving
///    each unopened one as a single box for its whole subtree. Unbudgeted —
///    the default — none of this runs and the geometry is unchanged.
///
/// **The walk reads only what it draws.** A directory is asked for its children
/// at the moment it is about to be subdivided, and never otherwise: everything
/// that folded into an aggregate, and everything beneath it, is left unread.
/// That is what makes the cost proportional to the boxes on screen rather than
/// to the tree's size — the property §6.2 promised and the engine did not
/// have until ticket 14, when a whole-tree pre-pass was found blocking the main
/// thread for seconds on a real volume.
public enum TreemapLayout {
    /// The deployment floor this package is built against (spec §4.2).
    public static let minimumSupportedMacOS = "11.0"

    /// Lays `tree` out in `viewport`, drawing at most `budget` boxes.
    ///
    /// Every size change recomputes from scratch — no cache, no hysteresis,
    /// no animation (spec §6.4) — which is affordable precisely because this
    /// is bounded by *visible* boxes rather than by node count, and, with a
    /// budget, by a number the caller picked rather than by the display's.
    public static func layout<Node: TreemapInputNode>(
        tree: Node,
        viewport: TreemapSize,
        budget: TreemapLayoutBudget = .unbounded
    ) -> TreemapLayoutResult<Node> {
        // A never-cancelled public call preserves the original pure API.
        layoutCancellable(
            tree: tree, viewport: viewport, budget: budget, shouldCancel: { false }
        )!
    }

    /// Coordinator-facing form. `nil` means the caller superseded this work;
    /// no partial geometry escapes and the ordinary layout remains identical.
    static func layoutCancellable<Node: TreemapInputNode>(
        tree: Node,
        viewport: TreemapSize,
        budget: TreemapLayoutBudget = .unbounded,
        shouldCancel: () -> Bool
    ) -> TreemapLayoutResult<Node>? {
        var statistics = TreemapLayoutStatistics()
        statistics.boxBudget = budget.visibleBoxes
        guard viewport.isDrawable, tree.treemapAttributedBytes > 0 else {
            return TreemapLayoutResult(viewport: viewport, boxes: [], statistics: statistics)
        }
        guard !shouldCancel() else { return nil }

        // The one number the layout takes on the seam's word rather than by
        // walking: how many entries have a rectangle to lose. A conformer that
        // maintains it costs nothing here; the protocol's default walks.
        statistics.placedNodeCount = tree.treemapPresentedItemCount
        guard !shouldCancel() else { return nil }

        let viewportRect = TreemapRect(origin: TreemapPoint(x: 0, y: 0), size: viewport)
        let viewportArea = viewportRect.area
        var boxes: [TreemapBox<Node>] = []
        boxes.append(
            TreemapBox(
                content: .node(tree),
                frame: viewportRect,
                depth: 0,
                parentIndex: nil,
                bytes: tree.treemapAttributedBytes,
                isSubdivided: false
            )
        )

        // An explicit queue rather than recursion: depth is the tree's, and the
        // deep-chain rung of the workload ladder is exactly the shape that
        // would otherwise put the layout on the releasing thread's stack budget.
        var queue = FrameQueue<Node>(bestFirst: budget.isBounded)
        queue.push(Frame(node: tree, rect: viewportRect, depth: 0, boxIndex: 0, sequence: 0))
        var sequence = 1
        var scratch = LayoutScratch<Node>()
        // Boxes that carry a fill. The root is one until something tiles it;
        // every subdivision then trades one for the placements it produced.
        var filledBoxCount = 1

        while let frame = queue.pop() {
            guard !shouldCancel() else { return nil }
            // The budget is checked *before* a directory is read, never after:
            // reading is the cost, and a region that stays shut costs nothing
            // beyond the one box it already has.
            if let cap = budget.visibleBoxes, filledBoxCount >= cap {
                statistics.reachedBoxBudget = true
                statistics.unopenedBoxCount = queue.count + 1
                break
            }
            guard frame.rect.width > 0, frame.rect.height > 0 else { continue }

            guard let children = PreparedTree.children(of: frame.node, shouldCancel: shouldCancel) else {
                return nil
            }
            statistics.preparedChildCount += children.count
            guard !children.isEmpty else { continue }
            statistics.visitedDirectoryCount += 1

            guard let placed = placeChildren(
                children,
                in: frame.rect,
                allowance: budget.allowance(forRect: frame.rect, viewportArea: viewportArea),
                statistics: &statistics,
                scratch: &scratch,
                shouldCancel: shouldCancel
            ) else { return nil }
            guard !placed.placements.isEmpty else { continue }

            boxes[frame.boxIndex].isSubdivided = true
            filledBoxCount += placed.placements.count - 1

            var descend: [Frame<Node>] = []
            descend.reserveCapacity(placed.placements.count)
            for placement in placed.placements {
                switch placement {
                case .child(let childIndex, let rect):
                    let child = children[childIndex]
                    let index = boxes.count
                    boxes.append(
                        TreemapBox(
                            content: .node(child.node),
                            frame: rect,
                            depth: frame.depth + 1,
                            parentIndex: frame.boxIndex,
                            bytes: child.bytes,
                            isSubdivided: false
                        )
                    )
                    descend.append(
                        Frame(
                            node: child.node,
                            rect: rect,
                            depth: frame.depth + 1,
                            boxIndex: index,
                            sequence: sequence
                        )
                    )
                    sequence += 1
                case .aggregate(let rect):
                    statistics.aggregateBoxCount += 1
                    statistics.mergedItemCount += placed.mergedItems
                    statistics.mergedBytes += placed.mergedBytes
                    boxes.append(
                        TreemapBox(
                            content: .aggregate(
                                TreemapAggregate(
                                    mergedRoots: placed.merged.map { children[$0].node },
                                    bytes: placed.mergedBytes,
                                    itemCount: placed.mergedItems
                                )
                            ),
                            frame: rect,
                            depth: frame.depth + 1,
                            parentIndex: frame.boxIndex,
                            bytes: placed.mergedBytes,
                            isSubdivided: false
                        )
                    )
                }
            }
            queue.push(children: descend)
        }

        for box in boxes {
            if box.isSubdivided {
                statistics.subdividedBoxCount += 1
            } else {
                statistics.visibleBoxCount += 1
                statistics.coveredArea += box.frame.area
            }
        }

        return TreemapLayoutResult(viewport: viewport, boxes: boxes, statistics: statistics)
    }

    // MARK: - The merge fixpoint (spec §6.2)

    /// Placements name their children by **index** into the directory's own
    /// prepared array. The fixpoint has to track which children survived a
    /// round, and an index does that without the class instance the engine used
    /// to allocate per node just to have an `ObjectIdentifier` to put in a set.
    private enum Placement<Node: TreemapInputNode> {
        case child(Int, TreemapRect)
        case aggregate(TreemapRect)
    }

    private struct PlacedChildren<Node: TreemapInputNode> {
        let placements: [Placement<Node>]
        let merged: [Int]
        let mergedBytes: Int64
        let mergedItems: Int
    }

    /// Capacity retained across directories and merge rounds in one layout.
    /// The old path allocated six proportional arrays for every opened folder;
    /// a wide, shallow volume therefore spent much of relayout in ARC/malloc.
    private struct LayoutScratch<Node: TreemapInputNode> {
        var survivors: [Int] = []
        var merged: [Int] = []
        var slivers: [Int] = []
        var weights: [Double] = []
        var rects: [TreemapRect] = []
        var placements: [Placement<Node>] = []
    }

    /// Squarify → merge slivers → re-squarify, until nothing is a sliver.
    ///
    /// A single pass cannot do this: it reasons about *area*, and a child with
    /// ample area can still land as a 0.5 pt strip. One correction pass does
    /// not converge either — ticket 01 measured 25 slivers left on the flat
    /// 2,500-item fixture. Iterating does, because merging only ever removes
    /// children, and the survivors it repacks are strictly fewer each round.
    ///
    /// The merged children's bytes and item counts accumulate as they fold, so
    /// each folded child is asked for its item count exactly once across all
    /// the rounds — which matters, because for a conformer without a maintained
    /// count that question is a subtree walk.
    private static func placeChildren<Node: TreemapInputNode>(
        _ children: [PreparedChild<Node>],
        in rect: TreemapRect,
        allowance: Int?,
        statistics: inout TreemapLayoutStatistics,
        scratch: inout LayoutScratch<Node>,
        shouldCancel: () -> Bool
    ) -> PlacedChildren<Node>? {
        scratch.survivors.removeAll(keepingCapacity: true)
        scratch.survivors.append(contentsOf: children.indices)
        scratch.merged.removeAll(keepingCapacity: true)
        scratch.slivers.removeAll(keepingCapacity: true)
        var mergedBytes: Int64 = 0
        var mergedItems = 0

        // The allowance, applied **before** the first squarify rather than
        // after it: a directory of 100,000 children in a region that may draw
        // 40 has no business being tiled 100,000 ways first. Children arrive
        // sorted bytes-descending (§6.1), so the tail is the smallest of them,
        // which is the same end of the directory the sliver rule takes.
        if let allowance, scratch.survivors.count > allowance {
            statistics.budgetFoldedChildCount += scratch.survivors.count - allowance
            for offset in allowance..<scratch.survivors.count {
                if offset & 255 == 0, shouldCancel() { return nil }
                let childIndex = scratch.survivors[offset]
                scratch.merged.append(childIndex)
                mergedBytes += children[childIndex].bytes
                mergedItems += children[childIndex].node.treemapPresentedItemCount
            }
            scratch.survivors.removeSubrange(allowance...)
        }

        for round in 1...TreemapMetrics.mergeRoundCap {
            guard !shouldCancel() else { return nil }
            pack(
                children, survivors: scratch.survivors, hasMerged: !scratch.merged.isEmpty,
                mergedBytes: mergedBytes, in: rect, statistics: &statistics, scratch: &scratch
            )

            scratch.slivers.removeAll(keepingCapacity: true)
            for (offset, placement) in scratch.placements.enumerated() {
                if offset & 255 == 0, shouldCancel() { return nil }
                guard case .child(let childIndex, let frame) = placement else { continue }
                if frame.width < TreemapMetrics.mergeThresholdPoints
                    || frame.height < TreemapMetrics.mergeThresholdPoints {
                    scratch.slivers.append(childIndex)
                }
            }

            if scratch.slivers.isEmpty {
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round)
                return PlacedChildren(
                    placements: scratch.placements, merged: scratch.merged,
                    mergedBytes: mergedBytes, mergedItems: mergedItems
                )
            }
            if round == TreemapMetrics.mergeRoundCap {
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round)
                statistics.reachedRoundCap = true
                return PlacedChildren(
                    placements: scratch.placements, merged: scratch.merged,
                    mergedBytes: mergedBytes, mergedItems: mergedItems
                )
            }

            // Placements preserve survivor order, so slivers are ordered too.
            // Compact survivors in place instead of allocating a Set plus a
            // filtered array on every fixpoint round.
            var sliverOffset = 0
            var survivorWriteOffset = 0
            for (offset, childIndex) in scratch.survivors.enumerated() {
                if offset & 255 == 0, shouldCancel() { return nil }
                if sliverOffset < scratch.slivers.count,
                   scratch.slivers[sliverOffset] == childIndex {
                    scratch.merged.append(childIndex)
                    mergedBytes += children[childIndex].bytes
                    mergedItems += children[childIndex].node.treemapPresentedItemCount
                    sliverOffset += 1
                } else {
                    scratch.survivors[survivorWriteOffset] = childIndex
                    survivorWriteOffset += 1
                }
            }
            scratch.survivors.removeSubrange(survivorWriteOffset...)

            if scratch.survivors.isEmpty {
                // Everything folded: the aggregate is the directory's whole
                // rectangle, which is the truthful picture of a region too
                // small to resolve.
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round + 1)
                pack(
                    children, survivors: [], hasMerged: true,
                    mergedBytes: mergedBytes, in: rect,
                    statistics: &statistics, scratch: &scratch
                )
                return PlacedChildren(
                    placements: scratch.placements, merged: scratch.merged,
                    mergedBytes: mergedBytes, mergedItems: mergedItems
                )
            }
        }
        return PlacedChildren(
            placements: scratch.placements, merged: scratch.merged,
            mergedBytes: mergedBytes, mergedItems: mergedItems
        )
    }

    /// One squarify pass over the survivors with the aggregate, if any, pinned
    /// **last** in child order.
    ///
    /// §6.1 fixes child order for real children and is silent on the aggregate.
    /// Ticket 01 chose last over sorted-by-combined-bytes because it settles the
    /// packing in 2 rounds instead of 5 — both are deterministic, so both
    /// satisfy the golden-rectangle requirement; only one could be the rule.
    private static func pack<Node: TreemapInputNode>(
        _ children: [PreparedChild<Node>],
        survivors: [Int],
        hasMerged: Bool,
        mergedBytes: Int64,
        in rect: TreemapRect,
        statistics: inout TreemapLayoutStatistics,
        scratch: inout LayoutScratch<Node>
    ) {
        scratch.weights.removeAll(keepingCapacity: true)
        scratch.weights.reserveCapacity(survivors.count + (hasMerged ? 1 : 0))
        for survivor in survivors {
            scratch.weights.append(Double(children[survivor].bytes))
        }
        if hasMerged {
            scratch.weights.append(Double(mergedBytes))
        }

        statistics.squarifyPasses += 1
        SquarifiedLayout.tile(weights: scratch.weights, in: rect, into: &scratch.rects)
        scratch.placements.removeAll(keepingCapacity: true)
        guard scratch.rects.count == scratch.weights.count else { return }

        scratch.placements.reserveCapacity(scratch.rects.count)
        for (index, frame) in scratch.rects.enumerated() {
            if index < survivors.count {
                scratch.placements.append(.child(survivors[index], frame))
            } else {
                scratch.placements.append(.aggregate(frame))
            }
        }
    }

    private struct Frame<Node: TreemapInputNode> {
        let node: Node
        let rect: TreemapRect
        let depth: Int
        let boxIndex: Int
        /// Creation order, and so the walk's tie-break. Two frames of exactly
        /// equal area must still have one settled order, or a budget would cut
        /// the map in a different place from one run to the next.
        let sequence: Int
    }

    /// Where the walk goes next.
    ///
    /// Unbudgeted this is the LIFO stack the layout has always used — children
    /// pushed reversed, so the draw list comes out parents first and siblings
    /// in layout order — and the box order is unchanged from before budgets
    /// existed.
    ///
    /// Budgeted it is a max-heap on rectangle area, because a cap has to be
    /// spent on what the eye actually reads. Depth-first would hand the whole
    /// budget to whichever branch happened to be walked first and leave the
    /// rest of the volume as one flat block; largest-first resolves the map
    /// evenly and degrades from the bottom, which is the same direction the
    /// merge rule already degrades in. Parents are still appended to the draw
    /// list before their children — a child frame is only ever created while
    /// its parent's box exists — so the containment invariant §6.4 hit testing
    /// relies on holds in both modes; only sibling order across the array
    /// differs, and nothing reads that.
    private struct FrameQueue<Node: TreemapInputNode> {
        private var frames: [Frame<Node>] = []
        private let bestFirst: Bool

        init(bestFirst: Bool) {
            self.bestFirst = bestFirst
        }

        var count: Int { frames.count }

        mutating func push(_ frame: Frame<Node>) {
            frames.append(frame)
            if bestFirst { siftUp(from: frames.count - 1) }
        }

        /// One directory's children at once.
        mutating func push(children: [Frame<Node>]) {
            if bestFirst {
                for frame in children { push(frame) }
            } else {
                frames.append(contentsOf: children.reversed())
            }
        }

        mutating func pop() -> Frame<Node>? {
            guard !frames.isEmpty else { return nil }
            guard bestFirst else { return frames.removeLast() }
            frames.swapAt(0, frames.count - 1)
            let top = frames.removeLast()
            if !frames.isEmpty { siftDown(from: 0) }
            return top
        }

        private func precedes(_ a: Frame<Node>, _ b: Frame<Node>) -> Bool {
            let left = a.rect.area
            let right = b.rect.area
            if left != right { return left > right }
            return a.sequence < b.sequence
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(frames[child], frames[parent]) else { return }
                frames.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var winner = parent
                if left < frames.count, precedes(frames[left], frames[winner]) { winner = left }
                if right < frames.count, precedes(frames[right], frames[winner]) { winner = right }
                guard winner != parent else { return }
                frames.swapAt(parent, winner)
                parent = winner
            }
        }
    }
}
