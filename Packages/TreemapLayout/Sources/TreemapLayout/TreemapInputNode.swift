import Foundation

/// What an entry is, for the two things the layout cares about: whether it can
/// carry a fill of its own, and which kind group its name classifies into.
///
/// This mirrors `ScanCore.NodeKind` without depending on it — the two packages
/// are siblings, and neither imports the other (spec §4.2, §10). The adapter
/// that bridges them lives in the app layer.
public enum TreemapEntryKind: Hashable, Sendable {
    case directory
    /// A bundle measured through but presented as one box until the user drills
    /// in (spec §3.4). Whether it is currently drilled into is expressed by
    /// ``TreemapInputNode/treemapPresentedChildren``, not by this case.
    case package
    case file
    case symbolicLink
    case other
}

/// Whether what an entry reports is the whole truth (spec §3.5), which the
/// treemap shows as the red diagonal hatch overlay (§6.3).
public enum TreemapReadState: Hashable, Sendable {
    case complete
    case incomplete
    case unreadable
}

/// The tree the layout reads.
///
/// Deliberately small: four scalars and the children, so nothing about the scan
/// engine — actors, snapshots, hard-link identity, diagnostics — has to be
/// visible here. Any tree that can answer these questions can be laid out.
///
/// **`treemapAttributedBytes` is a subtree total**, not the entry's own size:
/// it is the attributed logical bytes (spec §3.1) of this entry *and everything
/// presented beneath it*. A directory's value is therefore the sum of its
/// children's, and a collapsed package's is its whole measured content even
/// though it presents no children at all.
///
/// **`treemapPresentedChildren` is presentation, not structure.** A collapsed
/// package returns `[]` and is laid out as one leaf box; the same package
/// expanded returns its real children and subdivides — inside the identical
/// outer rectangle, because its byte total did not change. A conformer that
/// needs expansion state (which `ScanCore.ScanNode` alone cannot carry) wraps
/// the node in a value type that holds both.
///
/// Children are `[Self]` rather than an existential so the layout stays
/// specialized and allocation-free at the seam.
public protocol TreemapInputNode {
    /// Last path component. Used for the code-point tie-break in child order
    /// (spec §6.1) and for kind-group classification (§6.3).
    var treemapName: String { get }
    var treemapKind: TreemapEntryKind { get }
    var treemapReadState: TreemapReadState { get }
    /// Attributed logical bytes for this entry's whole presented subtree.
    /// Zero-attributed entries (empty files, symlinks, hard-link non-owners,
    /// unreadable entries of unknowable size) report `0` and get no rectangle.
    var treemapAttributedBytes: Int64 { get }
    var treemapPresentedChildren: [Self] { get }
}

/// A concrete tree for tests, previews, and any caller that already holds a
/// value tree. The production path conforms its own type instead — nothing in
/// the engine special-cases this one.
public struct TreemapTree: TreemapInputNode, Hashable, Sendable {
    public var name: String
    public var kind: TreemapEntryKind
    public var readState: TreemapReadState
    public var bytes: Int64
    public var children: [TreemapTree]

    /// A leaf. `bytes` is the entry's own size.
    public init(
        name: String,
        bytes: Int64,
        kind: TreemapEntryKind = .file,
        readState: TreemapReadState = .complete
    ) {
        self.name = name
        self.kind = kind
        self.readState = readState
        self.bytes = bytes
        self.children = []
    }

    /// A directory. Its bytes are its children's total, which is the invariant
    /// the scan engine already maintains (spec §3.1) — stating it here keeps
    /// fixtures from drifting out of that shape by hand.
    public init(
        directory name: String,
        kind: TreemapEntryKind = .directory,
        readState: TreemapReadState = .complete,
        children: [TreemapTree]
    ) {
        self.name = name
        self.kind = kind
        self.readState = readState
        self.bytes = children.reduce(0) { $0 + $1.bytes }
        self.children = children
    }

    /// A collapsed package: measured through, presenting no children (§3.4).
    public init(collapsedPackage name: String, bytes: Int64) {
        self.name = name
        self.kind = .package
        self.readState = .complete
        self.bytes = bytes
        self.children = []
    }

    public var treemapName: String { name }
    public var treemapKind: TreemapEntryKind { kind }
    public var treemapReadState: TreemapReadState { readState }
    public var treemapAttributedBytes: Int64 { bytes }
    public var treemapPresentedChildren: [TreemapTree] { children }
}
