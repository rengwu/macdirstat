import Foundation

/// Why an entry could not be measured (spec §3.5, §5.7).
///
/// Every one of these is **recoverable**: the entry is marked Unreadable, its
/// ancestors Incomplete, its size left at zero rather than guessed, and the
/// walk carries on. None of them fails a scan.
public enum ErrorCategory: Sendable, Hashable, CaseIterable {
    /// A directory whose listing threw — permission, I/O, anything but a
    /// disappearance.
    case unreadableDirectory
    /// An entry whose own metadata is missing or malformed — most commonly a
    /// `fileSize` that could not be read.
    case unreadableEntry
    /// An entry that was listed with its parent and was gone by the time the
    /// walk reached it. Live change is best-effort (spec §3.5).
    case disappeared
}

/// One retained error, kept only while the detail budget lasts (spec §5.7).
public struct ErrorRecord: Sendable, Equatable {
    /// The entry's path components, scan root first — the same shape
    /// ``ScanNode/pathComponents()`` returns, so the UI rebuilds a URL from it
    /// the same way. Not a stored `URL`: an error storm must stay cheap.
    public let path: [String]
    public let category: ErrorCategory
    /// What the filesystem said, where it said anything — a fallback the
    /// inspector can show verbatim. ``category`` is the field to branch on and
    /// to localize from; this one is diagnostic text, not UI copy.
    public let message: String

    public init(path: [String], category: ErrorCategory, message: String) {
        self.path = path
        self.category = category
        self.message = message
    }
}

/// What went wrong during a scan: exact totals, bounded detail (spec §5.7).
///
/// The counts are never capped — they are the honest answer to "how much of
/// this is missing". Only the per-entry records are, so that an error storm
/// cannot blow the memory ceiling.
public struct ErrorSummary: Sendable, Equatable {
    /// Exact count per category. Categories with no errors are absent.
    public let byCategory: [ErrorCategory: Int]
    /// The first `maxDetailedErrors` records, in traversal order.
    public let details: [ErrorRecord]
    /// The exact running total, whatever `details` had room for.
    public let total: Int
    /// `true` once errors outnumbered the retained records.
    public let truncated: Bool

    public init(byCategory: [ErrorCategory: Int], details: [ErrorRecord], total: Int, truncated: Bool) {
        self.byCategory = byCategory
        self.details = details
        self.total = total
        self.truncated = truncated
    }

    public static let empty = ErrorSummary(byCategory: [:], details: [], total: 0, truncated: false)

    public var isEmpty: Bool { total == 0 }
}

/// Why the scan deliberately did not count something (spec §3.3, §3.4).
///
/// An exclusion is **not** an error: nothing went wrong, a policy chose to skip
/// it. Exclusions therefore leave ancestors Complete and the result Exact.
public enum ExclusionReason: Sendable, Hashable, CaseIterable {
    /// A remote-only cloud placeholder: omitted from the tree, and never
    /// downloaded (spec §3.4).
    case remoteOnlyCloud
    /// A subdirectory on a different volume: visible, never descended
    /// (spec §3.3).
    case crossedVolumeBoundary
    /// A second path to a directory already descended on this volume — the
    /// APFS firmlink graft under `/System/Volumes/Data` is the case every Mac
    /// has. The name stays visible and weightless, its bytes counted once at
    /// the first path (spec §3.3, §3.4). Like every exclusion, it is not an
    /// error: nothing failed, the walk simply refused to count the same
    /// directory twice.
    case repeatedDirectory
}

/// What the scan skipped on purpose, counted exactly by reason (spec §3.5).
public struct ExclusionSummary: Sendable, Equatable {
    /// Reasons with no exclusions are absent.
    public let byReason: [ExclusionReason: Int]

    public init(byReason: [ExclusionReason: Int]) {
        self.byReason = byReason
    }

    public static let empty = ExclusionSummary(byReason: [:])

    public var total: Int { byReason.values.reduce(0, +) }

    public var isEmpty: Bool { byReason.isEmpty }
}

/// The scan's running error and exclusion accounting.
///
/// Scan-confined and single-writer, like the rest of ``ScanSession``'s state.
/// The detail budget is enforced *before* a path is built, so past the cap an
/// error costs one integer increment and no allocation — which is the whole
/// point of capping it.
struct ScanDiagnostics {
    private let detailLimit: Int
    private var byCategory: [ErrorCategory: Int] = [:]
    private var details: [ErrorRecord] = []
    private var errorTotal = 0
    private var byReason: [ExclusionReason: Int] = [:]

    init(detailLimit: Int) {
        self.detailLimit = max(0, detailLimit)
    }

    /// The exact number of entries that could not be read — what
    /// ``Completeness`` reports.
    var unreadableEntries: Int { errorTotal }

    mutating func recordError(_ category: ErrorCategory, at node: ScanNode, message: @autoclosure () -> String) {
        errorTotal += 1
        byCategory[category, default: 0] += 1
        guard details.count < detailLimit else { return }
        details.append(ErrorRecord(path: node.pathComponents(), category: category, message: message()))
    }

    mutating func exclude(_ reason: ExclusionReason) {
        byReason[reason, default: 0] += 1
    }

    var errors: ErrorSummary {
        ErrorSummary(
            byCategory: byCategory,
            details: details,
            total: errorTotal,
            truncated: errorTotal > details.count
        )
    }

    var exclusions: ExclusionSummary {
        ExclusionSummary(byReason: byReason)
    }
}
