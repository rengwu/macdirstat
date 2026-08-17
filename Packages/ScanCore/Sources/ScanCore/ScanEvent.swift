import Foundation

/// The scalar telemetry behind the progress card (spec §5.5).
///
/// Primary progress is **indeterminate**: there is no cheap way to know the
/// total before scanning, and a pre-pass would double the I/O. What is honest
/// is what has been measured so far.
public struct ProgressSnapshot: Sendable, Equatable {
    /// Blocks on disk counted so far — equal to the root's `subtreeDiskBytes`.
    /// Monotonic.
    public let attributedDiskBytes: Int64
    public let filesSeen: Int64
    public let directoriesSeen: Int64
    /// The last components of the directory being listed, for the "currently
    /// scanning …" line.
    public let currentPathTail: String
    public let elapsed: TimeInterval
    /// Entries met per second — files plus directories, over elapsed time.
    ///
    /// It replaces a bytes-per-second reading, which was never a disk speed:
    /// this scanner reads directory listings and never file contents, so the
    /// only rate on that card that is a measurement of anything is how fast
    /// entries are being met (ticket 13).
    public let itemsPerSecond: Double
    /// Whole-volume scans only: blocks counted ÷ the volume's used figure.
    ///
    /// Numerator and denominator are now the same quantity, so this is a real
    /// fraction rather than a reassurance bar — but it is still approximate,
    /// and it is honest about the two ways it can be wrong:
    ///
    /// - **Capped at 0.99 while a scan is running.** No state of the app claims
    ///   to be finished before it is; only a terminal snapshot may read 1.0.
    /// - **Withdrawn for the rest of the scan** — `nil` — once the counted
    ///   total passes volume-used. Past that point the figure has no honest
    ///   denominator left, and the card falls back to counted total, item count
    ///   and elapsed.
    ///
    /// Always `nil` for a folder scan, which has nothing to divide by
    /// (spec §5.5).
    public let approximateFraction: Double?
    /// Emission order. Later snapshots supersede earlier ones.
    public let sequence: UInt64

    public init(
        attributedDiskBytes: Int64,
        filesSeen: Int64,
        directoriesSeen: Int64,
        currentPathTail: String,
        elapsed: TimeInterval,
        itemsPerSecond: Double,
        approximateFraction: Double?,
        sequence: UInt64
    ) {
        self.attributedDiskBytes = attributedDiskBytes
        self.filesSeen = filesSeen
        self.directoriesSeen = directoriesSeen
        self.currentPathTail = currentPathTail
        self.elapsed = elapsed
        self.itemsPerSecond = itemsPerSecond
        self.approximateFraction = approximateFraction
        self.sequence = sequence
    }
}

/// An immutable view of the tree as it stands.
///
/// Its `root` is frozen: completed subtrees are the very same objects the scan
/// built, shared by reference, and only the still-open spine is copied
/// (spec §5.2).
public struct TreeSnapshot: Sendable {
    public let root: ScanNode
    /// Emission order. Later snapshots supersede earlier ones.
    public let generation: UInt64

    /// Keeps the scan's live tree alive for as long as this snapshot is held.
    /// A shared frozen subtree's `parent` chain points into that live tree, so
    /// releasing it while a snapshot survives would leave those links dangling.
    private let retainedLiveTree: ScanNode

    init(root: ScanNode, liveTree: ScanNode, generation: UInt64) {
        self.root = root
        self.retainedLiveTree = liveTree
        self.generation = generation
    }
}

/// Whether a result is the whole truth (spec §5.3).
public enum Completeness: Sendable, Equatable {
    /// Ran to completion with nothing unreadable.
    case exact
    /// Cancelled, or something beneath the root could not be read. Totals are
    /// floors; nothing was guessed to fill the gap.
    case incomplete(cancelled: Bool, unreadableEntries: Int)
}

/// The terminal payload of a scan that ran. A cancelled scan and a scan with
/// unreadable entries both produce a result — partial results are results, not
/// failures (spec §5.3).
public struct ScanResult: Sendable {
    public enum Reason: Sendable, Equatable {
        case completed
        case cancelled
    }

    public let reason: Reason
    /// The frozen, fully retained tree. Browsable and selectable whatever the
    /// reason (spec §3.5).
    public let root: ScanNode
    public let completeness: Completeness
    /// What could not be read: exact totals, bounded detail (spec §5.7).
    public let errors: ErrorSummary
    /// What was skipped on purpose, counted by reason (spec §3.4, §3.5). Not
    /// errors — the tree is still Exact.
    public let exclusions: ExclusionSummary
    /// Volume scans only, reported separately from any attributed byte count.
    public let volumeCapacity: VolumeCapacity?
    public let elapsed: TimeInterval

    public init(
        reason: Reason,
        root: ScanNode,
        completeness: Completeness,
        errors: ErrorSummary = .empty,
        exclusions: ExclusionSummary = .empty,
        volumeCapacity: VolumeCapacity?,
        elapsed: TimeInterval
    ) {
        self.reason = reason
        self.root = root
        self.completeness = completeness
        self.errors = errors
        self.exclusions = exclusions
        self.volumeCapacity = volumeCapacity
        self.elapsed = elapsed
    }
}

/// The only way a scan fails, and it can only happen at pre-flight (spec §5.3).
/// Every mid-scan filesystem problem is recorded and traversal continues.
public enum ScanFailure: Error, Sendable, Equatable {
    case rootMissing(URL)
    case rootNotDirectory(URL)
    /// `volumeIsLocalKey == false` — a network volume is out of scope (spec §3.3).
    case rootOnNetworkVolume(URL)
    case rootAccessDenied(URL)
}

/// The scan's event stream.
///
/// Order is: exactly one `.started`, then interleaved `.progress` and `.tree`
/// (both monotonic, later supersedes earlier), then exactly one terminal
/// `.finished` or `.failed`, then the stream ends.
public enum ScanEvent: Sendable {
    case started(root: URL, mode: ScanMode, volumeCapacity: VolumeCapacity?)
    case progress(ProgressSnapshot)
    case tree(TreeSnapshot)
    /// Terminal: `.completed` or `.cancelled`.
    case finished(ScanResult)
    /// Terminal, pre-flight only.
    case failed(ScanFailure)

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        case .started, .progress, .tree: return false
        }
    }
}
