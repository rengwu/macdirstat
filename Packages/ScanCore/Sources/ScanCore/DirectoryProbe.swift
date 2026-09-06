import Foundation

/// The filesystem seam the scan engine talks to — **listing and metadata
/// only**.
///
/// Read-only is structural, not a matter of discipline (spec §10): there is no
/// method here that mutates, downloads, or hands back file contents, so no
/// implementation of this protocol — production or test — can be asked to do
/// any of those things. `ScanCoreTests` asserts that property against this
/// file's own source text, so a later addition cannot quietly widen the seam.
///
/// The production adapter over `FileManager` lands in ticket 05;
/// `ScriptedDirectoryProbe` (in `ScanCoreTestSupport`) backs the pure suite.
public protocol DirectoryProbe: Sendable {
    /// Lists one directory, shallowly, with every prefetch key already
    /// populated on the returned entries.
    ///
    /// Shallow, not the deep enumerator: `FileManager.enumerator(at:)`
    /// documents that it *traverses* mount points, which would silently leave
    /// the root's device. The engine recurses itself so every descent passes
    /// the device-boundary check (spec §5.4).
    ///
    /// A throw is a recoverable, per-directory problem: the entry is marked
    /// unreadable and traversal continues (spec §3.5).
    func list(_ url: URL) throws -> [EntryMeta]

    /// Reads one entry's metadata. The engine calls this for the scan root at
    /// pre-flight and nowhere else — children arrive fully described by
    /// `list(_:)`, so no entry is ever read twice (spec §8.2).
    func metadata(of url: URL) throws -> EntryMeta

    /// Reads the volume facts pre-flight needs: locality (the eligibility
    /// predicate), hard-link support, and capacity/free for a volume scan.
    func volumeInfo(for url: URL) throws -> VolumeInfo

    /// Every path at which a filesystem is currently mounted, read **once** per
    /// scan.
    ///
    /// It exists because APFS presents the system volume and the data volume as
    /// one volume: `/` and `/System/Volumes/Data` report the same volume
    /// identifier *and* the same file identity, while being two different
    /// directories — the second one holds the data volume's own top level
    /// (`.Spotlight-V100`, `.fseventsd`, `MobileSoftwareUpdate`) beside the
    /// firmlinked names already reachable from `/`. Knowing which directories
    /// are mount points lets the traversal walk that one last, so the duplicated
    /// names are attributed to the paths a person recognises (`/Users`) and only
    /// what is genuinely unique to the second root is counted there
    /// (spec §3.3).
    ///
    /// It is an ordering hint and nothing more: a probe that answers with an
    /// empty set — every scripted probe does, unless a test says otherwise —
    /// changes which of two paths owns a shared subtree, never how many times
    /// its bytes are counted.
    func mountPointPaths() -> Set<String>
}

public extension DirectoryProbe {
    /// The default: no directory is known to be a mount point.
    func mountPointPaths() -> Set<String> {
        []
    }
}

/// Opt-in for probes whose independent `list` calls may safely overlap.
/// Scripted/test probes stay serial by default, preserving their exact call
/// traces; the production FileManager adapter adopts this capability.
public protocol ConcurrentDirectoryListingProbe: DirectoryProbe {}

/// The result of measuring a package without materializing its interior as
/// scan nodes.
public struct PackageSummary: Sendable, Equatable {
    /// One contribution per multiply-linked inode, already included in the
    /// totals. The session reconciles these against its scan-wide index.
    public struct HardLink: Sendable, Equatable {
        public var identity: FileSystemIdentity
        public var relativePath: [String]
        public var diskBytes: Int64
        public var contentBytes: Int64

        public init(identity: FileSystemIdentity, relativePath: [String], diskBytes: Int64, contentBytes: Int64) {
            self.identity = identity
            self.relativePath = relativePath
            self.diskBytes = max(0, diskBytes)
            self.contentBytes = max(0, contentBytes)
        }
    }

    public var diskBytes: Int64
    public var contentBytes: Int64
    public var fileCount: Int64
    public var directoryCount: Int
    public var isComplete: Bool
    public var remoteOnlyItems: Int
    public var crossedVolumeBoundaries: Int
    public var hardLinks: [HardLink]

    public init(
        diskBytes: Int64,
        contentBytes: Int64,
        fileCount: Int64,
        directoryCount: Int,
        isComplete: Bool = true,
        remoteOnlyItems: Int = 0,
        crossedVolumeBoundaries: Int = 0,
        hardLinks: [HardLink] = []
    ) {
        self.diskBytes = max(0, diskBytes)
        self.contentBytes = max(0, contentBytes)
        self.fileCount = max(0, fileCount)
        self.directoryCount = max(0, directoryCount)
        self.isComplete = isComplete
        self.remoteOnlyItems = max(0, remoteOnlyItems)
        self.crossedVolumeBoundaries = max(0, crossedVolumeBoundaries)
        self.hardLinks = hardLinks
    }
}

/// An optional capability used only by ``PackageScanMode/summarized``.
///
/// It remains read-only: implementations may inspect directory entries and
/// metadata, but never file contents. A probe without this capability simply
/// falls back to the detailed package walk.
public protocol PackageSummarizingProbe: DirectoryProbe {
    func summarizePackage(
        _ url: URL,
        onVolume volume: FileSystemIdentity?,
        shouldStop: @Sendable () -> Bool
    ) -> PackageSummary?
}
