import Foundation
import ScanCore
import TreemapLayout
import XCTest

/// What a relayout costs, and where it runs (ticket 14).
///
/// `TreemapScaleTests` proves the *output* is bounded — no more boxes than the
/// viewport can hold. That was already true when the engine was slow, because
/// the boxes it threw away had all been built first: at the Large rung a full
/// relayout took **2.27 s**, on the main thread, inside `draw(_:)`, on every
/// tree snapshot. Two separate things had to change, and each is measured here
/// rather than argued:
///
/// 1. **The work is bounded by the boxes, not by the tree.** The layout reads a
///    directory's children only when that directory is about to be subdivided,
///    so a subtree that folded into an aggregate is never opened.
///    `preparedChildCount` counts what it did read.
/// 2. **It does not run on the main thread.** A heartbeat on the main actor
///    measures the longest it was ever unable to run while layouts happened —
///    with a control that makes the same measurement while one layout runs
///    inline, so the instrument is shown to be capable of failing.
final class TreemapLayoutCostTests: XCTestCase {
    /// The widest viewport the ladder is laid out at — a 2,560×1,600 display,
    /// which is where the old pre-pass cost the most.
    private let viewport = TreemapSize(width: 2_560, height: 1_600)

    /// The main thread must never be unable to run for longer than this while
    /// the treemap is laying out. It is a bound on *stall*, not on layout: a
    /// layout may take as long as it likes as long as it takes it elsewhere.
    /// Generous on purpose — the assertion is about seconds versus
    /// milliseconds, and a test host under load must not make it flaky.
    static let mainThreadStallBoundSeconds: TimeInterval = 0.1

    /// §8.4's ceiling, which a layout pass has to stay under as much as a scan
    /// does — it runs while the scan's whole tree is resident.
    private let ceilingBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    // MARK: - Bounded by rendered boxes

    func test_everyEntryReadIsEitherDrawnOrFolded() async throws {
        let workloads: [ScaleWorkload] = [ScaleRungs.smoke, ScaleRungs.stressHugeFile, ScaleRungs.stressDeepChain]
        for workload in workloads {
            let outcome = await ScaleScanDriver.run(workload)
            assertWorkIsAccountedFor(
                ScanNodeTreemapRef(node: outcome.result.root),
                rung: workload.manifest.rung
            )
        }
    }

    /// **The same tree, two viewports.** This is what "bounded by rendered
    /// boxes rather than total nodes" means, stated so that it can fail: shrink
    /// the map and the tree does not change, so any cost that tracks the tree
    /// stays put while any cost that tracks the picture falls.
    ///
    /// The old engine's number here was flat — it materialized every
    /// positive-byte node whatever the viewport was, which is why a 2.27 s
    /// relayout could not be escaped by making the window smaller.
    func test_shrinkingTheMapShrinksTheWorkThoughTheTreeIsUnchanged() async throws {
        let outcome = await ScaleScanDriver.run(ScaleRungs.smoke)
        assertWorkTracksTheViewport(
            ScanNodeTreemapRef(node: outcome.result.root),
            rung: "smoke",
            cramped: TreemapSize(width: 60, height: 40),
            atLeastTimesLess: 2
        )
    }

    func test_largeRungCostTracksTheViewportAndIsRecorded() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        let outcome = await ScaleScanDriver.run(ScaleRungs.large)
        let tree = ScanNodeTreemapRef(node: outcome.result.root)

        let wide = assertWorkIsAccountedFor(tree, rung: "large")
        assertWorkTracksTheViewport(tree, rung: "large", cramped: TreemapSize(width: 640, height: 400), atLeastTimesLess: 4)

        XCTAssertGreaterThan(wide.statistics.placedNodeCount, 1_000_000)
        // Even at the widest viewport the ladder uses, two thirds of the tree
        // is read and a third is not — and what is read is read *flat*: a
        // folded root costs one entry, not its subtree. That is the difference
        // between this rung's 1,198,128 folded roots and the 1,862,944 entries
        // they stand for.
        let mergedRoots = wide.boxes.reduce(0) { $0 + ($1.aggregate?.mergedRoots.count ?? 0) }
        XCTAssertLessThan(mergedRoots, wide.statistics.mergedItemCount)
        XCTAssertLessThan(wide.statistics.preparedChildCount, wide.statistics.placedNodeCount)
        // These figures reach the record through `TreemapScaleTests`, which
        // lays the same rung out at five viewports and writes the widest as
        // `large-with-treemap`. Recording them twice would put two rows in the
        // file that can never disagree.
    }

    // MARK: - What a layout pass costs in memory

    /// Measured **separately from the scan's**, so the transient allocation is
    /// visible instead of folded into one number (ticket 14).
    ///
    /// The old engine allocated one class instance per positive-byte node
    /// before placing anything; the draw list it produces is bounded by the
    /// viewport, so the pre-pass was the whole of the transient cost and none
    /// of it showed up separately.
    func test_aLayoutPassAtLargeIsRecordedApartFromTheScan() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        let outcome = await ScaleScanDriver.run(ScaleRungs.large)
        let tree = ScanNodeTreemapRef(node: outcome.result.root)

        let sampler = PeakMemorySampler(interval: 0.005)
        sampler.start()
        let began = ProcessInfo.processInfo.systemUptime
        let layout = TreemapLayout.layout(tree: tree, viewport: viewport)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        sampler.sample()
        let reading = sampler.stop()

        XCTAssertGreaterThan(layout.statistics.visibleBoxCount, 0)
        XCTAssertLessThan(
            reading.peak.physicalFootprint, ceilingBytes,
            "a layout pass pushed the process over the §8.4 ceiling"
        )
        print("""
            [performance] treemap layout pass at large, \(Int(viewport.width))×\(Int(viewport.height)): \
            peak footprint \(reading.peak.physicalFootprint.formattedAsGibibytes), \
            +\(reading.footprintDelta.formattedAsMebibytes) over the scan's tree, \
            \(layout.boxes.count) boxes, \(String(format: "%.3f", elapsed)) s [diagnostic]
            """)

        var record = ScaleScanDriver.record(
            outcome,
            manifest: ScaleRungs.large.manifest,
            hardLinkDuplicates: 0
        )
        record.rung = "large-treemap-layout-pass"
        record.treemapViewport = "\(Int(viewport.width))×\(Int(viewport.height))"
        record.apply(layout.statistics)
        record.treemapDiagnosticLayoutSeconds = elapsed
        record.treemapLayoutPeakFootprintBytes = reading.peak.physicalFootprint
        record.treemapLayoutFootprintDeltaBytes = reading.footprintDelta
        PerformanceRecordStore.shared.append(record, attachingTo: self)
    }

    // MARK: - The main thread

    func test_theMainThreadIsNeverBlockedByALayoutAtTheLargeRung() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        let outcome = await ScaleScanDriver.run(ScaleRungs.large)
        let tree = ScanNodeTreemapRef(node: outcome.result.root)

        let measured = await measureStall(layingOut: tree, snapshots: 6)

        XCTAssertLessThan(
            measured.backgroundStall, Self.mainThreadStallBoundSeconds,
            """
            the main thread was unable to run for \(String(format: "%.3f", measured.backgroundStall)) s \
            while the treemap laid out — the bound is \(Self.mainThreadStallBoundSeconds) s
            """
        )
        // The control: the same instrument, watching one layout run inline. If
        // it cannot see that, it could not have seen a regression either.
        XCTAssertGreaterThan(
            measured.inlineStall, measured.backgroundStall * 5,
            "the instrument did not notice a layout on the main thread, so it proves nothing"
        )
        XCTAssertGreaterThan(measured.layoutSeconds, 0)

        print("""
            [performance] main-thread stall at large: \
            \(String(format: "%.4f", measured.backgroundStall)) s with layout in the background, \
            \(String(format: "%.4f", measured.inlineStall)) s with one layout inline, \
            layout itself \(String(format: "%.3f", measured.layoutSeconds)) s [diagnostic]
            """)

        var record = ScaleScanDriver.record(
            outcome,
            manifest: ScaleRungs.large.manifest,
            hardLinkDuplicates: 0
        )
        record.rung = "large-treemap-main-thread"
        record.treemapViewport = "\(Int(viewport.width))×\(Int(viewport.height))"
        record.treemapDiagnosticLayoutSeconds = measured.layoutSeconds
        record.treemapMainThreadStallSeconds = measured.backgroundStall
        record.treemapInlineMainThreadStallSeconds = measured.inlineStall
        PerformanceRecordStore.shared.append(record, attachingTo: self)
    }

    /// The same measurement at the smoke rung, so the *shape* of the claim is
    /// checked on every run rather than only when the heavy rungs are asked
    /// for. It cannot fail the way the Large one can — a small tree lays out in
    /// microseconds either way — so it asserts only the bound.
    func test_theMainThreadIsNeverBlockedByALayoutAtTheSmokeRung() async throws {
        let outcome = await ScaleScanDriver.run(ScaleRungs.smoke)
        let measured = await measureStall(layingOut: ScanNodeTreemapRef(node: outcome.result.root), snapshots: 6)

        XCTAssertLessThan(measured.backgroundStall, Self.mainThreadStallBoundSeconds)
    }

    private struct StallMeasurement {
        var backgroundStall: TimeInterval
        var inlineStall: TimeInterval
        var layoutSeconds: TimeInterval
    }

    /// Drives `snapshots` relayouts the way a running scan does — a new
    /// revision every time, at a viewport that keeps changing — and watches how
    /// long the main actor is ever unable to run.
    @MainActor
    private func measureStall(
        layingOut tree: ScanNodeTreemapRef,
        snapshots: Int
    ) async -> StallMeasurement {
        let background = TreemapLayoutCoordinator<ScanNodeTreemapRef>(execution: .background)
        let heartbeat = MainActorHeartbeat()

        heartbeat.start()
        for revision in 1...snapshots {
            background.request(
                tree: tree,
                viewport: TreemapSize(width: viewport.width - Double(revision), height: viewport.height),
                revision: revision
            )
            await background.settle()
        }
        let backgroundStall = await heartbeat.stop()

        // The control: one layout on the main actor, watched by the same
        // heartbeat.
        let inline = TreemapLayoutCoordinator<ScanNodeTreemapRef>(execution: .immediate)
        heartbeat.start()
        await Task.yield()
        inline.request(tree: tree, viewport: viewport, revision: 1)
        await Task.yield()
        let inlineStall = await heartbeat.stop()

        return StallMeasurement(
            backgroundStall: backgroundStall,
            inlineStall: inlineStall,
            layoutSeconds: inline.lastLayoutSeconds
        )
    }

    // MARK: - Shared assertions

    /// Lays the same tree out at a wide viewport and a cramped one, and holds
    /// the work against the picture rather than against the tree.
    private func assertWorkTracksTheViewport(
        _ tree: ScanNodeTreemapRef,
        rung: String,
        cramped: TreemapSize,
        atLeastTimesLess: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let wide = TreemapLayout.layout(tree: tree, viewport: viewport).statistics
        let small = TreemapLayout.layout(tree: tree, viewport: cramped).statistics

        XCTAssertEqual(wide.placedNodeCount, small.placedNodeCount, "\(rung): the tree changed", file: file, line: line)
        XCTAssertLessThan(
            small.visibleBoxCount, wide.visibleBoxCount,
            "\(rung): the cramped viewport must draw fewer boxes for this to mean anything",
            file: file, line: line
        )
        XCTAssertLessThan(
            small.preparedChildCount, wide.preparedChildCount / atLeastTimesLess,
            """
            \(rung): the cramped viewport still read \(small.preparedChildCount) entries \
            against \(wide.preparedChildCount) — the work is not tracking the picture
            """,
            file: file, line: line
        )
        XCTAssertLessThan(
            small.preparedChildCount, small.placedNodeCount / atLeastTimesLess,
            "\(rung): a cramped relayout still reads most of the tree",
            file: file, line: line
        )
        print("""
            [performance] treemap work \(rung) by viewport: \
            \(wide.preparedChildCount) entries read at \(Int(viewport.width))×\(Int(viewport.height)), \
            \(small.preparedChildCount) at \(Int(cramped.width))×\(Int(cramped.height)), \
            of \(wide.placedNodeCount) in the tree either way [diagnostic]
            """)
    }

    @discardableResult
    private func assertWorkIsAccountedFor(
        _ tree: ScanNodeTreemapRef,
        rung: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TreemapLayoutResult<ScanNodeTreemapRef> {
        let result = TreemapLayout.layout(tree: tree, viewport: viewport)
        let statistics = result.statistics

        // Every entry the layout read ends as one of exactly two things: a box
        // it drew, or a root it folded into an aggregate. Nothing is read and
        // discarded — which is the precise sense in which the work is bounded
        // by what is on screen, and a stronger claim than any inequality.
        let mergedRoots = result.boxes.reduce(0) { $0 + ($1.aggregate?.mergedRoots.count ?? 0) }
        let drawnChildren = result.boxes.count - 1 - statistics.aggregateBoxCount
        XCTAssertEqual(
            statistics.preparedChildCount, drawnChildren + mergedRoots,
            "\(rung): the layout read entries it neither drew nor folded",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            statistics.visitedDirectoryCount, result.boxes.count,
            "\(rung): more directories were opened than there are boxes",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            statistics.preparedChildCount, statistics.placedNodeCount,
            "\(rung): a relayout read more than the tree holds",
            file: file, line: line
        )

        print("""
            [performance] treemap work \(rung) at \(Int(viewport.width))×\(Int(viewport.height)): \
            read \(statistics.preparedChildCount) of \(statistics.placedNodeCount) entries \
            (\(String(format: "%.2f", 100 * Double(statistics.preparedChildCount) / Double(max(statistics.placedNodeCount, 1))))%), \
            opened \(statistics.visitedDirectoryCount) directories, \
            drew \(statistics.visibleBoxCount) boxes, folded \(mergedRoots) roots \
            holding \(statistics.mergedItemCount) items [diagnostic]
            """)
        return result
    }
}

/// Records the longest the main actor was ever unable to run.
///
/// A task that wakes every two milliseconds and reports how late it was. The
/// number it produces is exactly what a user feels as a freeze: not how long
/// something took, but how long nothing else could happen.
@MainActor
final class MainActorHeartbeat {
    private var task: Task<TimeInterval, Never>?

    func start() {
        task?.cancel()
        task = Task { @MainActor in
            var maximum: TimeInterval = 0
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                maximum = max(maximum, now - last)
                last = now
            }
            return maximum
        }
    }

    func stop() async -> TimeInterval {
        guard let task else { return 0 }
        self.task = nil
        task.cancel()
        return await task.value
    }
}
