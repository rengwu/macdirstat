import Foundation

/// The per-scan hard-link identity index (spec §3.4).
///
/// One inode reached by several in-scope names must contribute its bytes
/// **once**. Under the traversal's deterministic name sort the first path to
/// arrive owns them; every later path stays visible with zero attributed bytes
/// and a pointer back to the owner.
///
/// **Only entries that could possibly be hard links are ever inserted** —
/// `linkCount > 1`, with a readable identity, on a volume that supports hard
/// links at all. That is what keeps the index proportional to the (typically
/// tiny) set of multiply-linked inodes rather than to the whole tree, which is
/// the memory claim in §5.7.
///
/// The identity is `fileResourceIdentifierKey`, which Apple documents as equal
/// exactly for *"the same file system item"* — precisely the identity the spec
/// asks for, with no `stat` and no second metadata read. It is not persistent
/// across restarts, so the index is per-scan and never stored.
///
/// APFS clones need no special case: a clone has its own identity, so it never
/// collides here and contributes its own logical length (spec §3.4).
struct HardLinkIndex {
    /// What one entry turned out to be.
    enum Outcome: Equatable {
        /// Not eligible for dedup — the index was not consulted.
        case notALink
        /// The first in-scope name for this inode; it owns the bytes.
        case owner
        /// A later name for an inode already counted at `of`.
        case duplicate(of: ScanNode)

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case (.notALink, .notALink), (.owner, .owner): return true
            case (.duplicate(let a), .duplicate(let b)): return a === b
            default: return false
            }
        }
    }

    private var owners: [FileSystemIdentity: ScanNode] = [:]
    /// `volumeSupportsHardLinksKey`, read once at pre-flight. Where the volume
    /// cannot hold a hard link, no dedup is possible and the whole mechanism is
    /// skipped.
    private let isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// How many inodes are indexed — the memory claim, in one number.
    var count: Int { owners.count }

    /// Claims `meta`'s identity for `node`, or reports who claimed it first.
    mutating func claim(_ meta: EntryMeta, for node: ScanNode) -> Outcome {
        guard isEnabled,
              let linkCount = meta.linkCount, linkCount > 1,
              let identity = meta.fileIdentity
        else {
            // A link count of 1 cannot be a hard link, and an identity we could
            // not read is not evidence of one.
            return .notALink
        }

        if let owner = owners[identity] {
            return .duplicate(of: owner)
        }
        owners[identity] = node
        return .owner
    }
}
