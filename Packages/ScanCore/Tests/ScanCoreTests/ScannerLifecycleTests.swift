import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The event/state contract of spec §5.3: `idle → scanning → completed |
/// cancelled | failed`, `.failed` **only** at pre-flight, exactly one terminal
/// event, one active scan.
final class ScannerLifecycleTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    private func smallTree() -> ScriptedEntry {
        .directory("scan-root", volume: volumeA, children: [
            .file("a.bin", bytes: 100, volume: volumeA),
            .directory("sub", volume: volumeA, children: [
                .file("b.bin", bytes: 50, volume: volumeA)
            ])
        ])
    }

    // MARK: - Pre-flight is the only way to fail

    func test_rootThatDoesNotExistFailsPreFlight() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: smallTree(),
            metadataFailure: CocoaError(.fileNoSuchFile)
        )

        let events = await runScan(probe)

        XCTAssertEqual(events.failure, .rootMissing(scanRootURL))
        XCTAssertTrue(events.startedEvents.isEmpty, "pre-flight failure must not announce a scan")
        XCTAssertEqual(events.terminalEvents.count, 1)
        XCTAssertNil(events.result)
    }

    func test_rootThatIsNotADirectoryFailsPreFlight() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .file("scan-root", bytes: 10, volume: volumeA)
        )

        let events = await runScan(probe)

        XCTAssertEqual(events.failure, .rootNotDirectory(scanRootURL))
        XCTAssertTrue(probe.listedPaths.isEmpty, "an ineligible root is never listed")
    }

    func test_symbolicLinkRootFailsPreFlight() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .symlink("scan-root", looksLikeDirectory: true, volume: volumeA)
        )

        let events = await runScan(probe)
        XCTAssertEqual(events.failure, .rootNotDirectory(scanRootURL))
    }

    func test_networkVolumeRootFailsPreFlight() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: smallTree(),
            volumeInfo: VolumeInfo(isLocal: false)
        )

        let events = await runScan(probe)

        XCTAssertEqual(events.failure, .rootOnNetworkVolume(scanRootURL))
        XCTAssertTrue(probe.listedPaths.isEmpty)
    }

    func test_unreadableRootFailsPreFlightAsAccessDenied() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: smallTree(),
            metadataFailure: CocoaError(.fileReadNoPermission)
        )

        let events = await runScan(probe)
        XCTAssertEqual(events.failure, .rootAccessDenied(scanRootURL))
    }

    /// The other half of "only pre-flight": a directory that cannot be read
    /// *during* the scan is recorded and traversal carries on (spec §3.5).
    func test_midScanFailureNeverProducesFailed() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("locked", volume: volumeA, listFailure: CocoaError(.fileReadNoPermission), children: [
                .file("hidden-from-us.bin", bytes: 999, volume: volumeA)
            ]),
            .file("readable.bin", bytes: 100, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        let events = await runScan(probe)

        XCTAssertNil(events.failure, "a mid-scan problem is not a failed scan")
        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 1))
        XCTAssertEqual(result.root.subtreeDiskBytes, 100, "the unreadable subtree's size is never guessed")
        XCTAssertEqual(result.root.readState, .incomplete)
        XCTAssertEqual(node(result.root, at: "locked")?.readState, .unreadable)
        XCTAssertEqual(node(result.root, at: "readable.bin")?.readState, .complete)
        XCTAssertEqual(probe.listedPaths.sorted(), ["", "locked"], "a sibling's failure never stops the walk")
    }

    // MARK: - The happy path's shape

    func test_eligibleRootEmitsStartedThenExactlyOneTerminalEventThenEnds() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: smallTree())

        let events = await runScan(probe)

        XCTAssertEqual(events.startedEvents.count, 1)
        XCTAssertEqual(events.terminalEvents.count, 1)
        guard case .started(let root, let mode, let capacity)? = events.first else {
            return XCTFail("the first event must be .started")
        }
        XCTAssertEqual(root, scanRootURL)
        XCTAssertEqual(mode, .folder)
        XCTAssertNil(capacity, "a folder scan has no volume capacity to report")
        XCTAssertTrue(events.last?.isTerminal == true, "the terminal event is the last one, then the stream ends")
        XCTAssertEqual(events.result?.reason, .completed)
        XCTAssertEqual(events.result?.completeness, .exact)
    }

    func test_volumeScanReportsCapacitySeparatelyFromAttributedBytes() async {
        let capacity = VolumeCapacity(totalBytes: 1_000, availableBytes: 400)
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: smallTree(),
            volumeInfo: VolumeInfo(isLocal: true, capacity: capacity)
        )

        let events = await runScan(probe, mode: .volumeRoot)

        guard case .started(_, _, let reported)? = events.first else {
            return XCTFail("the first event must be .started")
        }
        XCTAssertEqual(reported, capacity)
        XCTAssertEqual(events.result?.volumeCapacity, capacity)
        XCTAssertEqual(events.result?.root.subtreeDiskBytes, 150, "capacity never becomes attributed bytes")
    }

    func test_snapshotsAreMonotonicAndInterleaveBeforeTheTerminalEvent() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: smallTree())

        let events = await runScan(probe)

        let indexOfTerminal = events.firstIndex(where: \.isTerminal)
        XCTAssertEqual(indexOfTerminal, events.count - 1)

        var lastBytes: Int64 = -1
        var lastSequence: UInt64 = 0
        for snapshot in events.progressSnapshots {
            XCTAssertGreaterThanOrEqual(snapshot.attributedDiskBytes, lastBytes)
            XCTAssertGreaterThan(snapshot.sequence, lastSequence)
            lastBytes = snapshot.attributedDiskBytes
            lastSequence = snapshot.sequence
        }

        var lastGeneration: UInt64 = 0
        for snapshot in events.treeSnapshots {
            XCTAssertGreaterThan(snapshot.generation, lastGeneration)
            lastGeneration = snapshot.generation
        }

        XCTAssertFalse(events.progressSnapshots.isEmpty)
        XCTAssertFalse(events.treeSnapshots.isEmpty)
    }

    // MARK: - One active scan

    func test_startingASecondScanCancelsTheFirstAndBeginsOnlyAfterItsTerminalEvent() async {
        let log = SharedLog()
        let gate = DispatchSemaphore(value: 0)
        let scanner = Scanner()

        let blockingProbe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .directory("scan-root", volume: volumeA, children: (0..<8).map {
                .directory("d\($0)", volume: volumeA, children: [.file("f.bin", bytes: 10, volume: volumeA)])
            }),
            beforeRequest: { request in
                log.append("A:\(request)")
                if request.kind == .list && request.path.isEmpty { gate.wait() }
            }
        )
        let secondProbe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: smallTree(),
            beforeRequest: { request in log.append("B:\(request)") }
        )

        let firstStream = await scanner.scan(makeRequest(probe: blockingProbe))
        let firstEvents = Task { await collectEvents(firstStream) }

        // Give the first scan time to reach the gate inside its root listing.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let secondStream = await scanner.scan(makeRequest(probe: secondProbe))
        let secondEvents = Task { await collectEvents(secondStream) }

        gate.signal()

        let first = await firstEvents.value
        let second = await secondEvents.value

        XCTAssertEqual(first.result?.reason, .cancelled, "the replaced scan ends cancelled")
        XCTAssertEqual(first.terminalEvents.count, 1)
        XCTAssertEqual(second.result?.reason, .completed, "the replacement runs to completion")
        XCTAssertEqual(second.result?.root.subtreeDiskBytes, 150)

        let lines = log.entries
        let lastFirst = lines.lastIndex(where: { $0.hasPrefix("A:") })
        let firstSecond = lines.firstIndex(where: { $0.hasPrefix("B:") })
        XCTAssertNotNil(lastFirst)
        XCTAssertNotNil(firstSecond)
        XCTAssertLessThan(lastFirst!, firstSecond!, "the two scans never overlap on the device")
    }
}
