import ScanCore
import XCTest

/// What the engine asks of the filesystem, counted.
///
/// §8.2 refuses a wall-clock bar and commits to an *algorithmic* one instead:
/// single-pass, streaming, iterative DFS with prefetched keys and no redundant
/// metadata reads. That is a claim about operation counts, and these are the
/// operation counts. Nothing here asserts a duration.
///
/// The seam makes one of the four claims true by construction rather than by
/// test: `DirectoryProbe` has three methods — list, metadata, volume info — and
/// none of them returns file contents, so "no file-content reads" is a property
/// of the protocol, held there by `ScanCoreTests`' test over its own source
/// text. What is checked here is the numeric consequence: the engine performed
/// nothing *but* those three, and the third two exactly once each.
final class OperationCountTests: XCTestCase {

    // MARK: - One shallow list per traversed directory

    func test_everyDirectoryIsListedExactlyOnce() async throws {
        let workload = ScaleRungs.smoke
        let outcome = await ScaleScanDriver.run(workload, tracksListedPaths: true)
        let census = outcome.result.root.census()

        // Equality in both directions is the whole proof. Fewer listings than
        // directories would mean one went unvisited; more would mean one was
        // listed twice; the repeated-path counter catches a re-listing that
        // happened to be balanced by a directory that was skipped.
        XCTAssertEqual(outcome.operations.listCount, census.directories)
        XCTAssertEqual(outcome.operations.listCount, workload.manifest.directoryCount)
        XCTAssertEqual(outcome.operations.repeatedListCount, 0)
    }

    func test_theRootIsTheOnlyEntryWhoseMetadataIsFetched() async throws {
        let outcome = await ScaleScanDriver.run(ScaleRungs.smoke)

        // A child arrives fully described by its parent's listing, because the
        // production probe prefetches every key the engine reads (spec §8.2).
        // A second fetch for any of the 4,095 non-root entries would show here
        // — and the counting probe throws for a non-root metadata read, so it
        // would also have failed the scan rather than passing quietly.
        XCTAssertEqual(outcome.operations.metadataCount, 1)
        XCTAssertEqual(outcome.operations.volumeInfoCount, 1)
        XCTAssertEqual(
            outcome.operations.total,
            outcome.operations.listCount + 2,
            "the engine performed an operation that is neither a listing nor one of the two pre-flight reads"
        )
    }

    func test_everyEntryTheListingsReturnedBecameExactlyOneNode() async throws {
        let workload = ScaleRungs.smoke
        let outcome = await ScaleScanDriver.run(workload)
        let census = outcome.result.root.census()

        // Entries returned by listings, plus the root, is the node count: the
        // walk is single-pass, so nothing was visited twice and nothing the
        // filesystem offered was dropped.
        XCTAssertEqual(outcome.operations.entriesReturned + 1, census.entries)
        XCTAssertEqual(census.entries, workload.manifest.entryCount)
    }

    // MARK: - No descent across a device boundary (spec §3.3)

    func test_aDirectoryOnAnotherVolumeIsVisibleAndNeverListed() async throws {
        let workload = ScaleRungs.smokeWithVolumeBoundaries
        let outcome = await ScaleScanDriver.run(workload, tracksListedPaths: true)

        XCTAssertEqual(outcome.operations.foreignVolumeListCount, 0)
        // The decoys are entries — visible, counted as directories — but the
        // walk stops at them, so the listing count is the tree's count *less*
        // the four it refused to enter.
        XCTAssertEqual(outcome.operations.listCount, workload.manifest.directoryCount - 4)

        // Nothing went wrong, so this is an exclusion and not an error: the
        // ancestors stay Complete and the tree stays Exact (spec §3.5).
        XCTAssertEqual(outcome.result.exclusions.byReason[.crossedVolumeBoundary], 4)
        XCTAssertEqual(outcome.result.errors.total, 0)
        XCTAssertEqual(outcome.result.completeness, .exact)

        let decoys = outcome.result.root.children.filter { $0.name.hasPrefix("foreign-volume-") }
        XCTAssertEqual(decoys.count, 4)
        for decoy in decoys {
            XCTAssertTrue(decoy.children.isEmpty, "\(decoy.name) has descendants — the boundary was crossed")
            XCTAssertEqual(decoy.subtreeDiskBytes, 0)
            XCTAssertEqual(decoy.readState, .complete)
        }

        // And the boundary changed nothing about the bytes: the same 768 MiB
        // Smoke reports, with four extra entries beside it.
        XCTAssertEqual(outcome.result.root.subtreeDiskBytes, ScaleRungs.smoke.manifest.attributedBytes)
    }

    // MARK: - No second walk of a directory already visited (spec §3.3)

    /// The field report's shape, at Smoke's scale: four names repeating the
    /// identity of four directories the walk has already entered.
    ///
    /// A graft hands back the real subtree if anything lists it, so this rung
    /// reports Smoke's 768 MiB exactly when the guard holds, and about twice
    /// them when it does not — which is what a scan of `/` did before it.
    func test_aDirectoryReachedTwiceIsVisibleAndNeverListedASecondTime() async throws {
        let workload = ScaleRungs.smokeWithRepeatedDirectories
        let outcome = await ScaleScanDriver.run(workload, tracksListedPaths: true)

        XCTAssertEqual(outcome.operations.repeatedDirectoryListCount, 0)
        XCTAssertEqual(outcome.operations.repeatedListCount, 0)
        XCTAssertEqual(outcome.operations.listCount, workload.manifest.directoryCount - 4)

        // An exclusion, not an error, exactly like a device boundary.
        XCTAssertEqual(outcome.result.exclusions.byReason[.repeatedDirectory], 4)
        XCTAssertEqual(outcome.result.errors.total, 0)
        XCTAssertEqual(outcome.result.completeness, .exact)

        let grafts = outcome.result.root.children.filter { $0.name.hasPrefix("graft-") }
        XCTAssertEqual(grafts.count, 4)
        for graft in grafts {
            XCTAssertTrue(graft.children.isEmpty, "\(graft.name) was walked a second time")
            XCTAssertEqual(graft.subtreeDiskBytes, 0)
            XCTAssertEqual(graft.readState, .complete)
            guard case .directoryCountedElsewhere(let owner) = graft.attribution else {
                return XCTFail("\(graft.name) does not say where its bytes were counted")
            }
            XCTAssertEqual(owner?.count, 2, "the owner is a child of the scan root")
        }

        // The bytes are Smoke's, unchanged: four extra entries, not four extra
        // subtrees.
        XCTAssertEqual(outcome.result.root.subtreeDiskBytes, ScaleRungs.smoke.manifest.attributedBytes)
        XCTAssertEqual(outcome.result.root.census().entries, workload.manifest.entryCount)
    }

    // MARK: - Counts scale with entries and depth, not with bytes

    func test_ahundredfoldMoreBytesInTheSameShapeCostsExactlyTheSameOperations() async throws {
        let light = await ScaleScanDriver.run(ScaleRungs.smoke)
        let heavy = await ScaleScanDriver.run(ScaleRungs.smokeSameShapeHundredfoldBytes)

        XCTAssertEqual(
            heavy.result.root.subtreeDiskBytes,
            light.result.root.subtreeDiskBytes * 100,
            "the control rung is not actually a hundred times heavier"
        )
        XCTAssertEqual(heavy.operations, light.operations,
                       "operation counts moved with total bytes; §8.2 says they must not")
    }

    func test_operationCountsTrackDirectoryCountAcrossGeometricallyLargerInputs() async throws {
        var observed: [(entries: Int, directories: Int, operations: Int)] = []
        for workload in [ScaleRungs.smoke, ScaleRungs.smokeTimesFour, ScaleRungs.smokeTimesSixteen] {
            let outcome = await ScaleScanDriver.run(workload)
            observed.append((
                workload.manifest.entryCount,
                workload.manifest.directoryCount,
                outcome.operations.total
            ))
        }

        // Sixteen times the entries, sixteen times the listings, and the
        // relationship is exact rather than asymptotic: one list per directory
        // plus the two pre-flight reads, at every size.
        for measurement in observed {
            XCTAssertEqual(measurement.operations, measurement.directories + 2)
        }
        XCTAssertEqual(observed.map(\.entries), [4_096, 16_384, 65_536])
        XCTAssertEqual(observed[1].operations - 2, (observed[0].operations - 2) * 4)
        XCTAssertEqual(observed[2].operations - 2, (observed[0].operations - 2) * 16)
    }

    /// Depth, separately from breadth: a 64-level chain costs one listing per
    /// level and nothing per ancestor beyond that. An engine that re-read a
    /// parent on the way back up would show a quadratic count here.
    func test_aDeepChainCostsOneListingPerLevel() async throws {
        let workload = ScaleRungs.stressDeepChain
        let outcome = await ScaleScanDriver.run(workload, tracksListedPaths: true)

        XCTAssertEqual(outcome.operations.listCount, workload.depth + 1)
        XCTAssertEqual(outcome.operations.repeatedListCount, 0)
        XCTAssertEqual(outcome.operations.deepestListedDepth, workload.depth)
        XCTAssertEqual(outcome.result.root.census().maximumDirectoryDepth, workload.depth)
    }

    /// One flat directory of 100,000 entries is still one listing — the
    /// per-batch cancellation checkpoint must not turn into a re-read.
    func test_oneEnormousFlatDirectoryIsStillOneListing() async throws {
        let workload = ScaleRungs.stressFlatDirectory
        let outcome = await ScaleScanDriver.run(workload)

        XCTAssertEqual(outcome.operations.listCount, 1)
        XCTAssertEqual(outcome.operations.entriesReturned, workload.fileCount)
        XCTAssertEqual(outcome.result.root.subtreeDiskBytes, workload.manifest.attributedBytes)
    }
}
