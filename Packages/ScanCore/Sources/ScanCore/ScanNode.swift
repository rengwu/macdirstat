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
    /// This directory is a second path to a directory already walked at
    /// `owner` — an APFS firmlink graft, or any other re-entry. Its subtree was
    /// counted once, there; this name stays visible, weightless and unexpanded
    /// rather than disappearing, because the directory really is at this path
    /// (spec §3.3, §3.4).
    case directoryCountedElsewhere(owner: [String]?)
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
/// hot path.
///
/// **One tree, handed over once.** The scan builds the tree on its own thread
/// and mutates nothing after it emits `.finished`; the UI only ever sees it
/// after that. That hand-off — not the type system — is why this class is
/// `@unchecked Sendable`. Nothing here is shared between a mutating tree and a
/// published one, which is what used to make published percentages wrong and
/// selections crash.
///
/// **Lifetime.** `parent` is `unowned`: the tree owns its children downward, so
/// holding the root (as `ScanResult` does) keeps every node's parent chain
/// alive. Hold the root, not a bare descendant.
public final class ScanNode: @unchecked Sendable {
    /// Last path component only.
    public let name: String
    public let kind: NodeKind
    public private(set) unowned var parent: ScanNode?
    public private(set) var children: [ScanNode]

    /// This entry's own blocks on disk (`fileAllocatedSizeKey`) — **the
    /// measure** (spec §3.1). Zero for directories, symlinks, a second name for
    /// an inode already counted, and anything whose size could not be read.
    public private(set) var ownDiskBytes: Int64
    /// `ownDiskBytes` plus every descendant's — rolled up incrementally, so this
    /// is live and correct at every instant during the scan (spec §3.1). This
    /// is what the treemap draws, what the tree's Size column reads, and what
    /// every total the app reports is made of.
    public private(set) var subtreeDiskBytes: Int64
    /// This entry's own content length (`fileSizeKey`), charged wherever
    /// `ownDiskBytes` is charged and zero wherever that is zero.
    ///
    /// It drives nothing. It exists so the inspector can explain the visible
    /// figure on the entries where the two diverge — a sparse VM image, a
    /// compressed system binary, a cloud placeholder that is length and no
    /// blocks at all (ticket 13).
    public private(set) var ownContentBytes: Int64
    /// `ownContentBytes` rolled up, on the same ancestor walk as
    /// `subtreeDiskBytes`.
    ///
    /// Rolled up rather than kept per file because the divergence is a *folder*
    /// story: `~/Library` is 1.05 TiB of content length on a few dozen GB of
    /// disk, and a file-only pair can only ever tell that one file at a time.
    public private(set) var subtreeContentBytes: Int64
    /// Regular files in this subtree, `1` for a regular file itself.
    public private(set) var fileCount: Int64
    /// This entry and every descendant whose subtree carries attributed bytes
    /// **on disk** — the visible measure, because that is the one with a
    /// rectangle to lose.
    ///
    /// Rolled up on the same walk as `subtreeDiskBytes`, for one reason: it is the
    /// count a treemap aggregate reports as *"N items below individual size"*,
    /// and a layout that has pruned a subtree by area must be able to say how
    /// many entries it folded **without walking it**. Computing it at draw time
    /// is what made the whole-tree pre-pass O(total nodes) (ticket 14).
    ///
    /// Zero-attributed entries — empty files, symlinks, hard-link non-owners,
    /// re-entered directories, anything of unknowable size — are *not* counted:
    /// they have no rectangle to lose, so folding them changes nothing (spec
    /// §6.2). A directory counts itself exactly when its subtree carries bytes,
    /// which is exactly when it has an attributed descendant.
    public private(set) var attributedNodeCount: Int

    public private(set) var attribution: Attribution
    public private(set) var readState: ReadState

    init(name: String, kind: NodeKind, parent: ScanNode?) {
        self.name = name
        self.kind = kind
        self.parent = parent
        self.children = []
        self.ownDiskBytes = 0
        self.subtreeDiskBytes = 0
        self.ownContentBytes = 0
        self.subtreeContentBytes = 0
        self.fileCount = 0
        self.attributedNodeCount = 0
        self.attribution = .owned
        self.readState = .complete
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

    func attribute(diskBytes: Int64, contentBytes: Int64, isRegularFile: Bool) {
        ownDiskBytes = diskBytes
        subtreeDiskBytes = diskBytes
        ownContentBytes = contentBytes
        subtreeContentBytes = contentBytes
        fileCount = isRegularFile ? 1 : 0
        // The count keys on the visible measure: an entry that is content
        // length and no blocks — a cloud placeholder — has no rectangle, so
        // folding it into an aggregate hides nothing.
        attributedNodeCount = diskBytes > 0 ? 1 : 0
    }

    /// Adds a leaf's contribution to this ancestor. The roll-up walks the
    /// whole parent chain, which is what keeps every open directory's total
    /// live (spec §3.1).
    ///
    /// `attributedNodes` is how many entries *below* this one newly became
    /// attributed. The return value says whether this directory itself just
    /// did — it is attributed exactly when its subtree first carries bytes — so
    /// the caller can add it to everything further up the chain. That is the
    /// whole of the count's maintenance: no second walk, and no per-node state
    /// beyond the counter itself.
    @discardableResult
    func accumulate(diskBytes: Int64, contentBytes: Int64, files: Int64, attributedNodes: Int = 0) -> Bool {
        let wasAttributed = subtreeDiskBytes > 0
        subtreeDiskBytes += diskBytes
        subtreeContentBytes += contentBytes
        fileCount += files
        attributedNodeCount += attributedNodes
        guard !wasAttributed, subtreeDiskBytes > 0 else { return false }
        attributedNodeCount += 1
        return true
    }

    /// Records that this name's bytes were already counted at `owner`. The node
    /// keeps its place in the tree and its zero attributed bytes (spec §3.4).
    func markHardLinkElsewhere(owner: [String]?) {
        attribution = .hardLinkElsewhere(owner: owner)
    }

    /// Records that this path is a second name for the directory at `owner`,
    /// whose subtree already carries the bytes (spec §3.3).
    func markDirectoryCountedElsewhere(owner: [String]?) {
        attribution = .directoryCountedElsewhere(owner: owner)
    }

    func markUnreadable() {
        readState = .unreadable
    }

    func markIncomplete() {
        if readState == .complete {
            readState = .incomplete
        }
    }
}
