import Foundation

/// What a node is. Packages are directories that are measured through, but
/// presented collapsed (spec §3.4) — the engine builds their real children.
public enum NodeKind: Sendable, Equatable {
    case directory
    case package
    case file
    case symbolicLink
    case other
}

/// How a node's bytes are attributed (spec §3.4).
///
/// There is no case for a remote-only cloud placeholder: those are **omitted**
/// from the tree entirely and counted as exclusions instead, so no node ever
/// carries that state (spec §3.4).
public enum Attribution: Sendable, Equatable {
    /// This node owns the bytes it reports.
    case owned
    /// The same inode was already counted at another in-scope path. Zero
    /// attributed bytes, still visible, with the owning path so the UI can say
    /// where the bytes went.
    ///
    /// `owner` is optional because the spec promises the owning path only
    /// *when available*; this engine always has it, because the owner is a node
    /// it is still holding.
    case hardLinkElsewhere(owner: [String]?)
}

/// Whether what a node reports is the whole truth (spec §3.5).
public enum ReadState: Sendable, Equatable {
    /// Everything under this node was read.
    case complete
    /// Something beneath it could not be read, or the scan was cancelled while
    /// it was still open. Its total is a floor, not an exact figure.
    case incomplete
    /// This entry itself could not be read. Its size is **not** guessed.
    case unreadable
}

/// One discovered filesystem entry.
///
/// **Name-only.** A node stores its last path component, not an absolute URL —
/// at millions of nodes the paths would dominate memory. The absolute URL for
/// Open/Reveal/inspector is rebuilt from the parent chain on demand, off the
/// hot path (spec §5.2, §8.4).
///
/// **Freeze discipline.** A node is *open* while it or its subtree is still
/// being built and *frozen* once its listing is exhausted and its children are
/// frozen. A frozen node never mutates again, which is what makes it safe to
/// share a frozen subtree by reference into a snapshot instead of deep-copying
/// it (spec §5.2). That discipline — not the type system — is why this class
/// is `@unchecked Sendable`: the actor-side scan mutates only open nodes, and
/// only frozen nodes ever cross to the UI side.
///
/// **Lifetime.** `parent` is `unowned`: the tree owns its children downward, so
/// holding the root (as `ScanResult` and `TreeSnapshot` both do) keeps every
/// node's parent chain alive. Hold the root, not a bare descendant.
public final class ScanNode: @unchecked Sendable {
    /// Last path component only.
    public let name: String
    public let kind: NodeKind
    public private(set) unowned var parent: ScanNode?
    public private(set) var children: [ScanNode]

    /// This entry's own logical `fileSizeKey` bytes. Zero for directories,
    /// symlinks and anything whose size could not be read.
    public private(set) var ownBytes: Int64
    /// `ownBytes` plus every descendant's — rolled up incrementally, so this
    /// is live and correct at every instant during the scan (spec §3.1).
    public private(set) var subtreeBytes: Int64
    /// Regular files in this subtree, `1` for a regular file itself.
    public private(set) var fileCount: Int64

    public private(set) var attribution: Attribution
    public private(set) var readState: ReadState
    /// `true` once this node and its subtree are final and immutable.
    public private(set) var isFrozen: Bool

    init(name: String, kind: NodeKind, parent: ScanNode?) {
        self.name = name
        self.kind = kind
        self.parent = parent
        self.children = []
        self.ownBytes = 0
        self.subtreeBytes = 0
        self.fileCount = 0
        self.attribution = .owned
        self.readState = .complete
        self.isFrozen = false
    }

    // MARK: - Reading

    /// This node's path components, root first, this node last.
    public func pathComponents() -> [String] {
        var components: [String] = []
        var node: ScanNode? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        return components.reversed()
    }

    /// Rebuilds this node's absolute URL from the scan root's URL and the
    /// parent chain. O(depth), and only ever called on a user action.
    public func url(root rootURL: URL) -> URL {
        let components = pathComponents().dropFirst()
        var url = rootURL
        for component in components {
            url.appendPathComponent(component)
        }
        return url
    }

    /// Whether this node can hold children at all.
    public var isDirectoryLike: Bool {
        kind == .directory || kind == .package
    }

    /// The children a view shows before the user drills in.
    ///
    /// A package is **measured through** during the scan — its real children
    /// are right here and its aggregate is already exact — but it presents as
    /// one collapsed item and one treemap box until the user expands it
    /// (spec §3.4). Materializing that hierarchy later is a presentation
    /// change; because the bytes were counted at scan time, it cannot move the
    /// aggregate.
    public var initiallyPresentedChildren: [ScanNode] {
        kind == .package ? [] : children
    }

    // MARK: - Mutation (scan-side only, always on an open node)

    func appendChild(_ child: ScanNode) {
        children.append(child)
    }

    func attribute(ownBytes bytes: Int64, isRegularFile: Bool) {
        ownBytes = bytes
        subtreeBytes = bytes
        fileCount = isRegularFile ? 1 : 0
    }

    /// Adds a leaf's contribution to this ancestor. The roll-up walks the
    /// whole parent chain, which is what keeps every open directory's total
    /// live (spec §3.1).
    func accumulate(bytes: Int64, files: Int64) {
        subtreeBytes += bytes
        fileCount += files
    }

    /// Records that this name's bytes were already counted at `owner`. The node
    /// keeps its place in the tree and its zero attributed bytes (spec §3.4).
    func markHardLinkElsewhere(owner: [String]?) {
        attribution = .hardLinkElsewhere(owner: owner)
    }

    func markUnreadable() {
        readState = .unreadable
    }

    func markIncomplete() {
        if readState == .complete {
            readState = .incomplete
        }
    }

    func freeze() {
        isFrozen = true
    }

    // MARK: - Snapshots

    /// Builds an immutable view of this subtree.
    ///
    /// A frozen node is returned **as-is, shared by reference** — no copy, no
    /// walk. Only the still-open spine (root → the directory being listed) is
    /// copied, carrying its current partial totals. Cost is therefore O(spine
    /// depth + the open nodes' child arrays), never O(total nodes), which is
    /// what makes a 4 Hz tree feed affordable on a million-node scan
    /// (spec §5.2).
    func frozenSnapshot(parent snapshotParent: ScanNode?) -> ScanNode {
        if isFrozen { return self }
        let copy = ScanNode(name: name, kind: kind, parent: snapshotParent)
        copy.ownBytes = ownBytes
        copy.subtreeBytes = subtreeBytes
        copy.fileCount = fileCount
        copy.attribution = attribution
        copy.readState = readState
        copy.children = children.map { $0.frozenSnapshot(parent: copy) }
        copy.isFrozen = true
        return copy
    }
}
