import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The load-bearing traversal decisions of spec §5.4: serial, iterative,
/// depth-first, deterministic, one shallow listing per directory, and never a
/// step across the device boundary.
final class TraversalTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")
    private let volumeB = FileSystemIdentity("volume-B")

    private func orderedTree() -> ScriptedEntry {
        .directory("scan-root", volume: volumeA, children: [
            .file("zebra.bin", bytes: 3, volume: volumeA),
            .directory("beta", volume: volumeA, children: [
                .file("two.bin", bytes: 2, volume: volumeA),
                .file("one.bin", bytes: 1, volume: volumeA)
            ]),
            .file("alpha.bin", bytes: 4, volume: volumeA),
            .directory("Alpha", volume: volumeA, children: [
                .file("x.bin", bytes: 5, volume: volumeA)
            ])
        ])
    }

    func test_traversalIsDepthFirstInSortedOrder() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: orderedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(flatten(result.root), [
            "",
            "Alpha", "Alpha/x.bin",
            "alpha.bin",
            "beta", "beta/one.bin", "beta/two.bin",
            "zebra.bin"
        ])
        // The probe hands entries back in an order the engine must not trust;
        // the ordering above is the engine's own sort.
        XCTAssertEqual(probe.listedPaths, ["", "Alpha", "beta"],
                       "directories are listed in the same sorted, depth-first order")
    }

    func test_identicalRunsProduceIdenticalNodeOrderAndTotals() async {
        let tree = orderedTree()

        let first = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree))
        let second = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree))

        guard let a = first.result, let b = second.result else { return XCTFail("expected results") }
        XCTAssertEqual(flatten(a.root), flatten(b.root))
        XCTAssertEqual(subtreeTotals(a.root), subtreeTotals(b.root))
    }

    /// A chain far deeper than any call stack should be asked to carry — 15×
    /// the depth-64 stress shape, and deeper than `PATH_MAX` allows a real
    /// filesystem to nest. If the walk were recursive this is where it would
    /// die.
    ///
    /// The ceiling here is not the walk: releasing *any* class chain that deep
    /// is a recursive ARC teardown, and a cooperative-pool thread's 512 KB
    /// stack gives out somewhere past 1,000 levels. That is a property of deep
    /// linked structures in Swift, reproducible with three lines and no
    /// scanner, and it sits well beyond every shape this app can meet.
    func test_deepChainIsWalkedIterativelyWithoutRecursion() async {
        let depth = 1_000
        var chain = ScriptedEntry.directory("level-\(depth)", volume: volumeA, children: [
            .file("leaf.bin", bytes: 7, volume: volumeA)
        ])
        for level in stride(from: depth - 1, through: 1, by: -1) {
            chain = .directory("level-\(level)", volume: volumeA, children: [chain])
        }
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [chain])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        let events = await runScan(
            probe,
            options: ScanOptions(progressCadence: .terminalOnly, treeCadence: .terminalOnly)
        )

        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.root.subtreeDiskBytes, 7)
        XCTAssertEqual(result.root.fileCount, 1)
        XCTAssertEqual(probe.listedPaths.count, depth + 1, "one listing per directory, root included")

        var deepest = result.root
        var levels = 0
        while let child = deepest.children.first(where: \.isDirectoryLike) {
            deepest = child
            levels += 1
        }
        XCTAssertEqual(levels, depth)
        XCTAssertEqual(deepest.pathComponents().count, depth + 1)
    }

    // MARK: - One root, one device

    func test_nothingBeneathADifferingVolumeChildIsEverListed() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("own.bin", bytes: 100, volume: volumeA),
            .directory("mounted", volume: volumeB, children: [
                .directory("deeper", volume: volumeB, children: [
                    .file("elsewhere.bin", bytes: 9_000, volume: volumeB)
                ])
            ]),
            .directory("ours", volume: volumeA, children: [
                .file("kept.bin", bytes: 5, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertFalse(probe.listedPaths.contains { $0.hasPrefix("mounted") },
                       "the nested mount must never be listed: \(probe.listedPaths)")
        XCTAssertEqual(probe.listedPaths, ["", "ours"])
        XCTAssertEqual(result.root.subtreeDiskBytes, 105, "no attributed descendants beyond the boundary")
        let boundary = node(result.root, at: "mounted")
        XCTAssertNotNil(boundary, "the boundary directory stays visible")
        XCTAssertEqual(boundary?.children.count, 0)
        XCTAssertEqual(boundary?.subtreeDiskBytes, 0)
        XCTAssertEqual(result.root.subtreeDiskBytes, expectedBytes(tree, rootVolume: volumeA))
    }

    func test_noEntryIsReadTwice() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: orderedTree())

        _ = await runScan(probe)

        let lists = probe.requests.filter { $0.kind == .list }.map(\.path)
        XCTAssertEqual(lists.count, Set(lists).count, "a directory is listed exactly once: \(lists)")

        let metadataPaths = probe.requests.filter { $0.kind == .metadata }.map(\.path)
        XCTAssertEqual(metadataPaths, [""],
                       "only the root needs a metadata read; children arrive prefetched by their listing")

        XCTAssertEqual(probe.requests.filter { $0.kind == .volumeInfo }.count, 1)
    }
}
