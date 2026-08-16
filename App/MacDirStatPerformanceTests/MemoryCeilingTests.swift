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
            XCTAssertGreaterThan(outcome.result.root.subtreeBytes, 0, "\(manifest.rung)")
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
                outcome.result.root.subtreeBytes, manifest.attributedBytes,
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
