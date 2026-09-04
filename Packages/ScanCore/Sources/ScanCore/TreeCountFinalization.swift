import Foundation

/// The root-level tallies the status line reads for a finished or cancelled
/// scan (§7.3), under **presentation semantics**: a package is one item and
/// nothing below it is counted separately.
///
/// Root-only on purpose. These two numbers describe the scan, not a node, and
/// nothing in the UI ever asks them of a subtree — so they are carried once
/// beside the tree rather than paid for on every node. Two more full-width
/// fields on a two-million-node tree would cost ~32 MiB to answer one line of
/// text.
public struct VisibleTreeTotals: Sendable, Equatable {
    /// Everything presented that is not a folder — files, symlinks, packages
    /// (a package is one item, presented collapsed) and anything else.
    public let files: Int
    /// Presented `.directory` entries. Packages are *not* folders here: the
    /// status line counts what the tree shows, and the tree shows a package as
    /// one item.
    public let folders: Int

    public static let zero = VisibleTreeTotals(files: 0, folders: 0)

    public init(files: Int, folders: Int) {
        self.files = files
        self.folders = folders
    }
}

/// The one pass that turns the finished tree's shape into the measures and
/// counts the UI reads in O(1).
///
/// **Why a separate pass at all.** The UI needs three different tallies of
/// *names* — the tree's Items column, the inspector's folder count, and the
/// status line's visible totals — and none of them is a byte fact, so none can
/// ride the scan's byte roll-up: that walk starts at leaves that carry bytes
/// and never visits an empty directory, a zero-byte file or a deduplicated
/// name. Computing them at draw time is what made a wide folder re-walk its
/// subtree once per row.
///
/// **Why here, and why now.** The tree is published exactly once, with the
/// terminal event, and is immutable from that moment on. That makes the
/// instant after traversal the only moment where one bounded O(total nodes)
/// pass on the scan's own thread can replace unbounded repeated passes on the
/// main actor.
enum TreeCountFinalization {
    /// One open node on the post-order walk: how far through its children we
    /// are, and the three sums its finished children have contributed.
    private struct Frame {
        let node: ScanNode
        var nextChild: Int
        /// ``ScanNode/presentedDescendantCount`` under construction.
        var presented: Int
        /// ``ScanNode/folderDescendantCount`` under construction.
        var folders: Int
        /// Presented `.directory` descendants. Transient — only the root's
        /// value is ever read, to split the presented total into files and
        /// folders — so it is a frame field and not a fourth node field.
        var presentedDirectories: Int
        /// The four subtree measures under construction. Leaves already carry
        /// their own values; directories receive each finished child's totals
        /// exactly once.
        var diskBytes: Int64
        var contentBytes: Int64
        var files: Int64
        var attributedNodes: Int

        init(_ node: ScanNode) {
            self.node = node
            self.nextChild = 0
            self.presented = 0
            self.folders = 0
            self.presentedDirectories = 0
            self.diskBytes = node.ownDiskBytes
            self.contentBytes = node.ownContentBytes
            self.files = node.fileCount
            self.attributedNodes = 0
        }
    }

    /// Finalizes every node's derived counts and returns the root's visible
    /// totals.
    ///
    /// Iterative, with an explicit `(node, cursor, sums)` frame per open node,
    /// for two reasons. Recursion would put filesystem depth on the Swift call
    /// stack, which this engine never does. And the textbook two-stack
    /// post-order recipe would allocate a second collection the size of the
    /// whole tree — at a root with a million children that is worse than the
    /// walks it replaces. Frames are O(depth); a leaf never gets one.
    ///
    /// Correct for a cancelled tree with no extra care: it folds the nodes that
    /// exist, and after cancellation the nodes that exist are exactly the ones
    /// the walk reached.
    @discardableResult
    static func finalize(_ root: ScanNode) -> VisibleTreeTotals {
        var stack: [Frame] = [Frame(root)]
        var rootPresented = 0
        var rootPresentedDirectories = 0

        while !stack.isEmpty {
            let top = stack.count - 1
            let children = stack[top].node.children

            if stack[top].nextChild < children.count {
                let child = children[stack[top].nextChild]
                stack[top].nextChild += 1
                if child.children.isEmpty {
                    // A leaf contributes itself and nothing below it, and its
                    // own counts are already the zeros `ScanNode.init` gave it.
                    // Opening a frame for it would double the walk's traffic on
                    // a tree that is mostly leaves.
                    stack[top].presented += 1
                    if child.isDirectoryLike {
                        // An ordinary leaf has no folder descendants. A fast-
                        // summarized package is also a leaf in the materialized
                        // tree, but carries the interior count measured by its
                        // aggregate pass.
                        stack[top].folders += 1 + child.folderDescendantCount
                    }
                    if child.kind == .directory { stack[top].presentedDirectories += 1 }
                    stack[top].diskBytes += child.subtreeDiskBytes
                    stack[top].contentBytes += child.subtreeContentBytes
                    stack[top].files += child.fileCount
                    stack[top].attributedNodes += child.attributedNodeCount
                } else {
                    stack.append(Frame(child))
                }
                continue
            }

            // Every child is folded in, so this node's sums are final.
            let frame = stack.removeLast()
            let attributedNodes = frame.attributedNodes + (frame.diskBytes > 0 ? 1 : 0)
            frame.node.finalizeSubtreeMeasures(
                diskBytes: frame.diskBytes,
                contentBytes: frame.contentBytes,
                files: frame.files,
                attributedNodes: attributedNodes
            )
            frame.node.finalizeDescendantCounts(presented: frame.presented, folders: frame.folders)

            guard let parent = stack.indices.last else {
                rootPresented = frame.presented
                rootPresentedDirectories = frame.presentedDirectories
                break
            }

            let node = frame.node
            // The three recurrences, each written once. They differ only in
            // what a package does: it stops the presented walk and it does not
            // stop the folder walk.
            let isPackage = node.kind == .package
            stack[parent].presented += 1 + (isPackage ? 0 : frame.presented)
            stack[parent].folders += (node.isDirectoryLike ? 1 : 0) + frame.folders
            stack[parent].presentedDirectories +=
                (node.kind == .directory ? 1 : 0) + (isPackage ? 0 : frame.presentedDirectories)
            stack[parent].diskBytes += node.subtreeDiskBytes
            stack[parent].contentBytes += node.subtreeContentBytes
            stack[parent].files += node.fileCount
            stack[parent].attributedNodes += node.attributedNodeCount
        }

        return VisibleTreeTotals(
            files: rootPresented - rootPresentedDirectories,
            folders: rootPresentedDirectories
        )
    }
}
