import Foundation

/// One child of one directory, normalized for layout.
///
/// A value, and only three fields wide. The engine used to build a whole
/// parallel tree of class instances before placing anything, which made every
/// relayout O(total nodes) and put a multi-second allocation walk on the main
/// thread at volume scale (ticket 14). Nothing here outlives the directory it
/// belongs to.
///
/// `itemCount` is deliberately absent: it is asked of the seam only for the
/// children that actually fold, because that is the only place it is used.
struct PreparedChild<Node: TreemapInputNode> {
    let node: Node
    let bytes: Int64
    let name: String
    /// Discovery position among its siblings, before sorting — the last
    /// tie-break, so the order is total even for duplicate name/size pairs and
    /// cannot depend on the sort algorithm's handling of equal elements.
    let ordinal: Int
}

/// The normalization the layout applies to one directory, on the way in.
///
/// It runs **when a directory is about to be subdivided**, never before: a
/// directory that folded into an aggregate, or that never had a rectangle at
/// all, is never asked for its children. That is the whole of the pruning —
/// the merge rule already guarantees no surviving box is under 2 pt on either
/// side, so the number of directories that get here is bounded by the viewport
/// and not by the tree.
enum PreparedTree<Node: TreemapInputNode> {
    /// `node`'s presented children, minus the ones with no area, in child
    /// order (spec §6.1).
    ///
    /// Zero attributed bytes means no area, so no rectangle and no subtree
    /// (spec §6.2). The entry stays in the tree view; it simply has nothing to
    /// draw.
    static func children(of node: Node, shouldCancel: () -> Bool = { false }) -> [PreparedChild<Node>]? {
        var prepared: [PreparedChild<Node>] = []
        var ordinal = 0
        let completed = node.treemapForEachPresentedChild { child in
            if ordinal & 255 == 0, shouldCancel() { return false }
            let bytes = child.treemapAttributedBytes
            guard bytes > 0 else { return true }
            prepared.append(
                PreparedChild(node: child, bytes: bytes, name: child.treemapName, ordinal: ordinal)
            )
            ordinal += 1
            return true
        }
        guard completed, !shouldCancel() else { return nil }
        if !node.treemapPresentedChildrenAreInLayoutOrder {
            prepared.sort(by: precedes)
        }
        return shouldCancel() ? nil : prepared
    }

    /// Child order (spec §6.1): **bytes descending, ties by name ascending in
    /// code-point order**, and finally by discovery position.
    ///
    /// Code-point order is compared over Unicode scalars rather than with
    /// `String <`, which orders by Unicode canonical equivalence: both are
    /// locale-independent and stable, but only one of them is what §6.1 says.
    /// The distinction can only ever move two siblings of *identical* size past
    /// each other, and only when their names differ in normalization.
    ///
    /// **The scanner does the same thing, and cannot share this code.**
    /// `ScanCore.NameOrder` orders one directory's entries by exactly this
    /// comparison, for a stronger reason: there the order decides which of
    /// several names for one inode owns its bytes, so a pair of names that are
    /// not the same name must never compare equal. The two packages are
    /// independent — `ScanCore` is Foundation-only and knows nothing of
    /// layout — so the rule is written twice on purpose, and each site names the
    /// other. Changing one without the other would make a treemap box and its
    /// tree row disagree about sibling order.
    ///
    /// Names are compared for equality by scalar too, and not with `String ==`,
    /// so that a decomposed and a precomposed spelling of one name are two
    /// names here as well — otherwise this comparison would claim code-point
    /// order and then hand canonically equivalent names to the ordinal
    /// tie-break.
    static func precedes(_ a: PreparedChild<Node>, _ b: PreparedChild<Node>) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        if !a.name.unicodeScalars.elementsEqual(b.name.unicodeScalars) {
            return a.name.unicodeScalars.lexicographicallyPrecedes(b.name.unicodeScalars) {
                $0.value < $1.value
            }
        }
        return a.ordinal < b.ordinal
    }
}
