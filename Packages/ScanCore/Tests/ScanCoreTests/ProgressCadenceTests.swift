import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Progress honesty: coalesced to ~15 Hz, newest-wins under a slow consumer, an
/// exact final reading whatever the interval, and no completion percentage for a
/// folder scan.
///
/// Every timing claim here is made against a clock the test drives by hand. A
/// throttle asserted against the wall clock asserts the speed of the machine.
final class ProgressCadenceTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    /// 60 sibling directories, one file each — enough listings for the clock to
    /// advance past many cadence windows.
    private func wideTree(directories: Int = 60) -> ScriptedEntry {
        .directory("scan-root", volume: volumeA, children: (0..<directories).map { index in
            .directory(String(format: "d%03d", index), volume: volumeA, children: [
                .file("f.bin", bytes: Int64(index + 1), volume: volumeA)
            ])
        })
    }

    private var expectedWideTotal: Int64 { (1...60).reduce(0) { $0 + Int64($1) } }

    func test_progressIsThrottledToTheDocumentedInterval() async {
        let clock = VirtualClock()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            clock: clock,
            advancePerRequest: 0.02
        )

        let events = await runScan(
            probe,
            options: ScanOptions(
                progressInterval: ScanOptions.defaultProgressInterval,
                clock: clock
            )
        )

        guard let lastProgress = events.progressSnapshots.last else {
            return XCTFail("expected snapshots")
        }

        let elapsed = lastProgress.elapsed
        XCTAssertGreaterThan(elapsed, 1.0, "the fixture must span several windows")

        // `sequence` counts what the *engine* emitted, before any coalescing on
        // the way to this consumer — so it is the rate itself.
        let progressBudget = UInt64(elapsed / ScanOptions.defaultProgressInterval) + 2
        XCTAssertLessThanOrEqual(lastProgress.sequence, progressBudget,
                                 "\(lastProgress.sequence) emissions over \(elapsed)s exceeds ~15 Hz")

        // Delivered snapshots are spaced by at least the window — all
        // but the last, which is the forced exact final frame and is allowed to
        // land early.
        let elapsedTimes = events.progressSnapshots.dropLast().map(\.elapsed)
        for (earlier, later) in zip(elapsedTimes, elapsedTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, 1.0 / 15.0 - 1e-9)
        }
        XCTAssertGreaterThan(elapsedTimes.count, 3, "the fixture must produce a real progression")
    }

    func test_anInfiniteIntervalEmitsExactlyOneExactReading() async {
        let clock = VirtualClock()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            clock: clock,
            advancePerRequest: 0.02
        )

        let events = await runScan(
            probe,
            options: ScanOptions(progressInterval: .infinity, clock: clock)
        )

        XCTAssertEqual(events.progressSnapshots.count, 1)
        XCTAssertEqual(events.progressSnapshots.first?.sequence, 1)
        XCTAssertEqual(events.progressSnapshots.first?.attributedDiskBytes, expectedWideTotal)
        XCTAssertEqual(events.result?.root.subtreeDiskBytes, expectedWideTotal)
    }

    func test_theFinalReadingIsExactWhateverTheInterval() async {
        let clock = VirtualClock()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            clock: clock,
            advancePerRequest: 0.02
        )

        let events = await runScan(
            probe,
            options: ScanOptions(progressInterval: ScanOptions.defaultProgressInterval, clock: clock)
        )

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(events.progressSnapshots.last?.attributedDiskBytes, result.root.subtreeDiskBytes)
        XCTAssertEqual(events.progressSnapshots.last?.filesSeen, 60)
        XCTAssertEqual(events.progressSnapshots.last?.directoriesSeen, 61)
        XCTAssertEqual(result.root.fileCount, 60)
    }

    /// A consumer that looks away must come back to the newest snapshot, not to
    /// a queue of stale ones — while `.started` and the terminal event, which
    /// carry the contract, are never dropped.
    func test_aSlowConsumerReceivesTheNewestSnapshotNotABacklog() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: wideTree())
        let scanner = Scanner()
        let stream = await scanner.scan(makeRequest(
            probe: probe,
            options: ScanOptions(progressInterval: 0)
        ))

        // Look away while the scan runs.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let events = await collectEvents(stream)

        guard let lastProgress = events.progressSnapshots.last else { return XCTFail("expected snapshots") }
        XCTAssertEqual(events.startedEvents.count, 1, ".started is never superseded")
        XCTAssertEqual(events.terminalEvents.count, 1, "the terminal event is never superseded")
        XCTAssertLessThan(
            events.progressSnapshots.count, Int(lastProgress.sequence),
            "the engine emitted \(lastProgress.sequence) snapshots; a backlog would have delivered all of them"
        )
        XCTAssertEqual(lastProgress.attributedDiskBytes, expectedWideTotal, "what survives is the newest, and it is exact")

        let sequences = events.progressSnapshots.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted(), "no stale snapshot arrives after a newer one")
        XCTAssertEqual(sequences.count, Set(sequences).count)
    }

    // MARK: - The completion fraction

    func test_aFolderScanNeverCarriesACompletionFraction() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            volumeInfo: VolumeInfo(isLocal: true, capacity: VolumeCapacity(totalBytes: 10_000, availableBytes: 1_000))
        )

        let events = await runScan(probe, mode: .folder)

        XCTAssertFalse(events.progressSnapshots.isEmpty)
        for snapshot in events.progressSnapshots {
            XCTAssertNil(snapshot.approximateFraction, "a folder scan has nothing honest to divide by")
        }
        XCTAssertNil(events.result?.volumeCapacity)
    }

    /// Blocks counted over volume-used, and **never 100% until the scan has
    /// ended** (ticket 13). The fixture's total is exactly the used figure, so
    /// the last running snapshot would read 1.0 without the cap.
    func test_aRunningVolumeScanIsCappedBelowOneAndOnlyItsFinalSnapshotMayReachIt() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            volumeInfo: VolumeInfo(
                isLocal: true,
                capacity: VolumeCapacity(totalBytes: 2_000, availableBytes: 2_000 - 1_830)
            )
        )

        let events = await runScan(probe, mode: .volumeRoot)
        let snapshots = events.progressSnapshots
        let fractions = snapshots.compactMap(\.approximateFraction)

        XCTAssertEqual(fractions.count, snapshots.count, "an in-budget volume scan always has a fraction")
        for fraction in fractions.dropLast() {
            XCTAssertGreaterThanOrEqual(fraction, 0)
            XCTAssertLessThanOrEqual(fraction, 0.99, "a running scan claimed to be finished")
        }
        XCTAssertEqual(fractions.last, 1.0, "the terminal snapshot is the one that may say 100%")
        XCTAssertEqual(events.result?.root.subtreeDiskBytes, expectedWideTotal,
                       "the fraction is derived; no synthetic byte figure enters the tree")
    }

    /// The other failure direction: counted blocks pass the volume's used
    /// figure, so the percentage has no honest denominator left and is
    /// **withdrawn for the rest of the scan** rather than pinned at its ceiling
    /// (ticket 13). 1,830 bytes against 100 used.
    func test_aVolumeScanThatPassesVolumeUsedWithdrawsTheFractionForGood() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            volumeInfo: VolumeInfo(
                isLocal: true,
                capacity: VolumeCapacity(totalBytes: 1_000, availableBytes: 900)  // 100 bytes used
            )
        )

        let events = await runScan(probe, mode: .volumeRoot)
        let snapshots = events.progressSnapshots

        XCTAssertFalse(snapshots.isEmpty)
        for snapshot in snapshots {
            if let fraction = snapshot.approximateFraction {
                XCTAssertLessThanOrEqual(fraction, 0.99,
                                         "no snapshot before the withdrawal may claim to be finished")
            }
        }
        XCTAssertNil(snapshots.last?.approximateFraction,
                     "the withdrawal is for the rest of the scan, terminal snapshot included")

        // Withdrawn once, withdrawn thereafter: no snapshot carries a fraction
        // after the first one that does not.
        let withdrawnAt = snapshots.firstIndex { $0.approximateFraction == nil } ?? snapshots.startIndex
        for snapshot in snapshots[withdrawnAt...] {
            XCTAssertNil(snapshot.approximateFraction, "the fraction came back after being withdrawn")
        }

        XCTAssertEqual(events.result?.root.subtreeDiskBytes, expectedWideTotal,
                       "withdrawing the percentage changes nothing about what was counted")
    }

    /// The throughput reading is items per second, and it is a measurement:
    /// files plus directories over elapsed time (ticket 13).
    func test_throughputCountsItemsAndNotBytes() async {
        let clock = VirtualClock()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            clock: clock,
            advancePerRequest: 0.02
        )

        let events = await runScan(probe, options: ScanOptions(clock: clock))

        guard let last = events.progressSnapshots.last else { return XCTFail("expected snapshots") }
        XCTAssertGreaterThan(last.elapsed, 0)
        XCTAssertEqual(
            last.itemsPerSecond,
            Double(last.filesSeen + last.directoriesSeen) / last.elapsed,
            accuracy: 0.000_001
        )
    }
}
