import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The measurement contract of spec §3.1: one measure — logical `fileSizeKey`
/// bytes — rolled up incrementally to every ancestor, so every open directory's
/// total is live and correct at every instant, not only at the end.
final class AggregationTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    private func mixedTree() -> ScriptedEntry {
        .directory("scan-root", volume: volumeA, children: [
            .file("top.bin", bytes: 1_000, volume: volumeA),
            .directory("empty", volume: volumeA),
            .directory("docs", volume: volumeA, children: [
                .file("a.txt", bytes: 10, volume: volumeA),
                .file("b.txt", bytes: 20, volume: volumeA),
                .directory("nested", volume: volumeA, children: [
                    .file("deep.bin", bytes: 300, volume: volumeA)
                ])
            ]),
            .directory("media.app", volume: volumeA, isPackage: true, children: [
                .file("binary", bytes: 500, volume: volumeA),
                .directory("Resources", volume: volumeA, children: [
                    .file("art.png", bytes: 25, volume: volumeA)
                ])
            ])
        ])
    }

    func test_finalTotalsEqualAnIndependentManifestFold() async {
        let tree = mixedTree()
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        let events = await runScan(probe)

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.root.subtreeDiskBytes, expectedBytes(tree, rootVolume: volumeA))
        XCTAssertEqual(result.root.subtreeDiskBytes, 1_855)
        XCTAssertEqual(result.root.fileCount, expectedFileCount(tree, rootVolume: volumeA))
        XCTAssertEqual(result.root.subtreeDiskBytes, foldOwnDiskBytes(result.root))
    }

    func test_everyDirectoryTotalEqualsItsOwnDescendants() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: mixedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(node(result.root, at: "docs")?.subtreeDiskBytes, 330)
        XCTAssertEqual(node(result.root, at: "docs/nested")?.subtreeDiskBytes, 300)
        XCTAssertEqual(node(result.root, at: "empty")?.subtreeDiskBytes, 0)
        XCTAssertEqual(node(result.root, at: "media.app")?.subtreeDiskBytes, 525,
                       "a package is measured through, however it is later presented")
        XCTAssertEqual(node(result.root, at: "media.app")?.kind, .package)

        // Every directory in the tree, checked against its own leaves.
        var stack: [ScanNode] = [result.root]
        while let node = stack.popLast() {
            if node.isDirectoryLike {
                XCTAssertEqual(node.subtreeDiskBytes, foldOwnDiskBytes(node), "\(node.name) total disagrees with its leaves")
            }
            stack.append(contentsOf: node.children)
        }
    }

    /// Cadence zero: every change is published, so the invariant is checked at
    /// every event rather than only at the end.
    func test_atCadenceZeroEveryAncestorTotalIsMonotonicAndExactAtEveryEvent() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: mixedTree())

        let events = await runScan(
            probe,
            options: ScanOptions(progressCadence: .everyChange, treeCadence: .everyChange)
        )

        var previousTotals: [String: Int64] = [:]
        XCTAssertGreaterThan(events.treeSnapshots.count, 1, "cadence zero must publish a progression")

        for snapshot in events.treeSnapshots {
            // Exact: the rolled-up total is never ahead of what was attributed.
            XCTAssertEqual(snapshot.root.subtreeDiskBytes, foldOwnDiskBytes(snapshot.root))

            let totals = subtreeTotals(snapshot.root)
            for (path, total) in previousTotals {
                guard let now = totals[path] else {
                    return XCTFail("\(path) disappeared from a later snapshot")
                }
                XCTAssertGreaterThanOrEqual(now, total, "\(path) total went backwards")
            }
            previousTotals = totals
        }

        XCTAssertEqual(events.result?.root.subtreeDiskBytes, 1_855)
    }

    func test_sizesThatCannotBeReadAreNeverGuessed() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("known.bin", bytes: 700, volume: volumeA),
            .file("malformed.bin", bytes: nil, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 700)
        XCTAssertEqual(node(result.root, at: "malformed.bin")?.ownDiskBytes, 0)
        XCTAssertEqual(node(result.root, at: "malformed.bin")?.readState, .unreadable)
        XCTAssertEqual(result.root.readState, .incomplete)
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 1))
    }
}
