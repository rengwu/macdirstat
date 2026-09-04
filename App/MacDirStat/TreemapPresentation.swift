import AppKit
import ScanCore
import TreemapLayout

/// Which packages the user has drilled into.
///
/// Package drill-in is *presentation*, not structure (ticket 01, decision 2):
/// expanding a package in the tree subdivides its treemap box exactly like a
/// folder, and the outer rectangle's area never changes because the bytes were
/// already counted at scan time. `ScanNode` is the engine's and carries no
/// presentation state, so the expansion set lives beside it and the adapter
/// reads both.
///
/// Used from the main actor only, and read through an immutable
/// ``PackageExpansionSet`` — never directly — because the layout that reads it
/// runs off the main thread.
final class PackageExpansion {
    private var expanded: Set<ObjectIdentifier> = []
    private let childOrder = TreemapChildOrderCache()
    /// Bumped on every change, so the view can tell "same tree, same viewport,
    /// different drill-in" from "nothing changed" without diffing the set.
    private(set) var generation = 0

    init() {}

    func isExpanded(_ node: ScanNode) -> Bool {
        expanded.contains(ObjectIdentifier(node))
    }

    func setExpanded(_ isExpanded: Bool, for node: ScanNode) {
        let identifier = ObjectIdentifier(node)
        let changed = isExpanded ? expanded.insert(identifier).inserted : expanded.remove(identifier) != nil
        if changed { generation += 1 }
    }

    func reset() {
        childOrder.removeAll()
        if !expanded.isEmpty {
            expanded.removeAll()
            generation += 1
        }
    }

    /// The drill-in state as of now, frozen so a background layout can read it
    /// without racing the click that changes it. A handful of identifiers at
    /// most: nobody drills into a thousand packages.
    func snapshot() -> PackageExpansionSet {
        PackageExpansionSet(expanded: expanded, childOrder: childOrder)
    }
}

/// Sorted child arrays belong to the immutable scan tree, not to a viewport.
/// Keeping them across resize/layout requests removes the same O(k log k)
/// preparation work from every opened directory after its first appearance.
private final class TreemapChildOrderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObjectIdentifier: [ScanNode]] = [:]

    func children(of node: ScanNode) -> [ScanNode] {
        let identifier = ObjectIdentifier(node)
        lock.lock()
        if let cached = storage[identifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let ordered = node.children.enumerated().sorted { left, right in
            let lhs = left.element
            let rhs = right.element
            if lhs.subtreeDiskBytes != rhs.subtreeDiskBytes {
                return lhs.subtreeDiskBytes > rhs.subtreeDiskBytes
            }
            if !lhs.name.unicodeScalars.elementsEqual(rhs.name.unicodeScalars) {
                return lhs.name.unicodeScalars.lexicographicallyPrecedes(rhs.name.unicodeScalars) {
                    $0.value < $1.value
                }
            }
            return left.offset < right.offset
        }.map(\.element)

        lock.lock()
        if let cached = storage[identifier] {
            lock.unlock()
            return cached
        }
        storage[identifier] = ordered
        lock.unlock()
        return ordered
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// One frozen reading of which packages are drilled into.
struct PackageExpansionSet: Sendable {
    let expanded: Set<ObjectIdentifier>
    fileprivate let childOrder: TreemapChildOrderCache

    func isExpanded(_ node: ScanNode) -> Bool {
        expanded.contains(ObjectIdentifier(node))
    }
}

/// `ScanCore`'s tree, seen through `TreemapLayout`'s seam.
///
/// The two packages do not know about each other (spec §4.2, §10); this value
/// type is the whole of the adapter, and it lives in the app because only the
/// app knows the presentation policy — which packages are drilled into.
///
/// `Sendable`, and that is load-bearing: the scan is finished with its tree
/// before the app ever sees it, and the expansion set is a value, so a whole
/// tree can be handed to a background layout without the scan and the layout
/// ever touching the same memory.
struct TreemapNodeRef: TreemapInputNode, Sendable {
    let node: ScanNode
    let expansion: PackageExpansionSet

    var treemapName: String { node.name }

    var treemapKind: TreemapEntryKind {
        switch node.kind {
        case .directory: return .directory
        case .package: return .package
        case .file: return .file
        case .symbolicLink: return .symbolicLink
        case .other: return .other
        }
    }

    var treemapReadState: TreemapReadState {
        switch node.readState {
        case .complete: return .complete
        case .incomplete: return .incomplete
        case .unreadable: return .unreadable
        }
    }

    /// The subtree total, which is what the seam asks for — a collapsed package
    /// reports its whole measured content while presenting no children at all.
    var treemapAttributedBytes: Int64 { node.subtreeDiskBytes }

    var treemapPresentedChildren: [TreemapNodeRef] {
        guard isDrilledInto else { return [] }
        return expansion.childOrder.children(of: node).map {
            TreemapNodeRef(node: $0, expansion: expansion)
        }
    }

    @discardableResult
    func treemapForEachPresentedChild(_ visit: (TreemapNodeRef) -> Bool) -> Bool {
        guard isDrilledInto else { return true }
        for child in expansion.childOrder.children(of: node) {
            guard visit(TreemapNodeRef(node: child, expansion: expansion)) else { return false }
        }
        return true
    }

    var treemapPresentedChildrenAreInLayoutOrder: Bool { true }

    /// Constant time, because `ScanCore` rolls this count up as it scans. It is
    /// what lets the layout fold a subtree away and still say exactly how many
    /// entries it hid, without opening it (spec §6.2, ticket 14).
    var treemapPresentedItemCount: Int {
        guard isDrilledInto else { return node.subtreeDiskBytes > 0 ? 1 : 0 }
        return node.attributedNodeCount
    }

    /// A package presents as one box until the user drills in (spec §3.4);
    /// everything else presents what it holds.
    private var isDrilledInto: Bool {
        node.kind != .package || expansion.isExpanded(node)
    }
}

extension TreemapColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}

extension NSAppearance {
    /// Which half of the palette this appearance asks for (spec §6.3).
    var treemapAppearance: TreemapAppearance {
        let match = bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }
}

/// The classic-flat chrome the palette does not own: the colours that are
/// properties of the *drawing*, not of a kind.
///
/// They are gathered here rather than spread through `draw(_:)` so the
/// light/dark bitmap regressions have one place to read them from, and so the
/// treemap and the status-bar legend cannot drift apart.
enum TreemapChrome {
    static func voidBackground(_ appearance: TreemapAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1)
            : NSColor(srgbRed: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE8 / 255, alpha: 1)
    }

    /// The 0.5 pt hairline between sibling leaves (spec §6.1).
    static func siblingHairline(_ appearance: TreemapAppearance) -> NSColor {
        NSColor(white: 0, alpha: appearance == .dark ? 0.55 : 0.20)
    }

    /// The 1 pt per-depth directory outline (spec §6.1, capped at 3 levels).
    static func directoryOutline(_ appearance: TreemapAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(white: 1, alpha: 0.30)
            : NSColor(white: 0, alpha: 0.34)
    }

    /// The red diagonal hatch marking an Incomplete region (spec §6.3). Text
    /// carries the same fact in the tree and inspector, so the hatch is never
    /// the only channel.
    static func incompleteHatch(_ appearance: TreemapAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(srgbRed: 1, green: 105 / 255, blue: 97 / 255, alpha: 0.75)
            : NSColor(srgbRed: 208 / 255, green: 52 / 255, blue: 44 / 255, alpha: 0.70)
    }

    /// The 1 pt hover stroke (spec §6.3), high-contrast against either palette.
    static func hoverStroke(_ appearance: TreemapAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(white: 1, alpha: 0.95)
            : NSColor(white: 0, alpha: 0.85)
    }

    static let labelHalo = NSColor(white: 0, alpha: 0.45)
    static let labelForeground = NSColor(white: 1, alpha: 0.96)

    /// Hatch geometry, shared by the merged fill and the incomplete overlay so
    /// the two read as the same visual language at different colours.
    static let hatchSpacingPoints: CGFloat = 6
    static let hatchLineWidthPoints: CGFloat = 1.4

    /// A kind hue that follows the appearance, for the status-bar legend —
    /// which has to be the same colour the map drew, in either mode (§6.3).
    static func legendColor(for group: TreemapKindGroup) -> NSColor {
        NSColor(name: nil) { appearance in
            TreemapPalette.color(for: group, appearance: appearance.treemapAppearance).nsColor
        }
    }

    static var legendMergedColor: NSColor {
        NSColor(name: nil) { appearance in
            TreemapPalette.mergedBoxFillColor(appearance.treemapAppearance).nsColor
        }
    }
}
