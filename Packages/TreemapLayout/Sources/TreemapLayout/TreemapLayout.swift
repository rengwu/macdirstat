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

        let prepared = PreparedTree(root: tree)
        statistics.placedNodeCount = prepared.root.itemCount

        let viewportRect = TreemapRect(origin: TreemapPoint(x: 0, y: 0), size: viewport)
        var boxes: [TreemapBox<Node>] = []
        boxes.reserveCapacity(prepared.nodeCount)
        boxes.append(
            TreemapBox(
                content: .node(prepared.root.node),
                frame: viewportRect,
                depth: 0,
                parentIndex: nil,
                bytes: prepared.root.bytes,
                isSubdivided: false
            )
        )

        // Explicit stack rather than recursion: depth is the tree's, and the
        // deep-chain rung of the workload ladder is exactly the shape that
        // would otherwise put the layout on the releasing thread's stack budget.
        var stack: [Frame<Node>] = [Frame(node: prepared.root, rect: viewportRect, depth: 0, boxIndex: 0)]

        while let frame = stack.popLast() {
            guard !frame.node.children.isEmpty, frame.rect.width > 0, frame.rect.height > 0 else { continue }

            let placements = placeChildren(frame.node.children, in: frame.rect, statistics: &statistics)
            guard !placements.isEmpty else { continue }

            boxes[frame.boxIndex].isSubdivided = true

            var descend: [Frame<Node>] = []
            descend.reserveCapacity(placements.count)
            for placement in placements {
                switch placement {
                case .child(let child, let rect):
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
                    descend.append(Frame(node: child, rect: rect, depth: frame.depth + 1, boxIndex: index))
                case .aggregate(let merged, let bytes, let itemCount, let rect):
                    statistics.aggregateBoxCount += 1
                    statistics.mergedItemCount += itemCount
                    statistics.mergedBytes += bytes
                    boxes.append(
                        TreemapBox(
                            content: .aggregate(
                                TreemapAggregate(
                                    mergedRoots: merged.map { $0.node },
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

    private enum Placement<Node: TreemapInputNode> {
        case child(PreparedNode<Node>, TreemapRect)
        case aggregate(merged: [PreparedNode<Node>], bytes: Int64, itemCount: Int, rect: TreemapRect)
    }

    /// Squarify → merge slivers → re-squarify, until nothing is a sliver.
    ///
    /// A single pass cannot do this: it reasons about *area*, and a child with
    /// ample area can still land as a 0.5 pt strip. One correction pass does
    /// not converge either — ticket 01 measured 25 slivers left on the flat
    /// 2,500-item fixture. Iterating does, because merging only ever removes
    /// children, and the survivors it repacks are strictly fewer each round.
    private static func placeChildren<Node: TreemapInputNode>(
        _ children: [PreparedNode<Node>],
        in rect: TreemapRect,
        statistics: inout TreemapLayoutStatistics
    ) -> [Placement<Node>] {
        var survivors = children
        var merged: [PreparedNode<Node>] = []
        var placements: [Placement<Node>] = []

        for round in 1...TreemapMetrics.mergeRoundCap {
            placements = pack(survivors: survivors, merged: merged, in: rect, statistics: &statistics)

            var slivers = Set<ObjectIdentifier>()
            for placement in placements {
                guard case .child(let child, let frame) = placement else { continue }
                if frame.width < TreemapMetrics.mergeThresholdPoints
                    || frame.height < TreemapMetrics.mergeThresholdPoints {
                    slivers.insert(ObjectIdentifier(child))
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

            merged.append(contentsOf: survivors.filter { slivers.contains(ObjectIdentifier($0)) })
            survivors.removeAll { slivers.contains(ObjectIdentifier($0)) }

            if survivors.isEmpty {
                // Everything folded: the aggregate is the directory's whole
                // rectangle, which is the truthful picture of a region too
                // small to resolve.
                statistics.maximumMergeRounds = max(statistics.maximumMergeRounds, round + 1)
                return pack(survivors: [], merged: merged, in: rect, statistics: &statistics)
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
        survivors: [PreparedNode<Node>],
        merged: [PreparedNode<Node>],
        in rect: TreemapRect,
        statistics: inout TreemapLayoutStatistics
    ) -> [Placement<Node>] {
        var weights = survivors.map { Double($0.bytes) }

        var mergedBytes: Int64 = 0
        var mergedItems = 0
        if !merged.isEmpty {
            for node in merged {
                mergedBytes += node.bytes
                mergedItems += node.itemCount
            }
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
        let node: PreparedNode<Node>
        let rect: TreemapRect
        let depth: Int
        let boxIndex: Int
    }
}
