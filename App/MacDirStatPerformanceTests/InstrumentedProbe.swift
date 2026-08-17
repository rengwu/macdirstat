import Foundation
import ScanCore

/// What the engine asked of the filesystem, in numbers rather than a log.
///
/// `ScriptedDirectoryProbe` keeps a full request log, which is the right shape
/// for a twelve-entry fixture and the wrong one for two million: the log would
/// outweigh the tree it is measuring, inside the test whose job is to measure
/// the tree. So this counts instead, and reconstructs the two claims that a log
/// would otherwise be needed for:
///
/// - **One shallow list per traversed directory** — `listCount` equals the
///   directory count the resulting tree reports. Equality in both directions is
///   the proof: fewer would mean a directory went unvisited, more would mean
///   one was listed twice.
/// - **No descent across a device boundary** — a decoy on another volume hands
///   back children if anything ever lists it, and `foreignVolumeListCount`
///   counts the attempt.
struct ProbeOperationCounts: Equatable {
    var listCount = 0
    var metadataCount = 0
    var volumeInfoCount = 0
    var listFailureCount = 0
    var entriesReturned = 0
    var deepestListedDepth = 0
    var foreignVolumeListCount = 0
    /// Listings of a name that repeats another directory's identity. A graft
    /// hands back the real subtree, so a walk that listed one would double it.
    var repeatedDirectoryListCount = 0
    /// Only tracked when the probe was built with `tracksListedPaths`, which
    /// the heavy rungs turn off — the set would be a per-directory allocation
    /// inside a memory measurement.
    var repeatedListCount = 0

    /// Every operation the engine performed. `list` plus the two pre-flight
    /// reads is the whole of it: the seam has no third verb (spec §10).
    var total: Int { listCount + metadataCount + volumeInfoCount }
}

/// A clock that only moves when the workload tells it to.
///
/// Emission cadence is time-based, and a lazily generated workload finishes far
/// faster than a real disk would, so on the system clock a 400,000-entry rung
/// can produce a single tree snapshot and no intermediate progress at all.
/// Advancing a fixed step per directory listing makes the cadence a function of
/// *traversal position* instead of wall time: with a 0.25 s tree cadence and a
/// 0.01 s step, a snapshot lands every twenty-five directories, deterministically
/// and at no cost. Wall-clock elapsed is measured separately, and is diagnostic
/// only (spec §8.2).
final class SteppingClock: ScanClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private let step: TimeInterval

    init(step: TimeInterval) {
        self.step = step
    }

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance() {
        lock.lock()
        current += step
        lock.unlock()
    }
}

/// A `DirectoryProbe` over a generated ``ScaleWorkload`` that counts what it
/// was asked and computes what it answers.
///
/// It retains no listing: `list(_:)` derives the entries from the path and the
/// seed on every call, so the probe's own memory is a handful of counters
/// whatever the rung (spec §9.2, "rather than retaining a second metadata
/// copy").
final class CountingWorkloadProbe: DirectoryProbe, @unchecked Sendable {
    private let rootURL: URL
    private let rootComponentCount: Int
    private let workload: ScaleWorkload
    private let clock: SteppingClock?
    private let tracksListedPaths: Bool
    /// Called before each listing with the number of listings already done —
    /// the hook a cancellation barrier hangs off.
    private let beforeList: (@Sendable (Int) -> Void)?

    private let lock = NSLock()
    private var counts = ProbeOperationCounts()
    private var listedPaths: Set<String> = []

    init(
        rootURL: URL,
        workload: ScaleWorkload,
        clock: SteppingClock? = nil,
        tracksListedPaths: Bool = false,
        beforeList: (@Sendable (Int) -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.rootComponentCount = rootURL.standardizedFileURL.pathComponents.count
        self.workload = workload
        self.clock = clock
        self.tracksListedPaths = tracksListedPaths
        self.beforeList = beforeList
    }

    var operationCounts: ProbeOperationCounts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    // MARK: - DirectoryProbe

    func list(_ url: URL) throws -> [EntryMeta] {
        let components = relativeComponents(of: url)

        lock.lock()
        let ordinal = counts.listCount
        counts.listCount += 1
        counts.deepestListedDepth = max(counts.deepestListedDepth, components.count)
        if components.last?.hasPrefix("foreign-volume-") == true {
            counts.foreignVolumeListCount += 1
        }
        if components.contains(where: { $0.hasPrefix("graft-") }) {
            counts.repeatedDirectoryListCount += 1
        }
        if tracksListedPaths, !listedPaths.insert(components.joined(separator: "/")).inserted {
            counts.repeatedListCount += 1
        }
        lock.unlock()

        beforeList?(ordinal)
        clock?.advance()

        do {
            let entries = try workload.entries(at: components)
            lock.lock()
            counts.entriesReturned += entries.count
            lock.unlock()
            return entries
        } catch {
            lock.lock()
            counts.listFailureCount += 1
            lock.unlock()
            throw error
        }
    }

    func metadata(of url: URL) throws -> EntryMeta {
        lock.lock()
        counts.metadataCount += 1
        lock.unlock()
        guard url.standardizedFileURL == rootURL else {
            // The engine reads metadata for the root and nowhere else
            // (spec §8.2). Anything else is a duplicate fetch of a value the
            // parent's listing already prefetched, and it should fail loudly.
            throw CocoaError(.fileNoSuchFile)
        }
        return workload.rootMetadata(name: url.lastPathComponent)
    }

    func volumeInfo(for url: URL) throws -> VolumeInfo {
        lock.lock()
        counts.volumeInfoCount += 1
        lock.unlock()
        return workload.volumeInfo
    }

    // MARK: - Paths

    private func relativeComponents(of url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponentCount else { return [] }
        return Array(components.dropFirst(rootComponentCount))
    }
}
