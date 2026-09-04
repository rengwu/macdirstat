import Foundation

/// The per-scan visited-directory index (spec §3.3, §3.4).
///
/// A directory reached at two paths on one volume must be walked **once**. The
/// case that exists on every modern Mac is the APFS firmlink graft: macOS
/// reports the same volume identifier for `/` and for `/System/Volumes/Data`,
/// so the device-boundary check sees no boundary and descends — and every
/// directory beneath it is the same inode already reached through a firmlink
/// (`/Users` and `/System/Volumes/Data/Users` are one directory). Without this
/// index a scan of `/` counts the whole data volume twice: twice the bytes,
/// twice the nodes, twice the wall clock, twice the footprint.
///
/// ``HardLinkIndex`` cannot catch it. Those entries have a link count of 1, so
/// it answers `.notALink` before it ever consults its map, and it is aimed at
/// multiply-linked *files* in the first place.
///
/// **Why identity, and not a list of known mount points.** The identity is
/// `fileResourceIdentifierKey`, which Apple documents as equal exactly for
/// *"the same file system item"*, and it is already in the probe's prefetch
/// set — so the guard costs no extra syscall. A hardcoded list of Apple's
/// synthetic mounts would be brittle and version-specific; reading `statfs`'s
/// `f_mntfromname` would be a second syscall per directory. An identity set
/// also generalises: it catches any future graft, not only the one Apple ships
/// today.
///
/// **Why a repeat is always re-entry.** Only directories on the root volume are
/// offered here — the device check runs first — and no filesystem macOS
/// supports lets an ordinary process create a second hard link to a directory.
/// So a repeated identity within one volume is the same directory, never a
/// legitimate second thing.
///
/// **Memory.** One dictionary entry per directory *descended*, holding the
/// identity object and the owning node — proportional to directory count
/// (~1.4 M on a whole-Mac scan), not to entry count. It is its own type, like
/// ``HardLinkIndex``, so that claim is testable directly through ``count``
/// rather than only through what a scan happened to produce.
struct VisitedDirectoryIndex {
    /// What one directory turned out to be.
    enum Outcome: Equatable {
        /// No identity could be read. Not evidence of anything, so it descends:
        /// omitting real bytes is the worse error (the rule
        /// `isOnRootVolume` already follows).
        case unidentified
        /// The first path to this directory. It owns everything beneath it.
        case firstVisit
        /// A second path to a directory already descended at `of`.
        case repeatVisit(of: ScanNode)

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case (.unidentified, .unidentified), (.firstVisit, .firstVisit): return true
            case (.repeatVisit(let a), .repeatVisit(let b)): return a === b
            default: return false
            }
        }
    }

    private var owners: [FileSystemIdentity: ScanNode] = [:]
    /// The guard's off switch. It exists for one reason: a test that asserts a
    /// grafted fixture is counted once proves nothing unless the same fixture
    /// can be shown to double without the guard.
    private let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    /// How many directories are indexed — the memory claim, in one number.
    var count: Int { owners.count }

    /// Read-only hint for speculative listing. Ownership is still settled by
    /// `claim` at deterministic arrival time; this merely avoids I/O we already
    /// know cannot be consumed.
    func hasClaimed(_ identity: FileSystemIdentity?) -> Bool {
        guard isEnabled, let identity else { return false }
        return owners[identity] != nil
    }

    /// Claims `identity` for `node`, or reports which node claimed it first.
    mutating func claim(_ identity: FileSystemIdentity?, for node: ScanNode) -> Outcome {
        guard isEnabled, let identity = identity else { return .unidentified }
        if let owner = owners[identity] {
            return .repeatVisit(of: owner)
        }
        owners[identity] = node
        return .firstVisit
    }
}
