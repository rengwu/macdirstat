import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Exclusions (spec §3.4, §3.5): things the scan deliberately did not count.
/// Nothing went wrong — a policy chose to skip them — so they are counted
/// separately from errors and never make an ancestor Incomplete.
final class ExclusionTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")
    private let volumeB = FileSystemIdentity("volume-B")

    // MARK: - Cloud materialization gating

    func test_onlyLocallyMaterializedCloudItemsAreCounted() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("current.bin", bytes: 100, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: .current),
            .file("downloaded.bin", bytes: 200, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: .downloaded),
            .file("remote-only.bin", bytes: 4_000_000, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: .notDownloaded),
            // A third-party file provider that surfaces no status at all: the
            // conservative reading is that what is there is local.
            .file("unavailable.bin", bytes: 50, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: nil)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeBytes, 350, "the placeholder's advertised size is not counted")
        XCTAssertEqual(node(result.root, at: "current.bin")?.ownBytes, 100)
        XCTAssertEqual(node(result.root, at: "downloaded.bin")?.ownBytes, 200)
        XCTAssertEqual(node(result.root, at: "unavailable.bin")?.ownBytes, 50)

        // Omitted, not zeroed: a remote-only placeholder has no node at all.
        XCTAssertNil(node(result.root, at: "remote-only.bin"))
        XCTAssertEqual(result.root.children.map(\.name),
                       ["current.bin", "downloaded.bin", "unavailable.bin"])
        XCTAssertEqual(result.root.fileCount, 3)

        XCTAssertEqual(result.exclusions.byReason, [.remoteOnlyCloud: 1])
        XCTAssertEqual(result.exclusions.total, 1)
        XCTAssertTrue(result.errors.isEmpty, "an exclusion is not an error")
        XCTAssertEqual(result.completeness, .exact,
                       "a policy exclusion does not make the tree Incomplete")
        XCTAssertEqual(result.root.readState, .complete)
    }

    /// The seam has no download method at all (`ReadOnlySeamTests`), so the
    /// remaining question is whether the engine *touched* the placeholder. The
    /// recorded request log answers it: it never asked about that path.
    func test_aRemoteOnlyPlaceholderIsNeverRequestedInAnyWay() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("local.bin", bytes: 10, volume: volumeA),
            .file("remote-only.bin", bytes: 1 << 30, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: .notDownloaded),
            .directory("remote-folder", volume: volumeA,
                       isUbiquitousItem: true, cloudStatus: .notDownloaded, children: [
                .file("inside.bin", bytes: 500, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeBytes, 10)
        XCTAssertEqual(result.exclusions.byReason, [.remoteOnlyCloud: 2])

        XCTAssertEqual(probe.listedPaths, [""], "a dataless folder is never listed — listing it would fetch it")
        for request in probe.requests {
            XCTAssertFalse(request.path.hasPrefix("remote"),
                           "the engine touched a remote-only placeholder: \(request)")
        }
        XCTAssertEqual(probe.requests.map(\.kind).filter { $0 == .metadata }.count, 1,
                       "only the root's metadata is ever read")
    }

    // MARK: - The device boundary

    func test_aDirectoryOnAnotherVolumeIsCountedAsABoundaryExclusion() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("here.bin", bytes: 64, volume: volumeA),
            .directory("mounted", volume: volumeB, children: [
                .file("theirs.bin", bytes: 9_000, volume: volumeB)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeBytes, 64)
        XCTAssertEqual(probe.listedPaths, [""], "nothing beneath the boundary is listed")
        XCTAssertNotNil(node(result.root, at: "mounted"), "the boundary itself stays visible")
        XCTAssertEqual(result.exclusions.byReason, [.crossedVolumeBoundary: 1])
        XCTAssertEqual(result.completeness, .exact, "a boundary is a policy, not a failure")
    }

    func test_exclusionReasonsAreCountedSeparately() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("mount-1", volume: volumeB),
            .directory("mount-2", volume: volumeB),
            .file("remote.bin", bytes: 1, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: .notDownloaded)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.exclusions.byReason, [.crossedVolumeBoundary: 2, .remoteOnlyCloud: 1])
        XCTAssertEqual(result.exclusions.total, 3)
    }

    // MARK: - Volume capacity is a separate fact

    func test_volumeCapacityIsReportedSeparatelyAndNeverAttributedToANode() async {
        let capacity = VolumeCapacity(totalBytes: 500_000_000_000, availableBytes: 120_000_000_000)
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("a.bin", bytes: 1_000, volume: volumeA),
            .directory("d", volume: volumeA, children: [
                .file("b.bin", bytes: 2_000, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: tree,
            volumeInfo: VolumeInfo(isLocal: true, capacity: capacity)
        )

        let events = await runScan(probe, mode: .volumeRoot)
        guard let result = events.result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.volumeCapacity, capacity)
        XCTAssertEqual(result.root.subtreeBytes, 3_000, "the tree carries measured bytes and nothing else")

        // No node anywhere carries capacity, free, or the used figure derived
        // from them — the "Unknown" synthetic byte count the spec forbids.
        let forbidden: Set<Int64> = [capacity.totalBytes, capacity.availableBytes, capacity.usedBytes]
        var stack: [ScanNode] = [result.root]
        while let node = stack.popLast() {
            XCTAssertFalse(forbidden.contains(node.ownBytes), "\(node.name) carries a volume figure as own bytes")
            XCTAssertFalse(forbidden.contains(node.subtreeBytes), "\(node.name) carries a volume figure as a total")
            stack.append(contentsOf: node.children)
        }

        // It reaches the UI as its own fact on `.started` and on the result,
        // never folded into a total.
        guard case .started(_, _, let startedCapacity)? = events.startedEvents.first else {
            return XCTFail("expected a started event")
        }
        XCTAssertEqual(startedCapacity, capacity)
    }

    func test_aFolderScanCarriesNoVolumeCapacityAtAll() async {
        let capacity = VolumeCapacity(totalBytes: 400, availableBytes: 100)
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .directory("scan-root", volume: volumeA, children: [
                .file("a.bin", bytes: 300, volume: volumeA)
            ]),
            volumeInfo: VolumeInfo(isLocal: true, capacity: capacity)
        )

        guard let result = await runScan(probe, mode: .folder).result else {
            return XCTFail("expected a result")
        }

        XCTAssertNil(result.volumeCapacity)
        XCTAssertEqual(result.root.subtreeBytes, 300,
                       "a folder total that happens to equal capacity − free is a coincidence, not a source")
    }
}
