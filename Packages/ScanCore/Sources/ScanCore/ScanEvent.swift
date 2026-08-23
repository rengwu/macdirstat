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

/// Whether a result is the whole truth.
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
    /// The tree. Browsable and selectable whatever the reason — a cancelled
    /// scan hands over everything it did reach.
    public let root: ScanNode
    public let completeness: Completeness
    /// What could not be read: exact totals, bounded detail (spec §5.7).
    public let errors: ErrorSummary
    /// What was skipped on purpose, counted by reason (spec §3.4, §3.5). Not
    /// errors — the tree is still Exact.
    public let exclusions: ExclusionSummary
    /// The root's presented file and folder tallies, folded on the scan's own
    /// thread while the tree was finalized (§7.3).
    ///
    /// They travel with the result rather than being recomputed because the
    /// status line is rebuilt whenever the presentation model changes, and a
    /// whole-tree walk on the main actor per rebuild is what made selecting a
    /// large root stall.
    public let visibleTotals: VisibleTreeTotals
    /// Volume scans only, reported separately from any attributed byte count.
    public let volumeCapacity: VolumeCapacity?
    public let elapsed: TimeInterval

    public init(
        reason: Reason,
        root: ScanNode,
        completeness: Completeness,
        errors: ErrorSummary = .empty,
        exclusions: ExclusionSummary = .empty,
        visibleTotals: VisibleTreeTotals = .zero,
        volumeCapacity: VolumeCapacity?,
        elapsed: TimeInterval
    ) {
        self.reason = reason
        self.root = root
        self.completeness = completeness
        self.errors = errors
        self.exclusions = exclusions
        self.visibleTotals = visibleTotals
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
/// Order is: exactly one `.started`, then `.progress` (monotonic, later
/// supersedes earlier), then exactly one terminal `.finished` or `.failed`,
/// then the stream ends.
///
/// **The tree is delivered once, with the terminal event.** It used to be
/// republished several times a second so the panes could fill in as the scan
/// ran, which meant handing out a tree the scan was still writing to. Those
/// snapshots shared their finished subtrees with the live tree by reference, so
/// a published node's `parent` pointed at a node the scan thread was still
/// mutating — wrong percentages, and a dangling pointer once the snapshot it
/// was selected from went away. There is now one tree, built by the scan and
/// handed over when it is finished with it.
public enum ScanEvent: Sendable {
    case started(root: URL, mode: ScanMode, volumeCapacity: VolumeCapacity?)
    case progress(ProgressSnapshot)
    /// Terminal: `.completed` or `.cancelled`. Carries the tree.
    case finished(ScanResult)
    /// Terminal, pre-flight only.
    case failed(ScanFailure)

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        case .started, .progress: return false
        }
    }
}
