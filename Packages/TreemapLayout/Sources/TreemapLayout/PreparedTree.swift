import Foundation

/// One entry of the tree, normalized for layout.
///
/// The input protocol is read exactly once per layout: zero-byte entries are
/// dropped, children are sorted, and item counts are rolled up, all before any
/// squarifying happens. The merge fixpoint re-packs a directory several times,
/// and it must see the same numbers and the same order every round.
///
/// A reference type so the fixpoint can track survivors by identity even when
/// two siblings have the same name and the same size.
final class PreparedNode<Node: TreemapInputNode> {
    let node: Node
    let name: String
    let bytes: Int64
    /// Discovery position among its siblings, before sorting — the last
    /// tie-break, so the order is total even for duplicate name/size pairs and
    /// cannot depend on the sort algorithm's handling of equal elements.
    let ordinal: Int
    var children: [PreparedNode<Node>] = []
    /// This entry plus every positive-byte entry beneath it.
    var itemCount = 1

    init(node: Node, ordinal: Int) {
        self.node = node
        self.name = node.treemapName
        self.bytes = node.treemapAttributedBytes
        self.ordinal = ordinal
    }
}

/// The whole normalized tree, built in one pass.
struct PreparedTree<Node: TreemapInputNode> {
    let root: PreparedNode<Node>
    let nodeCount: Int

    init(root inputRoot: Node) {
        let root = PreparedNode(node: inputRoot, ordinal: 0)

        // Breadth-first, so a parent always precedes its children in `flat` and
        // the reverse pass below is a valid bottom-up order. Iterative because
        // a 64-level rung — let alone a pathological chain — has no business
        // being bounded by the stack.
        var flat: [PreparedNode<Node>] = [root]
        var index = 0
        while index < flat.count {
            let current = flat[index]
            index += 1

            var ordinal = 0
            for child in current.node.treemapPresentedChildren {
                // Zero attributed bytes means no area, so no rectangle and no
                // subtree (spec §6.2). The entry stays in the tree view; it
                // simply has nothing to draw.
                guard child.treemapAttributedBytes > 0 else { continue }
                let prepared = PreparedNode(node: child, ordinal: ordinal)
                ordinal += 1
                current.children.append(prepared)
                flat.append(prepared)
            }
            current.children.sort(by: PreparedTree.precedes)
        }

        for node in flat.reversed() {
            var count = 1
            for child in node.children { count += child.itemCount }
            node.itemCount = count
        }

        self.root = root
        self.nodeCount = flat.count
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
    static func precedes(_ a: PreparedNode<Node>, _ b: PreparedNode<Node>) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        if !a.name.unicodeScalars.elementsEqual(b.name.unicodeScalars) {
            return a.name.unicodeScalars.lexicographicallyPrecedes(b.name.unicodeScalars) {
                $0.value < $1.value
            }
        }
        return a.ordinal < b.ordinal
    }
}
