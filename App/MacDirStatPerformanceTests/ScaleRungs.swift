import Foundation

/// The workload ladder, with the exact numbers spec §9.2 fixes.
///
/// Every rung is a literal here rather than a parameter a test passes in, so
/// "Representative" means the same 400,000 entries and the same 200 GiB in
/// every run, on every machine, and a record from one week is comparable with
/// a record from the next. `ScaleWorkloadTests` asserts each rung against its
/// declared totals, which is what keeps a hand-edited ladder from silently
/// producing 199 GiB.
enum ScaleRungs {
    // Powers of two, spelled out, because a rung that is "about 200 GiB" is
    // not reproducible and a `1 << 37` in an argument list is not readable.
    private static let kiB: Int64 = 1_024
    private static let miB: Int64 = 1_024 * 1_024
    private static let giB: Int64 = 1_024 * 1_024 * 1_024
    private static let tiB: Int64 = 1_024 * 1_024 * 1_024 * 1_024

    /// Smoke — 4,096 entries / 768 MiB. The inner loop: small enough that the
    /// whole suite can run it on every commit, large enough to exercise the
    /// merge fixpoint and the k-ary descent.
    static var smoke: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "smoke",
            directoryCount: 256,
            fileCount: 3_840,
            branching: 4,
            totalBytes: 768 * miB,
            rungs: [
                .init(count: 1, bytes: 192 * miB),
                .init(count: 2, bytes: 96 * miB),
                .init(count: 8, bytes: 16 * miB),
                .init(count: 32, bytes: 2 * miB),
                .init(count: 128, bytes: 256 * kiB)
            ]
        )
    }

    /// Smoke with four device-boundary decoys hung off the root.
    ///
    /// A separate rung rather than a flag on Smoke, because the decoys are
    /// entries: folding them into the anchor rung would make 4,096 mean two
    /// different things.
    static var smokeWithVolumeBoundaries: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "smoke-with-volume-boundaries",
            directoryCount: 260,
            fileCount: 3_840,
            branching: 4,
            totalBytes: 768 * miB,
            rungs: [
                .init(count: 1, bytes: 192 * miB),
                .init(count: 2, bytes: 96 * miB),
                .init(count: 8, bytes: 16 * miB),
                .init(count: 32, bytes: 2 * miB),
                .init(count: 128, bytes: 256 * kiB)
            ],
            foreignVolumeDirectories: 4
        )
    }

    /// Smoke's shape with a hundred times its bytes.
    ///
    /// The control for "operation counts scale with entries + ancestor depth,
    /// **not total bytes**": same directories, same files, same tree, 75 GiB
    /// instead of 768 MiB. Any difference in the operation count between this
    /// rung and Smoke would mean the engine is doing work proportional to size.
    static var smokeSameShapeHundredfoldBytes: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "smoke-hundredfold-bytes",
            directoryCount: 256,
            fileCount: 3_840,
            branching: 4,
            totalBytes: 100 * 768 * miB,
            rungs: [
                .init(count: 1, bytes: 100 * 192 * miB),
                .init(count: 2, bytes: 100 * 96 * miB),
                .init(count: 8, bytes: 100 * 16 * miB),
                .init(count: 32, bytes: 100 * 2 * miB),
                .init(count: 128, bytes: 100 * 256 * kiB)
            ]
        )
    }

    /// Smoke's shape, quadrupled twice. The three of them together are the
    /// "geometrically larger inputs" the operation-count claim is checked
    /// across (spec §9.3).
    static var smokeTimesFour: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "smoke-x4",
            directoryCount: 1_024,
            fileCount: 15_360,
            branching: 4,
            totalBytes: 3 * giB,
            rungs: [
                .init(count: 4, bytes: 192 * miB),
                .init(count: 8, bytes: 96 * miB),
                .init(count: 32, bytes: 16 * miB),
                .init(count: 128, bytes: 2 * miB),
                .init(count: 512, bytes: 256 * kiB)
            ]
        )
    }

    static var smokeTimesSixteen: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "smoke-x16",
            directoryCount: 4_096,
            fileCount: 61_440,
            branching: 4,
            totalBytes: 12 * giB,
            rungs: [
                .init(count: 16, bytes: 192 * miB),
                .init(count: 32, bytes: 96 * miB),
                .init(count: 128, bytes: 16 * miB),
                .init(count: 512, bytes: 2 * miB),
                .init(count: 2_048, bytes: 256 * kiB)
            ]
        )
    }

    /// Representative — 400,000 entries / 200 GiB. **The anchor rung** (§8.1).
    static var representative: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "representative",
            directoryCount: 40_000,
            fileCount: 360_000,
            branching: 8,
            totalBytes: 200 * giB,
            rungs: [
                .init(count: 4, bytes: 8 * giB),
                .init(count: 16, bytes: 2 * giB),
                .init(count: 64, bytes: 512 * miB),
                .init(count: 256, bytes: 128 * miB),
                .init(count: 1_024, bytes: 32 * miB),
                .init(count: 4_096, bytes: 4 * miB)
            ]
        )
    }

    /// Large — 2,000,000 entries / 1 TiB. "No catastrophic degradation, still
    /// usable" (§8.1), and the rung the 8 GiB ceiling is really about.
    static var large: BalancedTreeWorkload {
        BalancedTreeWorkload(
            rung: "large",
            directoryCount: 200_000,
            fileCount: 1_800_000,
            branching: 8,
            totalBytes: 1 * tiB,
            rungs: [
                .init(count: 8, bytes: 16 * giB),
                .init(count: 32, bytes: 4 * giB),
                .init(count: 128, bytes: 1 * giB),
                .init(count: 512, bytes: 256 * miB),
                .init(count: 2_048, bytes: 64 * miB),
                .init(count: 8_192, bytes: 16 * miB)
            ]
        )
    }

    // MARK: - The four stress shapes (§9.2)

    static var stressFlatDirectory: FlatDirectoryWorkload {
        FlatDirectoryWorkload(
            fileCount: 100_000,
            totalBytes: 8 * giB,
            rungs: [
                .init(count: 1, bytes: 1 * giB),
                .init(count: 4, bytes: 256 * miB),
                .init(count: 16, bytes: 64 * miB),
                .init(count: 64, bytes: 16 * miB)
            ]
        )
    }

    static var stressDeepChain: DeepChainWorkload {
        DeepChainWorkload(
            depth: 64,
            filesPerLevel: 8,
            totalBytes: 2 * giB,
            rungs: [
                .init(count: 1, bytes: 512 * miB),
                .init(count: 4, bytes: 128 * miB),
                .init(count: 16, bytes: 32 * miB)
            ]
        )
    }

    static var stressHugeFile: HugeFileWorkload {
        HugeFileWorkload(hugeBytes: 40 * giB, tinyCount: 10_000, tinyBytes: 4 * kiB)
    }

    static var stressHardLinks: HardLinkWorkload {
        // 2,000 inodes × 5 names = the 10,000 links §9.2 asks for, beside
        // 20,000 files that are not links, so "the index is proportional to
        // multiply-linked inodes" is a claim this shape can actually test.
        HardLinkWorkload(
            inodeCount: 2_000,
            namesPerInode: 5,
            linkedBytes: 1 * miB,
            ordinaryFileCount: 20_000,
            ordinaryBytes: 64 * kiB,
            singleLinkIdentityCollisions: 500
        )
    }

    static var stressInjectedFailures: InjectedFailureWorkload {
        InjectedFailureWorkload(
            unreadableDirectories: 1_250,
            unreadableFiles: 1_250,
            ordinaryFileCount: 20_000,
            ordinaryBytes: 64 * kiB
        )
    }

    /// The four stress shapes, in the order the record lists them.
    static var stressShapes: [ScaleWorkload] {
        [stressFlatDirectory, stressDeepChain, stressHugeFile, stressHardLinks, stressInjectedFailures]
    }
}

// MARK: - Opting in

/// How much of the ladder this run is allowed to climb.
///
/// The performance plan is the **opt-in pre-release-candidate gate** (§9.1),
/// but `Scripts/verify-scaffold.sh` also runs it once on every local gate to
/// prove the plan is readable at all — a habit that exists because ticket 02
/// shipped a plan Xcode rejected and nothing noticed. Those two facts pull in
/// opposite directions, so the split is here rather than in the plan: by
/// default only the rungs that finish in seconds run, and the heavy ones skip
/// with a message naming the variable that enables them.
///
///     MACDIRSTAT_PERFORMANCE_RUNGS=all \
///       xcodebuild test -project MacDirStat.xcodeproj \
///         -scheme MacDirStat-Performance -configuration Release \
///         -destination 'platform=macOS'
enum PerformanceRunPolicy {
    enum Level: String {
        /// Smoke and the cheap stress shapes only.
        case smoke
        /// Everything: Representative, Large and all four stress shapes.
        case all
    }

    static var level: Level {
        let raw = ProcessInfo.processInfo.environment["MACDIRSTAT_PERFORMANCE_RUNGS"]?.lowercased()
        return Level(rawValue: raw ?? "") ?? .smoke
    }

    static var runsHeavyRungs: Bool { level == .all }

    /// Where a record is written so it can be committed beside the map.
    /// Unset means "a temporary directory": a test must never write into the
    /// repository unless it was told to.
    static var recordDirectory: URL? {
        ProcessInfo.processInfo.environment["MACDIRSTAT_PERFORMANCE_RECORD_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The empty, sentinel-marked directory the real-I/O soak may materialize
    /// into. Unset means the soak does not run (spec §9.2: "not part of the
    /// normal loop").
    static var fixtureDirectory: URL? {
        ProcessInfo.processInfo.environment["MACDIRSTAT_PERFORMANCE_FIXTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let heavyRungSkipMessage = """
        Heavy rungs are opt-in (spec §9.1). Re-run with MACDIRSTAT_PERFORMANCE_RUNGS=all \
        on the reference machine, in Release, without sanitizers.
        """
}
