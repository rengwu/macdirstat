import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Progress honesty, spec §5.5: coalesced at ≤ ~15 Hz scalars and ≤ ~4 Hz tree,
/// buffering-newest under a slow consumer, an exact final snapshot whatever the
/// cadence, and no completion fraction for a folder scan.
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

    func test_emissionsAreThrottledToTheDocumentedCadences() async {
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
                progressCadence: .progressDefault,
                treeCadence: .treeDefault,
                clock: clock
            )
        )

        guard let lastProgress = events.progressSnapshots.last,
              let lastTree = events.treeSnapshots.last
        else { return XCTFail("expected snapshots") }

        let elapsed = lastProgress.elapsed
        XCTAssertGreaterThan(elapsed, 1.0, "the fixture must span several cadence windows")

        // `sequence`/`generation` count what the *engine* emitted, before any
        // coalescing on the way to this consumer — so they are the rate itself.
        let progressBudget = UInt64(elapsed / (1.0 / 15.0)) + 2
        let treeBudget = UInt64(elapsed / 0.25) + 2
        XCTAssertLessThanOrEqual(lastProgress.sequence, progressBudget,
                                 "\(lastProgress.sequence) scalar emissions over \(elapsed)s exceeds ~15 Hz")
        XCTAssertLessThanOrEqual(lastTree.generation, treeBudget,
                                 "\(lastTree.generation) tree emissions over \(elapsed)s exceeds ~4 Hz")
        XCTAssertGreaterThan(lastProgress.sequence, lastTree.generation,
                             "scalars must run faster than the tree")

        // Delivered snapshots are spaced by at least the scalar window — all
        // but the last, which is the forced exact final frame and is allowed to
        // land early.
        let elapsedTimes = events.progressSnapshots.dropLast().map(\.elapsed)
        for (earlier, later) in zip(elapsedTimes, elapsedTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, 1.0 / 15.0 - 1e-9)
        }
        XCTAssertGreaterThan(elapsedTimes.count, 3, "the fixture must produce a real progression")
    }

    func test_terminalOnlyCadenceEmitsExactlyOneExactSnapshotOfEachKind() async {
        let clock = VirtualClock()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            clock: clock,
            advancePerRequest: 0.02
        )

        let events = await runScan(
            probe,
            options: ScanOptions(progressCadence: .terminalOnly, treeCadence: .terminalOnly, clock: clock)
        )

        XCTAssertEqual(events.progressSnapshots.count, 1)
        XCTAssertEqual(events.treeSnapshots.count, 1)
        XCTAssertEqual(events.progressSnapshots.first?.sequence, 1)
        XCTAssertEqual(events.treeSnapshots.first?.generation, 1)
        XCTAssertEqual(events.progressSnapshots.first?.attributedBytes, expectedWideTotal)
        XCTAssertEqual(events.treeSnapshots.first?.root.subtreeBytes, expectedWideTotal)
        XCTAssertEqual(events.result?.root.subtreeBytes, expectedWideTotal)
    }

    func test_theFinalSnapshotIsExactWhateverTheCadence() async {
        let clock = VirtualClock()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            clock: clock,
            advancePerRequest: 0.02
        )

        let events = await runScan(
            probe,
            options: ScanOptions(progressCadence: .progressDefault, treeCadence: .treeDefault, clock: clock)
        )

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(events.progressSnapshots.last?.attributedBytes, result.root.subtreeBytes)
        XCTAssertEqual(events.progressSnapshots.last?.filesSeen, 60)
        XCTAssertEqual(events.progressSnapshots.last?.directoriesSeen, 61)
        XCTAssertEqual(events.treeSnapshots.last?.root.subtreeBytes, result.root.subtreeBytes)
        XCTAssertEqual(events.treeSnapshots.last?.root.fileCount, 60)
    }

    /// A consumer that looks away must come back to the newest snapshot, not to
    /// a queue of stale ones — while `.started` and the terminal event, which
    /// carry the contract, are never dropped.
    func test_aSlowConsumerReceivesTheNewestSnapshotNotABacklog() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: wideTree())
        let scanner = Scanner()
        let stream = await scanner.scan(makeRequest(
            probe: probe,
            options: ScanOptions(progressCadence: .everyChange, treeCadence: .everyChange)
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
        XCTAssertEqual(lastProgress.attributedBytes, expectedWideTotal, "what survives is the newest, and it is exact")

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

    func test_aVolumeScanCarriesAnApproximateClampedFraction() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: wideTree(),
            volumeInfo: VolumeInfo(
                isLocal: true,
                capacity: VolumeCapacity(totalBytes: 1_000, availableBytes: 900)  // 100 bytes used
            )
        )

        let events = await runScan(probe, mode: .volumeRoot)

        let fractions = events.progressSnapshots.compactMap(\.approximateFraction)
        XCTAssertEqual(fractions.count, events.progressSnapshots.count)
        for fraction in fractions {
            XCTAssertGreaterThanOrEqual(fraction, 0)
            XCTAssertLessThanOrEqual(fraction, 1.0, "the approximation is clamped, never over 100%")
        }
        // 1,830 logical bytes against 100 "used" bytes — the drift the spec
        // calls out, absorbed by the clamp rather than shown as 1,830%.
        XCTAssertEqual(fractions.last, 1.0)
        XCTAssertEqual(events.result?.root.subtreeBytes, expectedWideTotal,
                       "the fraction is derived; no synthetic byte figure enters the tree")
    }
}
