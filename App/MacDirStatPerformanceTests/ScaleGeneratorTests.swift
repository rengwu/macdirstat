import ScanCore
import XCTest

/// The generator, before it is trusted to measure anything.
///
/// A performance suite is only as honest as its workload: a rung that quietly
/// produced 199 GiB, or that produced different bytes on two machines, would
/// turn every number downstream into noise. So the exact rungs of spec §9.2 are
/// asserted here as arithmetic, and the Smoke rung is asserted a second way —
/// by scanning it and counting what came out.
final class ScaleGeneratorTests: XCTestCase {
    private let miB: Int64 = 1_048_576
    private let giB: Int64 = 1_073_741_824
    private let tiB: Int64 = 1_099_511_627_776

    // MARK: - The ladder's exact numbers (spec §9.2)

    func test_smokeRungIs4096EntriesAnd768MiB() {
        let manifest = ScaleRungs.smoke.manifest
        XCTAssertEqual(manifest.entryCount, 4_096)
        XCTAssertEqual(manifest.logicalBytes, 768 * miB)
        XCTAssertEqual(manifest.directoryCount, 256)
        XCTAssertEqual(manifest.fileCount, 3_840)
    }

    func test_representativeRungIs400000EntriesAnd200GiB() {
        let manifest = ScaleRungs.representative.manifest
        XCTAssertEqual(manifest.entryCount, 400_000)
        XCTAssertEqual(manifest.logicalBytes, 200 * giB)
    }

    func test_largeRungIs2000000EntriesAnd1TiB() {
        let manifest = ScaleRungs.large.manifest
        XCTAssertEqual(manifest.entryCount, 2_000_000)
        XCTAssertEqual(manifest.logicalBytes, 1 * tiB)
    }

    func test_theFourStressShapesAreTheOnesTheSpecNames() {
        XCTAssertEqual(ScaleRungs.stressFlatDirectory.manifest.fileCount, 100_000)
        XCTAssertEqual(ScaleRungs.stressFlatDirectory.manifest.directoryCount, 1)

        XCTAssertEqual(ScaleRungs.stressDeepChain.manifest.maximumDepth, 64)

        XCTAssertEqual(ScaleRungs.stressHugeFile.hugeBytes, 40 * giB)
        XCTAssertEqual(ScaleRungs.stressHugeFile.tinyCount, 10_000)

        XCTAssertEqual(ScaleRungs.stressHardLinks.linkedNameCount, 10_000)

        XCTAssertEqual(ScaleRungs.stressInjectedFailures.injectedFailures, 2_500)
    }

    /// The composition's arithmetic, checked against itself: the ladder plus
    /// the divided tail must be the declared total, to the byte, for every
    /// rung. This is the property that lets the byte figures above be literals
    /// rather than approximations.
    func test_everyCompositionSumsExactlyToItsDeclaredTotal() {
        let compositions: [(String, SizeComposition)] = [
            ("smoke", ScaleRungs.smoke.composition),
            ("representative", ScaleRungs.representative.composition),
            ("large", ScaleRungs.large.composition),
            ("stress-flat", ScaleRungs.stressFlatDirectory.composition),
            ("stress-chain", ScaleRungs.stressDeepChain.composition)
        ]
        for (name, composition) in compositions {
            XCTAssertEqual(
                composition.recomputedTotalBytes,
                composition.totalBytes,
                "\(name): the ladder and the divided tail do not add up to the declared total"
            )
            XCTAssertGreaterThan(composition.tailQuotient, 0, "\(name): tail files must not be empty")
        }
    }

    /// The same claim the hard way, for the rung small enough to enumerate:
    /// add up all 3,840 individual file sizes and compare.
    func test_theSmokeRungsIndividualFileSizesSumToItsTotal() {
        let composition = ScaleRungs.smoke.composition
        var total: Int64 = 0
        var distinctSizes: Set<Int64> = []
        for index in 0..<composition.fileCount {
            let size = composition.size(ofFileAt: index)
            XCTAssertGreaterThan(size, 0, "file \(index) has no bytes")
            total += size
            distinctSizes.insert(size)
        }
        XCTAssertEqual(total, composition.totalBytes)
        // A flat distribution would make the merge fixpoint and the squarify
        // pass trivial, so the heavy tail is part of the fixture, not decoration.
        XCTAssertGreaterThanOrEqual(distinctSizes.count, 6)
        XCTAssertGreaterThanOrEqual(distinctSizes.max() ?? 0, 192 * miB)
    }

    // MARK: - Reproducibility

    func test_twoIndependentlyBuiltWorkloadsProduceIdenticalListings() throws {
        let first = ScaleRungs.representative
        let second = ScaleRungs.representative
        for path in [[], ["directory-1"], ["directory-1", "directory-9"], ["directory-39999"]] {
            let left = try first.entries(at: path)
            let right = try second.entries(at: path)
            XCTAssertEqual(left, right, "listing of \(path) is not reproducible")
            XCTAssertFalse(left.isEmpty, "listing of \(path) is empty")
        }
    }

    func test_listingTheSameDirectoryTwiceReturnsTheSameEntries() throws {
        let workload = ScaleRungs.large
        let once = try workload.entries(at: ["directory-4242"])
        let twice = try workload.entries(at: ["directory-4242"])
        XCTAssertEqual(once, twice)
    }

    /// The "lazy, not retained" claim, as a structural fact rather than a
    /// measurement: a workload's own footprint is a fixed handful of fields, so
    /// the two-million-entry rung is exactly as large in memory as the
    /// four-thousand-entry one (spec §9.2).
    func test_aWorkloadStoresNothingPerEntry() {
        // The only heap a workload owns is its size ladder — five or six
        // `(count, bytes)` pairs, fixed per rung and unrelated to the entry
        // count. A per-file table added later would show up as a ladder that
        // grows with the rung, and as a footprint that does.
        XCTAssertEqual(ScaleRungs.smoke.composition.rungs.count, 5)
        XCTAssertEqual(ScaleRungs.large.composition.rungs.count, 6)

        let before = MemoryProbe.sample().physicalFootprint
        var workloads: [BalancedTreeWorkload] = []
        for _ in 0..<64 { workloads.append(ScaleRungs.large) }
        let after = MemoryProbe.sample().physicalFootprint
        XCTAssertEqual(workloads.count, 64)
        // Sixty-four two-million-entry workloads, held at once. Anything that
        // retained even one byte per entry would need 128 MB here.
        XCTAssertLessThan(
            after > before ? after - before : 0,
            4 * 1_048_576,
            "holding 64 Large workloads cost more than 4 MiB — something is being retained per entry"
        )
    }

    // MARK: - What a scan of the generator actually finds

    /// Smoke, scanned: the tree the engine builds has to agree with the
    /// manifest in every count and to the byte. Everything the heavy rungs
    /// assert about themselves rests on this, at a size where a disagreement
    /// can still be read by eye.
    func test_scanningTheSmokeRungReproducesItsManifestExactly() async throws {
        let workload = ScaleRungs.smoke
        let manifest = workload.manifest
        let outcome = await ScaleScanDriver.run(workload, tracksListedPaths: true)

        XCTAssertEqual(outcome.result.reason, .completed)
        XCTAssertEqual(outcome.result.completeness, .exact)
        XCTAssertEqual(outcome.result.root.subtreeBytes, manifest.attributedBytes)
        XCTAssertEqual(outcome.result.root.fileCount, Int64(manifest.fileCount))

        let census = outcome.result.root.census()
        XCTAssertEqual(census.directories, manifest.directoryCount)
        XCTAssertEqual(census.files, manifest.fileCount)
        XCTAssertEqual(census.entries, manifest.entryCount)
        XCTAssertEqual(census.maximumDirectoryDepth, manifest.maximumDepth)
        XCTAssertEqual(census.unreadable, 0)
        XCTAssertEqual(census.hardLinkDuplicates, 0)
    }

    /// Determinism the scan can see: identical runs produce identical node
    /// order, which is the precondition ticket 03 recorded for hard-link
    /// ownership being well defined at all (spec §9.3).
    func test_twoRunsOfTheSameRungProduceTheSameNodeOrder() async throws {
        func firstHundredNames() async -> [String] {
            let outcome = await ScaleScanDriver.run(ScaleRungs.smoke)
            var names: [String] = []
            outcome.result.root.walk { node in
                if names.count < 100 { names.append(node.pathComponents().joined(separator: "/")) }
                return names.count < 100
            }
            return names
        }
        let first = await firstHundredNames()
        let second = await firstHundredNames()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    /// Every generated name is a single path component and every generated
    /// file name classifies into a palette group — the treemap rung would
    /// otherwise be measuring eleven hues' worth of `.other`.
    func test_generatedNamesAreSinglePathComponentsAcrossAllElevenPaletteGroups() throws {
        var seen: Set<String> = []
        for index in 0..<5_000 {
            let name = WorkloadNaming.fileName(index)
            XCTAssertFalse(name.contains("/"), "\(name) is not a single path component")
            seen.insert(WorkloadNaming.fileExtension(index))
        }
        XCTAssertEqual(seen.count, WorkloadNaming.fileExtensions.count)
    }
}
