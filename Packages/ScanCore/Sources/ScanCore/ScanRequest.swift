import Foundation

/// Whether the selected root is an ordinary folder or a whole volume. Only a
/// volume scan gets an (explicitly approximate) completion fraction (spec §5.5).
public enum ScanMode: Sendable, Equatable {
    case folder
    case volumeRoot
}

/// The engine's time source, injectable so throttling is deterministic in
/// tests.
///
/// `Swift.Clock` is macOS 13+, above the 11.0 floor (spec §4.2), so the engine
/// owns this one-property protocol instead. `now` is elapsed seconds from an
/// arbitrary origin and must be monotonic.
public protocol ScanClock: Sendable {
    var now: TimeInterval { get }
}

/// The production clock: monotonic, unaffected by wall-clock changes.
public struct MonotonicClock: ScanClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// How often an event kind may be emitted.
///
/// Emissions are coalesced, never per-entry (spec §5.5). Tests set
/// `.everyChange` (cadence 0) to see the full progression, or `.terminalOnly`
/// (cadence ∞) to see only the final exact snapshot.
public enum EmissionCadence: Sendable, Equatable {
    /// Emit on every change — cadence 0.
    case everyChange
    /// Emit at most once per interval, in seconds.
    case minimumInterval(TimeInterval)
    /// Emit only the final exact snapshot — cadence ∞.
    case terminalOnly

    /// ≤ ~15 Hz scalars (spec §5.5).
    public static let progressDefault = EmissionCadence.minimumInterval(1.0 / 15.0)
    /// ≤ ~4 Hz tree (spec §5.5).
    public static let treeDefault = EmissionCadence.minimumInterval(0.25)
}

/// Tunables a scan carries. Every one has a default; tests override cadence
/// and clock.
public struct ScanOptions: Sendable {
    public var progressCadence: EmissionCadence
    public var treeCadence: EmissionCadence
    /// Cancellation is checked per directory **and** every this-many entries
    /// inside one directory — a worst-case operation bound independent of tree
    /// size, not a millisecond SLA (spec §5.6).
    public var cancellationBatchSize: Int
    /// How many per-entry error records to retain before keeping only the exact
    /// running total (spec §5.7). The category counts stay exact either way —
    /// this bounds memory, not honesty.
    public var maxDetailedErrors: Int
    public var clock: ScanClock
    /// The visited-directory guard's off switch (``VisitedDirectoryIndex``).
    ///
    /// Internal, and `true` everywhere in the product: a scan that walks the
    /// same directory twice reports twice the bytes. It exists so a test can
    /// show its own grafted fixture doubling without the guard — an assertion
    /// that the guard counts a graft once proves nothing unless the fixture is
    /// known to be a graft in the first place.
    var deduplicatesRepeatedDirectories = true

    public init(
        progressCadence: EmissionCadence = .progressDefault,
        treeCadence: EmissionCadence = .treeDefault,
        cancellationBatchSize: Int = 256,
        maxDetailedErrors: Int = 1_000,
        clock: ScanClock = MonotonicClock()
    ) {
        self.progressCadence = progressCadence
        self.treeCadence = treeCadence
        self.cancellationBatchSize = max(1, cancellationBatchSize)
        self.maxDetailedErrors = max(0, maxDetailedErrors)
        self.clock = clock
    }
}

/// The security-scoped access seam (spec §10).
///
/// `startAccessing` reports whether a scope was actually *started*, so the
/// engine knows whether a matching `stopAccessing` is owed — it is not an
/// eligibility verdict. An ordinary local URL is readable without a scope, and
/// a root that genuinely cannot be read fails pre-flight through the probe.
public protocol SecurityScopedAccess: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// The production adapter over `URL`'s security-scoped API.
public struct SystemSecurityScopedAccess: SecurityScopedAccess {
    public init() {}

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Everything one scan needs: the root, its mode, the filesystem seam, the
/// security-scoped access handle, and the cadence/clock (spec §5.1).
public struct ScanRequest: Sendable {
    public let root: URL
    public let mode: ScanMode
    public let probe: DirectoryProbe
    public let access: SecurityScopedAccess
    public let options: ScanOptions

    public init(
        root: URL,
        mode: ScanMode,
        probe: DirectoryProbe,
        access: SecurityScopedAccess = SystemSecurityScopedAccess(),
        options: ScanOptions = ScanOptions()
    ) {
        self.root = root
        self.mode = mode
        self.probe = probe
        self.access = access
        self.options = options
    }
}
