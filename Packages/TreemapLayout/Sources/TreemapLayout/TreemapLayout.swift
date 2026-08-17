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

    /// Lays `tree` out in `viewport`.
    ///
    /// Every size change recomputes from scratch — no cache, no hysteresis,
    /// no animation (spec §6.4) — which is affordable precisely because this
    /// is bounded by *visible* boxes rather than by node count.
    public static func layout<Node: TreemapInputNode>(
        tree: Node,
        viewport: TreemapSize
    ) -> TreemapLayoutResult<Node> {
        var statistics = TreemapLayoutStatistics()
        guard viewport.isDrawable, tree.treemapAttributedBytes > 0 else {
            return TreemapLayoutResult(viewport: viewport, boxes: [], statistics: statistics)
        }

        // The one number the layout takes on the seam's word rather than by
        // walking: how many entries have a rectangle to lose. A conformer that
        // maintains it costs nothing here; the protocol's default walks.
        statistics.placedNodeCount = tree.treemapPresentedItemCount

        let viewportRect = TreemapRect(origin: TreemapPoint(x: 0, y: 0), size: viewport)
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

        // Explicit stack rather than recursion: depth is the tree's, and the
        // deep-chain rung of the workload ladder is exactly the shape that
        // would otherwise put the layout on the releasing thread's stack budget.
        var stack: [Frame<Node>] = [Frame(node: tree, rect: viewportRect, depth: 0, boxIndex: 0)]

        while let frame = stack.popLast() {
            guard frame.rect.width > 0, frame.rect.height > 0 else { continue }

            let children = PreparedTree.children(of: frame.node)
            statistics.preparedChildCount += children.count
            guard !children.isEmpty else { continue }
            statistics.visitedDirectoryCount += 1

            let placements = placeChildren(children, in: frame.rect, statistics: &statistics)
            guard !placements.isEmpty else { continue }

            boxes[frame.boxIndex].isSubdivided = true

            var descend: [Frame<Node>] = []
            descend.reserveCapacity(placements.count)
            for placement in placements {
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
                    descend.append(Frame(node: child.node, rect: rect, depth: frame.depth + 1, boxIndex: index))
                case .aggregate(let merged, let bytes, let itemCount, let rect):
                    statistics.aggregateBoxCount += 1
                    statistics.mergedItemCount += itemCount
                    statistics.mergedBytes += bytes
                    boxes.append(
                        TreemapBox(
                            content: .aggregate(
                                TreemapAggregate(
                                    mergedRoots: merged.map { children[$0].node },
                                    bytes: bytes,
                                    itemCount: itemCount
                                )
                            ),
                            frame: rect,
                            depth: frame.depth + 1,
                            parentIndex: frame.boxIndex,
                            bytes: bytes,
                            isSubdivided: false
                        )
                    )
                }
            }
            // Reversed, so a LIFO stack walks the children in layout order and
            // the draw list stays "parents first, then siblings in order".
            stack.append(contentsOf: descend.reversed())
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
        case aggregate(merged: [Int], bytes: Int64, itemCount: Int, rect: TreemapRect)
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
        statistics: inout TreemapLayoutStatistics
    ) -> [Placement<Node>] {
        var survivors = Array(children.indices)
        var merged: [Int] = []
        var mergedBytes: Int64 = 0
        var mergedItems = 0
        var placements: [Placement<Node>] = []

        for round in 1...TreemapMetrics.mergeRoundCap {
            placements = pack(
                children, survivors: survivors, merged: merged,
                mergedBytes: mergedBytes, mergedItems: mergedItems,
                in: rect, statistics: &statistics
            )

            var slivers: [Int] = []
            for placement in placements {
                guard case .child(let childIndex, let frame) = placement else { continue }
                if frame.width < TreemapMetrics.mergeThresholdPoints
                    || frame.height < TreemapMetrics.mergeThresholdPoints {
                    slivers.append(childIndex)
                }
            }

            if slivers.isEmpty {
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round)
                return placements
            }
            if round == TreemapMetrics.mergeRoundCap {
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round)
                statistics.reachedRoundCap = true
                return placements
            }

            let folding = Set(slivers)
            for childIndex in survivors where folding.contains(childIndex) {
                merged.append(childIndex)
                mergedBytes += children[childIndex].bytes
                mergedItems += children[childIndex].node.treemapPresentedItemCount
            }
            survivors.removeAll { folding.contains($0) }

            if survivors.isEmpty {
                // Everything folded: the aggregate is the directory's whole
                // rectangle, which is the truthful picture of a region too
                // small to resolve.
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round + 1)
                return pack(
                    children, survivors: [], merged: merged,
                    mergedBytes: mergedBytes, mergedItems: mergedItems,
                    in: rect, statistics: &statistics
                )
            }
        }
        return placements
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
        merged: [Int],
        mergedBytes: Int64,
        mergedItems: Int,
        in rect: TreemapRect,
        statistics: inout TreemapLayoutStatistics
    ) -> [Placement<Node>] {
        var weights = survivors.map { Double(children[$0].bytes) }
        if !merged.isEmpty {
            weights.append(Double(mergedBytes))
        }

        statistics.squarifyPasses += 1
        let rects = SquarifiedLayout.tile(weights: weights, in: rect)
        guard rects.count == weights.count else { return [] }

        var placements: [Placement<Node>] = []
        placements.reserveCapacity(rects.count)
        for (index, frame) in rects.enumerated() {
            if index < survivors.count {
                placements.append(.child(survivors[index], frame))
            } else {
                placements.append(
                    .aggregate(merged: merged, bytes: mergedBytes, itemCount: mergedItems, rect: frame)
                )
            }
        }
        return placements
    }

    private struct Frame<Node: TreemapInputNode> {
        let node: Node
        let rect: TreemapRect
        let depth: Int
        let boxIndex: Int
    }
}
