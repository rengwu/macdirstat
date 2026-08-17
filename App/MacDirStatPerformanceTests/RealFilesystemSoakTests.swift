import Foundation
import ScanCore
import XCTest

/// The same manifest, on a real disk, through the production probe.
///
/// **This is the only test in the suite that can see what the scripted rungs
/// cannot.** A lazily generated workload hands the engine a plain `EntryMeta`
/// struct and allocates nothing else; a real scan goes through
/// `FileManager.contentsOfDirectory`, which returns one `URL` per entry with
/// ten prefetched resource values hanging off each of them, all of it
/// Foundation objects on the autorelease path. A rung that never pays that cost
/// cannot measure it, so the scripted memory gate and this one answer different
/// questions and both are needed.
///
/// Opt-in, and it will not invent its own directory: set
/// `MACDIRSTAT_PERFORMANCE_FIXTURE_DIR` to an **empty** directory you are
/// content to have written to and removed. Optionally set
/// `MACDIRSTAT_PERFORMANCE_FIXTURE_RUNG=representative` for the anchor rung
/// (400,000 inodes; sparse, so the bytes are free but the inodes are not).
final class RealFilesystemSoakTests: XCTestCase {
    private let ceilingBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    func test_aMaterializedRungScansThroughTheProductionProbeBelowTheCeiling() async throws {
        let container = try XCTSkipIfUnset(PerformanceRunPolicy.fixtureDirectory)
        let workload = Self.requestedWorkload

        let fixture = try WorkloadFixtureBuilder.materialize(workload, into: container)
        addTeardownBlock {
            do { try fixture.remove() } catch { XCTFail("fixture cleanup refused: \(error)") }
        }

        let sampler = PeakMemorySampler()
        sampler.start()
        let began = Date()

        var result: ScanResult?
        let scanner = Scanner()
        let request = ScanRequest(
            root: fixture.root,
            mode: .folder,
            probe: FileManagerDirectoryProbe(),
            options: ScanOptions(treeCadence: .minimumInterval(0.25))
        )
        for await event in await scanner.scan(request) {
            if case .finished(let finished) = event { result = finished }
            if case .tree = event { sampler.sample() }
        }
        let elapsed = Date().timeIntervalSince(began)
        let reading = sampler.stop()
        let scan = try XCTUnwrap(result, "the materialized rung failed pre-flight")

        let manifest = fixture.manifest
        let census = scan.root.census()
        XCTAssertEqual(scan.reason, .completed)
        XCTAssertEqual(census.entries, manifest.entryCount, "the materialized tree is not the manifest")
        // **What a materialized rung proves about the two measures.** Every
        // file here is staged with `ftruncate` and nothing is written, so the
        // whole tree occupies no blocks whatever — and since ticket 13 that is
        // exactly what the engine reports, with the manifest's byte total
        // showing up in the length carried beside it. Two hundred thousand
        // entries of the case that made the single measure indefensible.
        XCTAssertEqual(scan.root.subtreeDiskBytes, 0,
                       "a tree of holes occupies nothing, and the engine now says so")
        XCTAssertEqual(scan.root.subtreeContentBytes, manifest.attributedBytes,
                       "sparse files lost their length")

        let bytesPerEntry = Double(reading.footprintDelta) / Double(manifest.entryCount)
        print("""
            [performance] real-filesystem soak \(manifest.rung): \
            \(manifest.entryCount) entries, \
            peak footprint \(reading.peak.physicalFootprint.formattedAsGibibytes) \
            (delta \(reading.footprintDelta.formattedAsMebibytes), \
            \(String(format: "%.0f", bytesPerEntry)) bytes per entry), \
            \(String(format: "%.2f", elapsed)) s [diagnostic]
            """)

        XCTAssertLessThan(
            reading.peak.physicalFootprint, ceilingBytes,
            """
            the materialized \(manifest.rung) rung exceeded the §8.4 ceiling: \
            \(reading.peak.physicalFootprint.formattedAsGibibytes) peak, \
            \(String(format: "%.0f", bytesPerEntry)) bytes of footprint per entry.
            """
        )

        var record = ScaleScanDriver.record(
            ScaleScanOutcome(
                result: scan,
                operations: ProbeOperationCounts(),
                memory: reading,
                treeSnapshots: 0,
                progressSnapshots: 0,
                wallClockSeconds: elapsed
            ),
            manifest: manifest,
            hardLinkDuplicates: census.hardLinkDuplicates
        )
        record.rung = "\(manifest.rung)-materialized"
        PerformanceRecordStore.shared.append(record, attachingTo: self)
    }

    /// The builder's refusals, which are the reason it is safe to point an
    /// environment variable at a directory at all. They run without a fixture
    /// directory, because refusing is the behaviour under test.
    func test_theBuilderRefusesADirectoryItShouldNotWriteTo() throws {
        let manager = FileManager.default
        let occupied = manager.temporaryDirectory
            .appendingPathComponent("macdirstat-soak-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: occupied, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: occupied) }
        try Data().write(to: occupied.appendingPathComponent("already-here.txt"))

        XCTAssertThrowsError(try WorkloadFixtureBuilder.materialize(ScaleRungs.smoke, into: occupied)) { error in
            XCTAssertTrue("\(error)".contains("already holds"), "\(error)")
        }

        let missing = occupied.appendingPathComponent("not-there", isDirectory: true)
        XCTAssertThrowsError(try WorkloadFixtureBuilder.materialize(ScaleRungs.smoke, into: missing))

        XCTAssertThrowsError(
            try WorkloadFixtureBuilder.materialize(
                ScaleRungs.smoke,
                into: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("refusing to stage"), "\(error)")
        }
    }

    /// Sixteen thousand real entries, in a directory this test makes and
    /// destroys itself — and the one guard that stands between the production
    /// probe and the bug this suite found.
    ///
    /// **Why there is a per-entry number here at all.** §8.4 fixes one bar, the
    /// 8 GiB ceiling, and calls the per-rung expectation "diagnostic, not a
    /// threshold" — so this assertion is not in the spec, and it is recorded in
    /// ticket 10's answer as an addition rather than smuggled in. The reason it
    /// earns its place: the ceiling alone could not have caught what was
    /// actually wrong. Every listing the production probe made was being
    /// retained for the whole scan, at 13,615 bytes per entry, and no rung
    /// small enough to run unattended would have crossed 8 GiB on that. The
    /// field report that prompted the measurement did — 28 GB, on a user's own
    /// volume. A ceiling that only fails on the machine of the person who
    /// already suffered is not a gate.
    ///
    /// The bound is deliberately loose: 2 KiB per entry is thirteen times the
    /// 158 bytes measured after the fix and still six times below the 13,615
    /// before it, so it catches the *mechanism* coming back and does not
    /// become a tuning knob.
    func test_aRealFilesystemScanCostsBoundedMemoryPerEntry() async throws {
        let manager = FileManager.default
        let container = manager.temporaryDirectory
            .appendingPathComponent("macdirstat-soak-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: container, withIntermediateDirectories: false)
        addTeardownBlock { try? manager.removeItem(at: container) }

        let workload = ScaleRungs.smokeTimesFour
        let fixture = try WorkloadFixtureBuilder.materialize(workload, into: container)

        // Warm Foundation up before the baseline is taken: the first
        // `contentsOfDirectory` of a process allocates caches that have nothing
        // to do with the tree's size and would otherwise be charged to it.
        _ = try FileManagerDirectoryProbe().list(fixture.root)

        let sampler = PeakMemorySampler()
        sampler.start()
        var result: ScanResult?
        let scanner = Scanner()
        for await event in await scanner.scan(ScanRequest(
            root: fixture.root, mode: .folder, probe: FileManagerDirectoryProbe()
        )) {
            if case .finished(let finished) = event { result = finished }
        }
        let reading = sampler.stop()
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.reason, .completed)
        XCTAssertEqual(scan.completeness, .exact)
        XCTAssertEqual(scan.root.census().entries, fixture.manifest.entryCount)
        XCTAssertEqual(scan.root.subtreeDiskBytes, 0, "the staged tree is sparse: no blocks, all length")
        XCTAssertEqual(scan.root.subtreeContentBytes, fixture.manifest.attributedBytes)

        let bytesPerEntry = Double(reading.footprintDelta) / Double(fixture.manifest.entryCount)
        print("""
            [performance] real-filesystem guard \(fixture.manifest.rung): \
            \(fixture.manifest.entryCount) entries, \
            delta \(reading.footprintDelta.formattedAsMebibytes), \
            \(String(format: "%.0f", bytesPerEntry)) bytes per entry
            """)
        XCTAssertLessThan(
            bytesPerEntry, 2_048,
            """
            a real scan cost \(String(format: "%.0f", bytesPerEntry)) bytes of resident \
            footprint per entry (\(reading.footprintDelta.formattedAsMebibytes) over \
            \(fixture.manifest.entryCount) entries). The production probe is retaining its \
            listings again — see the autorelease pool in FileManagerDirectoryProbe.list.
            """
        )

        try fixture.remove()
        XCTAssertFalse(manager.fileExists(atPath: fixture.root.path))
    }

    // MARK: - Helpers

    private static var requestedWorkload: ScaleWorkload {
        switch ProcessInfo.processInfo.environment["MACDIRSTAT_PERFORMANCE_FIXTURE_RUNG"]?.lowercased() {
        case "representative": return ScaleRungs.representative
        case "smoke": return ScaleRungs.smoke
        default: return ScaleRungs.smokeTimesSixteen
        }
    }

    /// The staging directory is the consent, so its *existence* is the opt-in.
    ///
    /// The `Release, all rungs` test-plan configuration already points
    /// `MACDIRSTAT_PERFORMANCE_FIXTURE_DIR` at `.performance-fixture` in the
    /// repository root (gitignored). Creating that directory, empty, is what
    /// turns the soak on; not creating it skips, rather than failing a run
    /// nobody asked to have write to their disk. A directory that exists but is
    /// *not* empty is a different matter, and the builder refuses it loudly.
    private func XCTSkipIfUnset(_ value: URL?) throws -> URL {
        guard let value else {
            throw XCTSkip("""
                The real-filesystem soak is opt-in (spec §9.2: "not part of the normal loop"). \
                Set MACDIRSTAT_PERFORMANCE_FIXTURE_DIR to an empty directory to run it.
                """)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw XCTSkip("""
                The real-filesystem soak is opt-in and stages onto a real disk. \
                Create \(value.path) as an empty directory to run it.
                """)
        }
        return value
    }
}
