import Darwin
import ScanCore
import TreemapLayout
import XCTest

/// Which quarter of the traversal an event arrived in.
///
/// The producer moves the phase forward from inside the walk, immediately
/// before the listing that crosses each barrier; the consumer stamps every
/// event it receives with whatever phase is current. A phase is *sticky*, so
/// any snapshot between two barriers belongs to the earlier one — which is what
/// makes the observation deterministic rather than a race against the emission
/// cadence.
final class TraversalPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to phase: Int) {
        lock.lock()
        value = phase
        lock.unlock()
    }
}

/// What arrived, per phase.
final class PhaseLog {
    struct Observation {
        var treeSnapshots = 0
        var progressSnapshots = 0
        var greatestAttributedBytes: Int64 = 0
        var greatestFilesSeen: Int64 = 0
        var greatestRootChildCount = 0
    }

    /// A node picked out of a mid-scan snapshot, with the facts it reported at
    /// the instant it was picked. Comparing those against the same object after
    /// the scan is what makes "the selection survived" a measurement rather
    /// than a re-reading of whatever the node says now.
    struct PickedNode {
        var node: ScanNode
        var pathComponents: [String]
        var subtreeBytes: Int64
        var fileCount: Int64
        var childCount: Int
    }

    private(set) var byPhase: [Int: Observation] = [:]
    private(set) var treeSnapshotsAfterTerminal = 0
    private(set) var sawTerminal = false
    private(set) var firstSharableSnapshot: TreeSnapshot?
    private(set) var pickedMidScan: PickedNode?

    func record(_ event: ScanEvent, phase: Int) {
        var observation = byPhase[phase] ?? Observation()
        switch event {
        case .progress(let snapshot):
            observation.progressSnapshots += 1
            observation.greatestAttributedBytes = max(
                observation.greatestAttributedBytes, snapshot.attributedBytes
            )
            observation.greatestFilesSeen = max(observation.greatestFilesSeen, snapshot.filesSeen)
        case .tree(let snapshot):
            if sawTerminal { treeSnapshotsAfterTerminal += 1 }
            observation.treeSnapshots += 1
            observation.greatestRootChildCount = max(
                observation.greatestRootChildCount, snapshot.root.children.count
            )
            // `isFrozen` cannot tell a shared subtree from a copied one: a
            // snapshot of an *open* node is a copy that is itself marked frozen
            // — correctly, since the copy will never change. What separates
            // them is position. The walk descends into a directory the instant
            // it appends it, so at any moment the only open child of the root
            // is its last one; every earlier child has already been finished
            // and frozen in place. Dropping the last child is therefore the
            // criterion, and it is conservative when the last child is a file.
            if firstSharableSnapshot == nil,
               let frozen = snapshot.root.children.dropLast().last(where: {
                   $0.isDirectoryLike && $0.children.contains { !$0.children.isEmpty }
               }) {
                firstSharableSnapshot = snapshot
                pickedMidScan = PickedNode(
                    node: frozen,
                    pathComponents: frozen.pathComponents(),
                    subtreeBytes: frozen.subtreeBytes,
                    fileCount: frozen.fileCount,
                    childCount: frozen.children.count
                )
            }
        case .finished, .failed:
            sawTerminal = true
        case .started:
            break
        }
        byPhase[phase] = observation
    }
}

/// Incremental results, shared snapshots, and the structural claims that make
/// the memory ceiling reachable in the first place.
///
/// §8.2 promises results "appear incrementally as discovered, never batched
/// until the end", and §8.4 explains how a million-node tree fits in memory:
/// name-only nodes, URLs rebuilt on demand, an identity index proportional to
/// multiply-linked inodes, and UI snapshots that share frozen subtrees by
/// reference. Each of those is a testable structural fact, and none of them is
/// a timing measurement.
final class IncrementalResultTests: XCTestCase {

    // MARK: - Barriers at 25 / 50 / 75%

    func test_smokeRungDeliversTreeAndProgressAtEveryQuarterOfTheWalk() async throws {
        try await assertIncrementalBarriers(for: ScaleRungs.smokeTimesSixteen)
    }

    func test_representativeRungDeliversTreeAndProgressAtEveryQuarterOfTheWalk() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        try await assertIncrementalBarriers(for: ScaleRungs.representative)
    }

    private func assertIncrementalBarriers(
        for workload: BalancedTreeWorkload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let manifest = workload.manifest
        let phase = TraversalPhase()
        let log = PhaseLog()
        // A fourth barrier at the last listing gives the tail of the walk — and
        // the exact final snapshot §5.5 promises whatever the cadence — a phase
        // of its own, so the 75% window cannot be credited with the finished
        // tree's numbers.
        let barriers = [
            manifest.directoryCount / 4,
            manifest.directoryCount / 2,
            manifest.directoryCount * 3 / 4,
            manifest.directoryCount - 1
        ]

        let outcome = await ScaleScanDriver.run(
            workload,
            // A stepping clock makes the cadence a function of traversal
            // position rather than of how fast this machine happens to be: one
            // hundredth of a second per directory, against a 0.25 s tree
            // cadence, is a snapshot every twenty-five directories.
            clockStep: 0.01,
            beforeList: { ordinal in
                guard let index = barriers.firstIndex(of: ordinal) else { return }
                phase.advance(to: index + 1)
                // A short pause so the consuming task is certainly scheduled
                // inside this phase's window. The window is a whole quarter of
                // the walk, so this is insurance rather than the mechanism.
                Thread.sleep(forTimeInterval: 0.02)
            },
            onEvent: { event in log.record(event, phase: phase.current) }
        )

        for quarter in 1...3 {
            let observation = try XCTUnwrap(
                log.byPhase[quarter],
                "no events at all in the \(quarter * 25)% window",
                file: file, line: line
            )
            XCTAssertGreaterThan(
                observation.treeSnapshots, 0,
                "no tree snapshot at \(quarter * 25)% — results are being batched until the end",
                file: file, line: line
            )
            XCTAssertGreaterThan(
                observation.progressSnapshots, 0,
                "no progress at \(quarter * 25)%", file: file, line: line
            )
            XCTAssertGreaterThan(
                observation.greatestAttributedBytes, 0,
                "the \(quarter * 25)% tree had no bytes in it", file: file, line: line
            )
            XCTAssertGreaterThan(
                observation.greatestRootChildCount, 0,
                "the \(quarter * 25)% tree had no children to show", file: file, line: line
            )
        }

        // Useful, not merely present: each quarter has seen strictly more than
        // the one before it.
        let bytes = (1...3).map { log.byPhase[$0]?.greatestAttributedBytes ?? 0 }
        let files = (1...3).map { log.byPhase[$0]?.greatestFilesSeen ?? 0 }
        XCTAssertLessThan(bytes[0], bytes[1], file: file, line: line)
        XCTAssertLessThan(bytes[1], bytes[2], file: file, line: line)
        XCTAssertLessThan(files[0], files[1], file: file, line: line)
        XCTAssertLessThan(files[1], files[2], file: file, line: line)

        // And every one of them arrived before the scan was over.
        XCTAssertEqual(log.treeSnapshotsAfterTerminal, 0, file: file, line: line)
        XCTAssertEqual(outcome.result.root.subtreeBytes, manifest.attributedBytes, file: file, line: line)
        XCTAssertLessThan(
            bytes[2], manifest.attributedBytes,
            "the 75% window saw the finished total — the phases are not separating the walk from its end",
            file: file, line: line
        )
        // The fourth phase is the tail, and it carries the exact final snapshot.
        XCTAssertEqual(
            log.byPhase[4]?.greatestAttributedBytes, manifest.attributedBytes,
            file: file, line: line
        )
    }

    // MARK: - Frozen subtrees are shared, not deep-copied (spec §5.2, §8.4)

    func test_aCompletedSubtreeIsTheSameObjectInEveryLaterSnapshot() async throws {
        let workload = ScaleRungs.smokeTimesSixteen
        let log = PhaseLog()
        let outcome = await ScaleScanDriver.run(
            workload,
            clockStep: 0.01,
            onEvent: { event in log.record(event, phase: 0) }
        )

        let midScan = try XCTUnwrap(
            log.firstSharableSnapshot,
            "no mid-scan snapshot ever contained a completed subdirectory"
        )
        let finalRoot = outcome.result.root

        // The root itself must *not* be shared: it was still open when the
        // snapshot was taken, so what crossed was a copy of the open spine
        // carrying that instant's partial totals.
        XCTAssertFalse(midScan.root === finalRoot)

        let frozenChild = try XCTUnwrap(log.pickedMidScan?.node, "the snapshot has no completed directory to compare")
        let sameChild = try XCTUnwrap(
            finalRoot.children.first { $0.name == frozenChild.name },
            "the final tree lost \(frozenChild.name)"
        )

        // Identity, not equality: a deep copy would compare equal in every
        // field and cost O(nodes) per emission, which is exactly the cost §5.2
        // says a 4 Hz tree feed cannot afford.
        XCTAssertTrue(
            frozenChild === sameChild,
            "\(frozenChild.name) was deep-copied into the snapshot instead of shared by reference"
        )

        // Sharing is of the whole subtree, not just its root.
        var comparedNodes = 0
        var stack: [(ScanNode, ScanNode)] = [(frozenChild, sameChild)]
        while let (left, right) = stack.popLast() {
            XCTAssertTrue(left === right)
            comparedNodes += 1
            XCTAssertEqual(left.children.count, right.children.count)
            for index in left.children.indices {
                stack.append((left.children[index], right.children[index]))
            }
        }
        XCTAssertGreaterThan(comparedNodes, 1)
    }

    // MARK: - Name-only nodes (spec §5.2, §8.4)

    func test_aNodeStoresOneNameAndAParentLinkAndNoAbsoluteURL() async throws {
        let workload = ScaleRungs.smoke
        let outcome = await ScaleScanDriver.run(workload)
        let root = outcome.result.root
        let deepest = try XCTUnwrap(deepestNode(under: root))

        let mirror = Mirror(reflecting: deepest)
        let storedTypes = mirror.children.map { String(describing: type(of: $0.value)) }
        XCTAssertFalse(
            storedTypes.contains { $0.contains("URL") },
            "ScanNode stores a URL: \(mirror.children.map { "\($0.label ?? "?"): \(type(of: $0.value))" })"
        )
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertTrue(labels.contains("name"))
        XCTAssertTrue(labels.contains("parent"))
        XCTAssertLessThanOrEqual(
            labels.count, 10,
            "ScanNode grew a stored property; every one of them is multiplied by two million at Large"
        )

        // One path component, and the absolute path is rebuilt from the chain
        // rather than remembered.
        var node: ScanNode? = deepest
        var chainLength = 0
        while let current = node {
            XCTAssertFalse(current.name.contains("/"), "\(current.name) is not a single component")
            node = current.parent
            chainLength += 1
        }
        let census = root.census()
        XCTAssertEqual(chainLength, census.maximumDepth + 1, "the parent chain does not reach the root")
        XCTAssertEqual(census.maximumDirectoryDepth, workload.manifest.maximumDepth)

        // The absolute URL is rebuilt from that chain, on demand, and matches
        // the one built independently from the components.
        let rootURL = ScaleScanDriver.rootURL(for: workload.manifest.rung)
        var rebuilt = rootURL
        for component in deepest.pathComponents().dropFirst() {
            rebuilt.appendPathComponent(component)
        }
        XCTAssertEqual(deepest.url(root: rootURL), rebuilt)
        XCTAssertEqual(deepest.url(root: rootURL).lastPathComponent, deepest.name)
    }

    // MARK: - The identity index stays proportional to multiply-linked inodes

    func test_onlyMultiplyLinkedInodesAreDeduplicated() async throws {
        let workload = ScaleRungs.stressHardLinks
        let manifest = workload.manifest
        let outcome = await ScaleScanDriver.run(workload)
        let census = outcome.result.root.census()

        XCTAssertEqual(census.files, manifest.fileCount)
        XCTAssertEqual(census.hardLinkDuplicates, manifest.hardLinkDuplicates)
        XCTAssertEqual(outcome.result.root.subtreeBytes, manifest.attributedBytes)
        // Deduplicated names are still entries: one item each, zero bytes.
        XCTAssertEqual(outcome.result.root.fileCount, Int64(manifest.fileCount))

        // The observable half of the memory claim. Five hundred pairs of files
        // share an identity while reporting `linkCount == 1`; every one of the
        // thousand names owns its bytes, so none of them was ever put in the
        // index. An engine that indexed by identity alone would be short by
        // 500 × 64 KiB here and would hold 500 more inodes than it needs.
        let colliding = outcome.result.root.children.filter { $0.name.hasPrefix("unlinked-collision-") }
        XCTAssertEqual(colliding.count, workload.collidingNameCount)
        for node in colliding {
            XCTAssertEqual(node.attribution, .owned, "\(node.name) was deduplicated on a link count of 1")
            XCTAssertEqual(node.ownBytes, workload.ordinaryBytes)
        }

        // Every duplicate points at the owner it was deduplicated against, and
        // the owner is the lexicographically first name for that inode.
        let duplicates = outcome.result.root.children.filter {
            if case .hardLinkElsewhere = $0.attribution { return true }
            return false
        }
        XCTAssertEqual(duplicates.count, manifest.hardLinkDuplicates)
        for duplicate in duplicates.prefix(50) {
            guard case .hardLinkElsewhere(let owner) = duplicate.attribution else {
                return XCTFail("\(duplicate.name) lost its attribution")
            }
            let ownerName = try XCTUnwrap(owner?.last)
            XCTAssertTrue(ownerName.hasSuffix("-000.bin"), "\(duplicate.name) points at \(ownerName)")
            XCTAssertEqual(duplicate.ownBytes, 0)
        }
    }

    // MARK: - Still usable: selection and cancel, mid-scan

    func test_aNodePickedOutOfAMidScanSnapshotIsStillValidAfterTheScan() async throws {
        let workload = ScaleRungs.smokeTimesSixteen
        let log = PhaseLog()
        let outcome = await ScaleScanDriver.run(
            workload,
            clockStep: 0.01,
            onEvent: { event in log.record(event, phase: 0) }
        )

        let midScan = try XCTUnwrap(log.firstSharableSnapshot)
        let picked = try XCTUnwrap(log.pickedMidScan)

        // This is what a selection *is* in this app: a `ScanNode` identity
        // (spec §10). Holding one from a snapshot taken while the scan was
        // still running, and finding every fact it reported then unchanged
        // afterwards, is the whole "still usable" claim — minus the wall clock
        // §8.3 declines to bar.
        XCTAssertEqual(picked.node.pathComponents(), picked.pathComponents)
        XCTAssertEqual(picked.node.subtreeBytes, picked.subtreeBytes)
        XCTAssertEqual(picked.node.fileCount, picked.fileCount)
        XCTAssertEqual(picked.node.children.count, picked.childCount)

        // Its parent is the *live* root, not the snapshot's copy of the root:
        // a shared frozen subtree keeps pointing into the tree it was built in,
        // which is exactly why `TreeSnapshot` retains that tree (spec §5.2).
        XCTAssertFalse(picked.node.parent === midScan.root)
        XCTAssertTrue(picked.node.parent === outcome.result.root)

        let rootURL = ScaleScanDriver.rootURL(for: workload.manifest.rung)
        XCTAssertEqual(
            picked.node.url(root: rootURL),
            rootURL.appendingPathComponent(picked.node.name)
        )

        // And the same object is what the finished tree hands back.
        let final = try XCTUnwrap(outcome.result.root.children.first { $0.name == picked.node.name })
        XCTAssertTrue(final === picked.node)

        // A click on the treemap would have resolved to something, too: the
        // mid-scan snapshot lays out and hit-tests like any other tree.
        let layout = TreemapLayout.layout(
            tree: ScanNodeTreemapRef(node: midScan.root),
            viewport: TreemapSize(width: 1_200, height: 800)
        )
        XCTAssertGreaterThan(layout.statistics.visibleBoxCount, 0)
        XCTAssertNotNil(layout.box(at: TreemapPoint(x: 600, y: 400)))
    }

    func test_cancellingHalfwayKeepsEverythingDiscoveredAndMarksTheOpenSpineIncomplete() async throws {
        let workload = ScaleRungs.smokeTimesSixteen
        let manifest = workload.manifest
        let outcome = await ScaleScanDriver.run(
            workload,
            clockStep: 0.01,
            cancelAfterListings: manifest.directoryCount / 2
        )

        XCTAssertEqual(outcome.result.reason, .cancelled)
        guard case .incomplete(let cancelled, _) = outcome.result.completeness else {
            return XCTFail("a cancelled scan reported \(outcome.completenessDescription)")
        }
        XCTAssertTrue(cancelled)

        // Cancellation is an *operation* bound, not a millisecond one
        // (spec §5.6, §9.3): at most one further listing after the request.
        XCTAssertLessThanOrEqual(outcome.operations.listCount, manifest.directoryCount / 2 + 1)

        // Partial results are results: everything discovered is still there,
        // and the walk stopped roughly where it was told to.
        let census = outcome.result.root.census()
        XCTAssertGreaterThan(census.entries, 1)
        XCTAssertLessThan(census.entries, manifest.entryCount)
        XCTAssertGreaterThan(outcome.result.root.subtreeBytes, 0)
        XCTAssertLessThan(outcome.result.root.subtreeBytes, manifest.attributedBytes)
        XCTAssertEqual(outcome.result.root.readState, .incomplete)
        XCTAssertEqual(outcome.result.errors.total, 0, "cancelling is not an error")

        // And it is still browsable and selectable afterwards.
        let deepest = try XCTUnwrap(deepestNode(under: outcome.result.root))
        XCTAssertFalse(deepest.pathComponents().isEmpty)
    }

    // MARK: - The recursive-teardown bound

    /// The deep-chain rung against the ceiling the map records for it.
    ///
    /// Releasing a `ScanNode` chain is a recursive ARC teardown — each node's
    /// deinit releases its children array — so it is bounded by the releasing
    /// thread's stack, which the map puts at roughly 1,000 levels on a 512 KB
    /// cooperative-pool thread. That is a recorded bound rather than a defect,
    /// and the map asks this suite to confirm the stress rung stays clear of
    /// it. It does, twice over: 64 levels is about fifteen times under the
    /// stack bound, and a real filesystem would refuse the path long before
    /// either — `PATH_MAX` is 1,024 bytes and this chain's deepest absolute
    /// path is already most of the way there.
    func test_theDeepChainRungStaysWellClearOfTheRecursiveTeardownBound() async throws {
        let workload = ScaleRungs.stressDeepChain
        let rootURL = ScaleScanDriver.rootURL(for: workload.manifest.rung)
        var deepestPathLength = 0
        var deepestDepth = 0

        // A scope, so the release — the operation actually under test — happens
        // here and a stack overflow would fail this test rather than some later
        // one.
        await { () async -> Void in
            let outcome = await ScaleScanDriver.run(workload)
            let deepest = try? XCTUnwrap(self.deepestNode(under: outcome.result.root))
            deepestPathLength = deepest?.url(root: rootURL).path.count ?? 0
            deepestDepth = outcome.result.root.census().maximumDirectoryDepth
        }()

        let recordedTeardownBoundLevels = 1_000
        XCTAssertEqual(deepestDepth, 64)
        XCTAssertLessThan(
            deepestDepth * 15, recordedTeardownBoundLevels,
            "the chain is no longer fifteen times clear of the ~\(recordedTeardownBoundLevels)-level "
                + "recursive-teardown bound the map records"
        )
        XCTAssertLessThan(
            deepestPathLength, Int(PATH_MAX),
            "the generated chain's deepest path no longer fits in PATH_MAX, so no real "
                + "filesystem could stage it — the rung has stopped modelling anything reachable"
        )
        XCTAssertGreaterThan(deepestPathLength, 700, "the chain got shallower without anybody noticing")
    }

    // MARK: - Error storms stay bounded (spec §5.7, §9.3)

    func test_twoThousandFiveHundredInjectedFailuresAreCountedExactlyAndDetailedUpToTheCap() async throws {
        let workload = ScaleRungs.stressInjectedFailures
        let outcome = await ScaleScanDriver.run(workload)

        XCTAssertEqual(outcome.result.reason, .completed)
        XCTAssertEqual(outcome.result.errors.total, 2_500)
        XCTAssertEqual(outcome.result.errors.details.count, 1_000)
        XCTAssertTrue(outcome.result.errors.truncated)
        XCTAssertEqual(outcome.result.errors.byCategory[.unreadableDirectory], 1_250)
        XCTAssertEqual(outcome.result.errors.byCategory[.unreadableEntry], 1_250)
        XCTAssertNil(outcome.result.errors.byCategory[.disappeared])
        XCTAssertEqual(outcome.result.completeness, .incomplete(cancelled: false, unreadableEntries: 2_500))
        XCTAssertEqual(outcome.result.root.subtreeBytes, workload.manifest.attributedBytes)
    }

    // MARK: - Helpers

    private func deepestNode(under root: ScanNode) -> ScanNode? {
        var best: ScanNode?
        var bestDepth = -1
        var stack: [(ScanNode, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            if depth > bestDepth {
                bestDepth = depth
                best = node
            }
            for child in node.children { stack.append((child, depth + 1)) }
        }
        return best
    }
}
