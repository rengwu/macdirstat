import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Cancellation as an **operation bound**, not a millisecond SLA (spec §5.6):
/// checked per directory and per batch, everything discovered retained, open
/// ancestors Incomplete, and security-scoped access released exactly once.
final class CancellationTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    private func siblingDirectories(_ count: Int) -> ScriptedEntry {
        .directory("scan-root", volume: volumeA, children: (0..<count).map { index in
            .directory(String(format: "d%03d", index), volume: volumeA, children: [
                .file("f.bin", bytes: 10, volume: volumeA)
            ])
        })
    }

    /// Cancels the moment a listing is requested — the worst moment, just past
    /// a checkpoint — and counts what the engine did afterwards.
    func test_cancellationCostsAtMostOneMoreListing() async {
        let scanner = Scanner()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: siblingDirectories(8),
            beforeRequest: { request in
                if request.kind == .list && request.path == "d002" { scanner.cancel() }
            }
        )

        let stream = await scanner.scan(makeRequest(probe: probe))
        let events = await collectEvents(stream)

        XCTAssertEqual(probe.listedPaths, ["", "d000", "d001", "d002"],
                       "no listing beyond the one in flight: \(probe.listedPaths)")
        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertEqual(result.completeness, .incomplete(cancelled: true, unreadableEntries: 0))
    }

    func test_cancellationInsideOneHugeDirectoryCostsAtMostOneBatch() async {
        let scanner = Scanner()
        let flat = ScriptedEntry.directory("scan-root", volume: volumeA, children: (0..<5_000).map { index in
            .file(String(format: "f%05d.bin", index), bytes: 1, volume: volumeA)
        })
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: flat,
            beforeRequest: { request in
                if request.kind == .list { scanner.cancel() }
            }
        )

        let stream = await scanner.scan(makeRequest(
            probe: probe,
            options: ScanOptions(progressInterval: .infinity, cancellationBatchSize: 256)
        ))
        let events = await collectEvents(stream)

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.root.children.count, 256,
                       "one batch past the checkpoint, no matter how large the directory")
        XCTAssertEqual(result.root.subtreeDiskBytes, 256, "what was measured before the stop is kept")
        XCTAssertEqual(result.reason, .cancelled)
    }

    func test_cancellationMarksOpenAncestorsIncompleteAndKeepsEverythingDiscovered() async {
        let scanner = Scanner()
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("finished", volume: volumeA, children: [
                .file("a.bin", bytes: 5, volume: volumeA)
            ]),
            .directory("open", volume: volumeA, children: [
                .directory("deeper", volume: volumeA, children: [
                    .file("b.bin", bytes: 7, volume: volumeA)
                ]),
                .directory("never-reached", volume: volumeA, children: [
                    .file("c.bin", bytes: 9, volume: volumeA)
                ])
            ])
        ])
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: tree,
            beforeRequest: { request in
                if request.kind == .list && request.path == "open/deeper" { scanner.cancel() }
            }
        )

        let stream = await scanner.scan(makeRequest(probe: probe))
        let events = await collectEvents(stream)

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.reason, .cancelled)

        // Retained: everything discovered before the stop is still there.
        XCTAssertEqual(node(result.root, at: "finished/a.bin")?.ownDiskBytes, 5)
        XCTAssertEqual(node(result.root, at: "open/deeper/b.bin")?.ownDiskBytes, 7)
        XCTAssertEqual(result.root.subtreeDiskBytes, 12)
        // Nodes are materialized as entries are processed, so a listed-but-not-
        // yet-processed sibling has no node. That is what Incomplete on its
        // parent means — the alternative would be inventing nodes whose state
        // nothing has established.
        XCTAssertEqual(node(result.root, at: "open")?.children.map(\.name), ["deeper"])
        XCTAssertNil(node(result.root, at: "open/never-reached"))

        // Open ancestors are Incomplete; a directory that finished is not.
        XCTAssertEqual(result.root.readState, .incomplete)
        XCTAssertEqual(node(result.root, at: "open")?.readState, .incomplete)
        XCTAssertEqual(node(result.root, at: "finished")?.readState, .complete)
        XCTAssertEqual(node(result.root, at: "finished/a.bin")?.readState, .complete)

        // The whole tree is browsable, and every node in it can name its own
        // path — nothing was handed over with a broken parent chain.
        var stack: [ScanNode] = [result.root]
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            XCTAssertEqual(node.pathComponents().first, result.root.name,
                           "\(node.name) does not lead back to the root")
            stack.append(contentsOf: node.children)
        }
        XCTAssertGreaterThan(visited, 1)
    }

    func test_cancellationIsTerminalEvenWhenTheWalkHadAlreadyFinished() async {
        let scanner = Scanner()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .directory("scan-root", volume: volumeA, children: [
                .file("a.bin", bytes: 1, volume: volumeA)
            ]),
            beforeRequest: { request in
                if request.kind == .list { scanner.cancel() }
            }
        )

        let stream = await scanner.scan(makeRequest(probe: probe))
        let events = await collectEvents(stream)

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.reason, .cancelled, "a cancelled scan never later reports completed")
        XCTAssertEqual(result.completeness, .exact,
                       "…but the data is not called incomplete when the walk had in fact finished")
        XCTAssertEqual(result.root.subtreeDiskBytes, 1)
    }

    // MARK: - Security-scoped access is balanced exactly once

    func test_accessIsReleasedExactlyOnceOnSuccess() async {
        let spy = SpySecurityScopedAccess()
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: siblingDirectories(3))

        _ = await runScan(probe, access: spy)

        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1)
    }

    func test_accessIsReleasedExactlyOnceOnPreFlightFailure() async {
        let spy = SpySecurityScopedAccess()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: siblingDirectories(3),
            volumeInfo: VolumeInfo(isLocal: false)
        )

        let events = await runScan(probe, access: spy)

        XCTAssertNotNil(events.failure)
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1)
    }

    func test_accessIsReleasedExactlyOnceOnCancellation() async {
        let spy = SpySecurityScopedAccess()
        let scanner = Scanner()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: siblingDirectories(8),
            beforeRequest: { request in
                if request.kind == .list && request.path == "d001" { scanner.cancel() }
            }
        )

        let stream = await scanner.scan(makeRequest(probe: probe, access: spy))
        let events = await collectEvents(stream)

        XCTAssertEqual(events.result?.reason, .cancelled)
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1, "the cancellation handler and the exit path must not both release")
    }

    func test_cancellingTheConsumingTaskAlsoStopsTheScanAndReleasesAccessOnce() async {
        let spy = SpySecurityScopedAccess()
        let scanner = Scanner()
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: siblingDirectories(400))
        let stream = await scanner.scan(makeRequest(probe: probe, access: spy))

        let consumer = Task { await collectEvents(stream) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        _ = await consumer.value

        // The scan observes the cancellation at its next checkpoint, which is
        // an operation away, not a promise about milliseconds.
        for _ in 0..<200 where spy.stopCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.stopCount, 1)
    }
}
