import Foundation

/// One directory's merge bucket: the children that were too small to draw
/// individually, folded into exactly one box (spec §6.2).
///
/// It is honest about what it hides — `bytes` is the exact sum, never rounded
/// or estimated — and it is the *only* synthetic box the layout produces.
public struct TreemapAggregate<Node: TreemapInputNode> {
    /// The folded children, in the order they were merged (largest first
    /// within each round). Each is the root of a whole folded subtree, so a
    /// collectively-tiny directory appears here once, not once per descendant.
    public let mergedRoots: [Node]
    /// Exact sum of the folded subtrees' attributed bytes.
    public let bytes: Int64
    /// How many entries are folded in, counted recursively over everything
    /// that would otherwise have had a rectangle — the number the inspector
    /// reports as *"N items below individual size, combined X"*.
    ///
    /// Zero-attributed entries inside the folded subtrees are **not** counted:
    /// they had no rectangle to lose, merged or not, and they remain listed in
    /// the tree either way (spec §6.2).
    public let itemCount: Int

    public init(mergedRoots: [Node], bytes: Int64, itemCount: Int) {
        self.mergedRoots = mergedRoots
        self.bytes = bytes
        self.itemCount = itemCount
    }
}

/// What a box stands for.
public enum TreemapBoxContent<Node: TreemapInputNode> {
    case node(Node)
    case aggregate(TreemapAggregate<Node>)
}

/// One rectangle in the computed layout.
public struct TreemapBox<Node: TreemapInputNode> {
    public let content: TreemapBoxContent<Node>
    /// Unrounded points (spec §6.1). Snap with
    /// ``TreemapRect/snapped(toBackingScale:)`` at draw time only.
    public let frame: TreemapRect
    /// Levels below the root box, which is `0`.
    public let depth: Int
    /// Index into ``TreemapLayoutResult/boxes`` of the box this one sits
    /// inside; `nil` for the root.
    public let parentIndex: Int?
    /// Attributed bytes this box's area is proportional to.
    public let bytes: Int64
    /// Whether other boxes tile this one's interior. A subdivided box is a
    /// directory region: it carries no fill of its own and is not hit-testable
    /// in the map (spec §6.3, §6.4).
    public internal(set) var isSubdivided: Bool

    public var node: Node? {
        if case .node(let node) = content { return node }
        return nil
    }

    public var aggregate: TreemapAggregate<Node>? {
        if case .aggregate(let aggregate) = content { return aggregate }
        return nil
    }

    public var isAggregate: Bool { aggregate != nil }

    /// The kind group whose hue fills this box, or `nil` where §6.3 says there
    /// is no fill of its own: any subdivided region, any directory, and the
    /// aggregate (which takes the neutral merged fill instead).
    public var kindGroup: TreemapKindGroup? {
        guard !isSubdivided, let node = node else { return nil }
        guard node.treemapKind != .directory else { return nil }
        return TreemapPalette.group(forFileNamed: node.treemapName)
    }

    /// Whether the scan could see all of what this box measures — the red
    /// diagonal hatch overlay in §6.3.
    public var isIncomplete: Bool {
        guard let node = node else { return false }
        return node.treemapReadState != .complete
    }

    /// Whether the box is large enough to carry its 11 pt label (spec §6.3).
    /// Directory regions are unlabelled in the flat variant regardless.
    public var fitsLabel: Bool {
        !isSubdivided
            && frame.width >= TreemapMetrics.labelMinimumSize.width
            && frame.height >= TreemapMetrics.labelMinimumSize.height
    }

    /// Whether a click inside this box selects it. Exactly the boxes that carry
    /// a fill: leaves and aggregates (spec §6.4).
    public var isHitTestable: Bool { !isSubdivided }
}

/// What the layout cost and what it hid — enough for the status bar, and the
/// numbers the geometry tests assert bounds on.
public struct TreemapLayoutStatistics: Hashable, Sendable {
    /// Boxes that carry a fill: leaves plus aggregates. Relayout is bounded by
    /// this, not by total node count (spec §6.2).
    public var visibleBoxCount = 0
    /// Directory regions — boxes tiled by other boxes.
    public var subdividedBoxCount = 0
    /// At most one per directory, by construction.
    public var aggregateBoxCount = 0
    public var mergedItemCount = 0
    public var mergedBytes: Int64 = 0
    /// Entries with positive attributed bytes reachable through the presented
    /// tree, including the root. Read from the input seam
    /// (``TreemapInputNode/treemapPresentedItemCount``), not counted here: the
    /// layout never walks the whole tree.
    public var placedNodeCount = 0
    /// Entries the layout actually read from the seam — one per child of every
    /// directory it subdivided.
    ///
    /// This is the work a relayout does, and the number that makes §6.2's
    /// "bounded by rendered boxes" checkable rather than asserted: it is
    /// bounded by the boxes on screen and their siblings, and on a tree whose
    /// bulk is folded away it is a small fraction of ``placedNodeCount``.
    public var preparedChildCount = 0
    /// Directories that were subdivided, i.e. asked for their children at all.
    public var visitedDirectoryCount = 0
    /// Total area of the filled boxes. Equals the viewport area to within
    /// float drift, which is what "100% area truthfulness" means in points.
    public var coveredArea: Double = 0
    /// Squarify invocations — the merge fixpoint's real cost.
    public var squarifyPasses = 0
    /// The most rounds any one directory needed to settle.
    public var maximumMergeRounds = 0
    /// `true` if some directory hit ``TreemapMetrics/mergeRoundCap`` and was
    /// accepted with slivers still in it. Never observed on the ticket-01
    /// fixtures; if it ever trips, the layout is still area-truthful.
    public var reachedRoundCap = false

    /// The cap this layout ran under, or `nil` if it ran unbudgeted
    /// (``TreemapLayoutBudget``).
    public var boxBudget: Int?
    /// `true` if the budget actually bound — the walk stopped opening
    /// directories with frames still queued. False on any map that resolved
    /// inside its budget, which is every map small enough not to need one.
    public var reachedBoxBudget = false
    /// Regions left unopened when the budget bound. Each is on screen as one
    /// box at its exact attributed area; the directories among them are the
    /// regions this map does not resolve into their contents.
    public var unopenedBoxCount = 0
    /// Children folded into their directory's aggregate by the budget's
    /// per-directory allowance rather than by the 2×2 pt sliver rule. They are
    /// merged, not dropped: the aggregate reports their exact combined bytes
    /// and item count, exactly as §6.2 requires of every fold.
    public var budgetFoldedChildCount = 0
}

/// The result of laying a tree out in a viewport: a flat draw list plus the
/// hit test over it.
public struct TreemapLayoutResult<Node: TreemapInputNode> {
    public let viewport: TreemapSize
    /// Draw order: a box always precedes the boxes inside it (spec §6.4).
    public let boxes: [TreemapBox<Node>]
    public let statistics: TreemapLayoutStatistics

    public init(viewport: TreemapSize, boxes: [TreemapBox<Node>], statistics: TreemapLayoutStatistics) {
        self.viewport = viewport
        self.boxes = boxes
        self.statistics = statistics
    }

    /// The boxes that carry a fill — leaves and aggregates.
    public var filledBoxes: [TreemapBox<Node>] {
        boxes.filter { !$0.isSubdivided }
    }

    /// The directory regions that get a 1 pt outline: below the root, within
    /// the depth cap, and wide enough for the stroke to mean anything
    /// (§6.1 as amended by ticket 01).
    public var outlinedBoxes: [TreemapBox<Node>] {
        boxes.filter {
            $0.isSubdivided
                && $0.depth > 0
                && $0.depth <= TreemapMetrics.directoryOutlineMaximumDepth
                && $0.frame.shortestSide >= TreemapMetrics.directoryOutlineMinimumSidePoints
        }
    }

    /// The deepest rendered box containing `point`, or `nil` where nothing is
    /// drawn (spec §6.4).
    ///
    /// Subdivided directory regions are skipped: their interior belongs to
    /// their children, and a directory is selected from the tree. An aggregate
    /// interior returns the aggregate — it is one box, not the files inside it.
    /// Zero-byte entries have no rectangle and so are unreachable here, by
    /// design; the tree still lists them.
    public func box(at point: TreemapPoint) -> TreemapBox<Node>? {
        var best: TreemapBox<Node>?
        for box in boxes where !box.isSubdivided {
            guard box.frame.contains(point) else { continue }
            if let current = best, current.depth > box.depth { continue }
            best = box
        }
        return best
    }

    /// The node a click selects, or `nil` if the point is empty or lands on an
    /// aggregate (which is not a file — check ``box(at:)`` for that case).
    public func node(at point: TreemapPoint) -> Node? {
        box(at: point)?.node
    }
}

// A draw list is an immutable value once returned, so it may cross to whichever
// thread computed it — which is the point: ``TreemapLayoutCoordinator`` runs the
// layout off the main thread and hands the result back (ticket 14). The
// conformances are conditional because ``TreemapInputNode`` deliberately does
// not require `Sendable`: a conformer that is only ever touched on one thread
// stays legal, it simply cannot be laid out in the background.
extension TreemapAggregate: Sendable where Node: Sendable {}
extension TreemapBoxContent: Sendable where Node: Sendable {}
extension TreemapBox: Sendable where Node: Sendable {}
extension TreemapLayoutResult: Sendable where Node: Sendable {}
