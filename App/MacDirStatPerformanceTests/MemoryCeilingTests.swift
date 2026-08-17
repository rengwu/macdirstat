import Darwin
import ScanCore
import XCTest

/// The one memory acceptance bar: **fits in 8 GB, never OOMs** (spec §8.4).
///
/// Everything else in §8 is deliberately unmeasured — no completion-time SLA,
/// no throughput number, no UI latency percentile — so this is the only rung of
/// the ladder that can actually fail on a number. It is asserted on
/// `phys_footprint`, the figure macOS itself charges the process and acts on
/// under pressure, and it is asserted absolutely rather than as a delta:
/// the machine has to survive the whole process, not this test's share of it.
///
/// Every rung also writes a record (OS, hardware, generator version, seed,
/// entry count, logical bytes, operation counts, peak footprint, terminal
/// state, diagnostic elapsed time), because a bar that passes without leaving
/// a number behind cannot be compared with next month's run.
final class MemoryCeilingTests: XCTestCase {
    /// §8.4's ceiling, exactly.
    private let ceilingBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    // MARK: - The three size rungs

    func test_smokeRungStaysWellUnderTheCeiling() async throws {
        await runRungAndAssertCeiling(ScaleRungs.smoke)
    }

    func test_representativeRungFinishesBelowEightGibibytes() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        await runRungAndAssertCeiling(ScaleRungs.representative)
    }

    func test_largeRungFinishesBelowEightGibibytes() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        await runRungAndAssertCeiling(ScaleRungs.large)
    }

    // MARK: - The four stress shapes

    func test_stressFlatDirectoryFinishesBelowEightGibibytes() async throws {
        await runRungAndAssertCeiling(ScaleRungs.stressFlatDirectory)
    }

    func test_stressDeepChainFinishesBelowEightGibibytes() async throws {
        await runRungAndAssertCeiling(ScaleRungs.stressDeepChain)
    }

    func test_stressHugeFileFinishesBelowEightGibibytes() async throws {
        await runRungAndAssertCeiling(ScaleRungs.stressHugeFile)
    }

    func test_stressHardLinksFinishesBelowEightGibibytes() async throws {
        await runRungAndAssertCeiling(ScaleRungs.stressHardLinks)
    }

    func test_stressInjectedFailuresFinishesBelowEightGibibytes() async throws {
        await runRungAndAssertCeiling(ScaleRungs.stressInjectedFailures)
    }

    /// The rung whose grafts the visited-directory index has to catch: a guard
    /// that leaked would show as four extra subtrees here, in the entry-count
    /// assertion, before it ever showed as memory.
    func test_repeatedDirectoriesFinishBelowEightGibibytes() async throws {
        await runRungAndAssertCeiling(ScaleRungs.smokeWithRepeatedDirectories)
    }

    // MARK: - What the visited-directory guard costs

    /// The guard that stops a scan of `/` counting the disk twice keeps one
    /// dictionary entry per directory **descended** — not per entry — and this
    /// is the number.
    ///
    /// Measured as a difference between two runs of one rung: the ordinary one,
    /// where every directory carries a `fileResourceIdentifier` as a real
    /// filesystem reports, and a control where the identity is built and
    /// discarded rather than carried. Same tree, same entries, same
    /// allocations; the only difference is what the engine retained.
    ///
    /// Both figures go into the record, so a reader can subtract them again
    /// rather than take this test's word for it. The bar is an upper bound on
    /// the difference, because that is the only direction the claim runs — noise
    /// in a shared host process can make one rung's delta look smaller than the
    /// other's, but it cannot make the index cost kilobytes per directory
    /// without showing up here.
    func test_theVisitedDirectoryGuardCostsBoundedMemoryPerDirectory() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)

        let indexed = ScaleRungs.representative
        let control = indexed.withoutDirectoryIdentities()
        let directories = indexed.manifest.directoryCount

        // The control runs **first**, deliberately. Both rungs share one host
        // process, and macOS's allocator does not hand freed pages straight
        // back, so a rung that runs second is measured against an arena the
        // first one already grew: any footprint the index really costs has to
        // exceed that arena to show up at all.
        let withoutIndex = await measureRung(control)
        let withIndex = await measureRung(indexed)

        let difference = Int64(withIndex) - Int64(withoutIndex)
        let bytesPerDirectory = Double(difference) / Double(directories)
        XCTAssertLessThan(
            bytesPerDirectory, 512,
            """
            the visited-directory index cost \(String(format: "%.0f", bytesPerDirectory)) bytes per \
            directory across \(directories) directories \
            (\(withIndex.formattedAsGibibytes) indexed against \
            \(withoutIndex.formattedAsGibibytes) unindexed) — at the ~1.4 M directories of a whole-Mac \
            scan that would be \(String(format: "%.2f", bytesPerDirectory * 1_400_000 / 1_073_741_824)) GiB.
            """
        )
        XCTAssertLessThan(withIndex, ceilingBytes)
    }

    /// One rung, run and released, reporting only its peak footprint. The tree
    /// is dropped and the allocator's free pages returned before the caller
    /// compares two of these.
    private func measureRung(_ workload: ScaleWorkload) async -> UInt64 {
        var peak: UInt64 = 0
        await { () async -> Void in
            let outcome = await ScaleScanDriver.run(workload)
            XCTAssertEqual(outcome.result.reason, .completed, "\(workload.manifest.rung)")
            XCTAssertEqual(
                outcome.result.root.subtreeDiskBytes, workload.manifest.attributedBytes,
                "\(workload.manifest.rung) attributed the wrong number of bytes"
            )
            peak = outcome.memory.peak.physicalFootprint
            PerformanceRecordStore.shared.append(
                ScaleScanDriver.record(
                    outcome,
                    manifest: workload.manifest,
                    hardLinkDuplicates: outcome.result.root.census().hardLinkDuplicates
                ),
                attachingTo: self
            )
        }()
        autoreleasepool {}
        malloc_zone_pressure_relief(nil, 0)
        return peak
    }

    // MARK: - Cancel keeps working on the biggest rungs

    /// "Still usable" at Representative and Large, as an operation bound rather
    /// than a timing one (§8.3, §5.6): cancellation lands within one further
    /// listing, the partial tree is retained, and a node picked out of it is
    /// still selectable afterwards.
    func test_cancelStillLandsWithinOneListingOnTheHeaviestRungs() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)

        for workload in [ScaleRungs.representative, ScaleRungs.large] {
            let manifest = workload.manifest
            let cancelAt = manifest.directoryCount / 2
            let outcome = await ScaleScanDriver.run(workload, cancelAfterListings: cancelAt)

            XCTAssertEqual(outcome.result.reason, .cancelled, "\(manifest.rung)")
            XCTAssertLessThanOrEqual(outcome.operations.listCount, cancelAt + 1, "\(manifest.rung)")
            XCTAssertGreaterThan(outcome.result.root.subtreeDiskBytes, 0, "\(manifest.rung)")
            XCTAssertEqual(outcome.result.root.readState, .incomplete, "\(manifest.rung)")
            XCTAssertLessThan(
                outcome.memory.peak.physicalFootprint, ceilingBytes,
                "\(manifest.rung) cancelled: peak footprint "
                    + outcome.memory.peak.physicalFootprint.formattedAsGibibytes
            )

            let picked = try XCTUnwrap(outcome.result.root.children.first { !$0.children.isEmpty })
            XCTAssertFalse(picked.pathComponents().isEmpty)
        }
    }

    // MARK: - The measurement itself

    /// Runs one rung, asserts the ceiling and the manifest, and files the
    /// record.
    ///
    /// The tree is released before the record is written, so the *next* rung's
    /// baseline is not this rung's tree — every rung runs in the one host
    /// process, and XCTest does not promise an order.
    private func runRungAndAssertCeiling(
        _ workload: ScaleWorkload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let manifest = workload.manifest
        var record: RungRecord?

        // A nested scope, so the tree is released here rather than at the end
        // of the test method: the next rung's baseline must not be this rung's
        // two million nodes. `autoreleasepool` cannot wrap an `await`, so the
        // scope does the work and the pool is drained around it.
        await { () async -> Void in
            let outcome = await ScaleScanDriver.run(workload)

            XCTAssertEqual(outcome.result.reason, .completed, "\(manifest.rung)", file: file, line: line)
            XCTAssertEqual(
                outcome.result.root.subtreeDiskBytes, manifest.attributedBytes,
                "\(manifest.rung) attributed the wrong number of bytes", file: file, line: line
            )
            let census = outcome.result.root.census()
            XCTAssertEqual(census.entries, manifest.entryCount, "\(manifest.rung)", file: file, line: line)
            XCTAssertEqual(
                census.unreadable, manifest.unreadableEntries,
                "\(manifest.rung)", file: file, line: line
            )

            XCTAssertLessThan(
                outcome.memory.peak.physicalFootprint, ceilingBytes,
                """
                \(manifest.rung) exceeded the §8.4 ceiling: peak physical footprint \
                \(outcome.memory.peak.physicalFootprint.formattedAsGibibytes) \
                (delta \(outcome.memory.footprintDelta.formattedAsGibibytes), \
                \(String(format: "%.0f", Double(outcome.memory.footprintDelta) / Double(manifest.entryCount))) \
                bytes per entry) against a ceiling of \(ceilingBytes.formattedAsGibibytes).
                """,
                file: file, line: line
            )

            record = ScaleScanDriver.record(
                outcome,
                manifest: manifest,
                hardLinkDuplicates: census.hardLinkDuplicates
            )
        }()
        autoreleasepool {}
        // Malloc keeps freed pages for reuse, so without this the next rung's
        // "baseline" is this rung's high-water mark and its delta reads as
        // zero. Returning the free pages makes the per-rung deltas in the
        // record comparable with each other; the absolute peak the ceiling is
        // asserted on does not depend on it.
        malloc_zone_pressure_relief(nil, 0)

        // The kernel's own high-water mark, as a cross-check on the sampler:
        // a spike between two ticks would still be caught here.
        let processPeak = MemoryProbe.peakResidentSizeSinceLaunch()
        XCTAssertLessThan(
            processPeak, ceilingBytes,
            """
            the test process's peak resident size since launch is \
            \(processPeak.formattedAsGibibytes), over the §8.4 ceiling — some rung in this \
            run crossed it even if \(manifest.rung) did not.
            """,
            file: file, line: line
        )

        if let record {
            PerformanceRecordStore.shared.append(record, attachingTo: self)
        }
    }
}
