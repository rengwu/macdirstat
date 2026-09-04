import Foundation

/// Whether the selected root is an ordinary folder or a whole volume. Only a
/// volume scan gets an (explicitly approximate) completion fraction (spec §5.5).
public enum ScanMode: Sendable, Equatable {
    case folder
    case volumeRoot
}

/// How application bundles and other macOS packages are scanned.
public enum PackageScanMode: Sendable, Equatable {
    /// Build the complete hierarchy inside every package.
    case detailed
    /// Measure each package in a lightweight aggregate pass and keep it as one
    /// atomic node. This avoids sorting and materializing the many small files
    /// inside an app bundle while retaining its total size.
    case summarized
}

/// The engine's time source, injectable so throttling is deterministic in
/// tests. `now` is elapsed seconds from an arbitrary origin and must be
/// monotonic.
public protocol ScanClock: Sendable {
    var now: TimeInterval { get }
}

/// The production clock: monotonic, unaffected by wall-clock changes.
public struct MonotonicClock: ScanClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Tunables a scan carries. Every one has a default; tests override the
/// progress interval and the clock.
public struct ScanOptions: Sendable {
    /// The shortest gap between two `.progress` emissions, in seconds.
    /// Progress is coalesced, never emitted per entry. `0` emits on every
    /// change (tests, to see the whole progression) and `.infinity` emits only
    /// the final exact reading.
    public var progressInterval: TimeInterval
    /// Cancellation is checked per directory **and** every this-many entries
    /// inside one directory — a worst-case operation bound independent of tree
    /// size, not a millisecond promise.
    public var cancellationBatchSize: Int
    /// How many per-entry error records to retain before keeping only the exact
    /// running total. The category counts stay exact either way — this bounds
    /// memory, not honesty.
    public var maxDetailedErrors: Int
    /// Whether packages are expanded into the scan tree or represented by one
    /// measured aggregate node.
    public var packageScanMode: PackageScanMode
    /// Maximum independent directory listings read ahead. Results are still
    /// consumed in deterministic depth-first order; this overlaps metadata I/O
    /// only for probes that explicitly support concurrent listing.
    public var directoryPrefetchConcurrency: Int
    public var clock: ScanClock
    /// The visited-directory guard's off switch (``VisitedDirectoryIndex``).
    ///
    /// Internal, and `true` everywhere in the product: a scan that walks the
    /// same directory twice reports twice the bytes. It exists so a test can
    /// show its own grafted fixture doubling without the guard — an assertion
    /// that the guard counts a graft once proves nothing unless the fixture is
    /// known to be a graft in the first place.
    var deduplicatesRepeatedDirectories = true

    /// ~15 Hz, which is as often as a handful of numbers on a card can
    /// usefully change.
    public static let defaultProgressInterval: TimeInterval = 1.0 / 15.0

    public init(
        progressInterval: TimeInterval = ScanOptions.defaultProgressInterval,
        cancellationBatchSize: Int = 256,
        maxDetailedErrors: Int = 1_000,
        packageScanMode: PackageScanMode = .detailed,
        directoryPrefetchConcurrency: Int = 3,
        clock: ScanClock = MonotonicClock()
    ) {
        self.progressInterval = max(0, progressInterval)
        self.cancellationBatchSize = max(1, cancellationBatchSize)
        self.maxDetailedErrors = max(0, maxDetailedErrors)
        self.packageScanMode = packageScanMode
        self.directoryPrefetchConcurrency = max(1, directoryPrefetchConcurrency)
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
