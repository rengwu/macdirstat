import CoreGraphics
import ScanCore
import TreemapLayout
import XCTest

/// The treemap on a scan-sized tree.
///
/// §6.2's promise is that relayout cost is bounded by **visible boxes**, not by
/// node count: a directory whose children would each fall below 2×2 pt folds
/// them into one aggregate, iterating to a fixpoint. That makes a real ceiling
/// available — no surviving box is under two points on either side, so no more
/// than `area / 4` of them fit in the viewport, whatever the tree holds. These
/// tests lay real scan output out against that ceiling and then paint the draw
/// list, because a bound that is never walked is not a bound anybody has
/// tested.
///
/// No relayout duration is asserted anywhere; §6.4's "no cache, recompute on
/// every size change" is a correctness rule, and §8.2 declines the clock.
final class TreemapScaleTests: XCTestCase {
    /// The five viewports ticket 06 laid its geometry out at, plus a large one.
    private let viewports: [TreemapSize] = [
        TreemapSize(width: 640, height: 400),
        TreemapSize(width: 1_024, height: 640),
        TreemapSize(width: 1_440, height: 900),
        TreemapSize(width: 1_920, height: 1_200),
        TreemapSize(width: 2_560, height: 1_600)
    ]

    // MARK: - Bounded visible boxes

    func test_smokeRungLaysOutWithinTheMergeBoundAtEveryViewport() async throws {
        let outcome = await ScaleScanDriver.run(ScaleRungs.smoke)
        assertBoundedLayout(of: outcome.result.root, rung: "smoke")
    }

    func test_representativeRungLaysOutWithinTheMergeBoundAtEveryViewport() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        let outcome = await ScaleScanDriver.run(ScaleRungs.representative)
        assertBoundedLayout(of: outcome.result.root, rung: "representative", recordingAgainst: outcome)
    }

    func test_largeRungLaysOutWithinTheMergeBoundAtEveryViewport() async throws {
        try XCTSkipUnless(PerformanceRunPolicy.runsHeavyRungs, PerformanceRunPolicy.heavyRungSkipMessage)
        let outcome = await ScaleScanDriver.run(ScaleRungs.large)
        assertBoundedLayout(of: outcome.result.root, rung: "large", recordingAgainst: outcome)
    }

    func test_everyStressShapeLaysOutAndPaintsWithoutCrashing() async throws {
        for workload in ScaleRungs.stressShapes {
            let rung = workload.manifest.rung
            let outcome = await ScaleScanDriver.run(workload)
            assertBoundedLayout(of: outcome.result.root, rung: rung)
        }
    }

    /// The shape the merge rule exists for: one 40 GiB file and ten thousand
    /// 4 KiB ones in the same directory. Every tiny file is far below 2×2 pt at
    /// any viewport, so all ten thousand of them must end up in **one**
    /// aggregate — exact in bytes and exact in count — beside one enormous box.
    func test_tenThousandTinyFilesBesideOneHugeOneCollapseIntoASingleAggregate() async throws {
        let workload = ScaleRungs.stressHugeFile
        let outcome = await ScaleScanDriver.run(workload)
        let layout = TreemapLayout.layout(
            tree: ScanNodeTreemapRef(node: outcome.result.root),
            viewport: TreemapSize(width: 1_440, height: 900)
        )

        XCTAssertEqual(layout.statistics.aggregateBoxCount, 1)
        XCTAssertEqual(layout.statistics.mergedItemCount, workload.tinyCount)
        XCTAssertEqual(
            layout.statistics.mergedBytes,
            Int64(workload.tinyCount) * workload.tinyBytes,
            "the aggregate must report the exact combined bytes, never a rounded one"
        )
        XCTAssertEqual(layout.statistics.visibleBoxCount, 2, "one huge box and one merge box")
        XCTAssertFalse(layout.statistics.reachedRoundCap)

        // "Merge, never disappear": the folded bytes are still on screen.
        let filled = layout.filledBoxes
        XCTAssertEqual(filled.reduce(Int64(0)) { $0 + $1.bytes }, workload.manifest.attributedBytes)
        // And the aggregate is hit-testable, so those ten thousand files are
        // still reachable from the map (spec §6.2, §6.4).
        let aggregateBox = try XCTUnwrap(filled.first(where: \.isAggregate))
        XCTAssertTrue(aggregateBox.isHitTestable)
    }

    /// One flat directory of 100,000 entries, at a viewport that can hold them
    /// and at one that cannot.
    ///
    /// The bound is the *viewport's*, not the tree's, and this is the shape
    /// that shows the difference. On a 2,560×1,600 map a hundred thousand
    /// siblings each get around 40 pt² — comfortably over 2×2 — so nothing
    /// merges and a hundred thousand boxes is the honest picture. Shrink the
    /// map to 640×400 and the same tree has to fold, because the same rule now
    /// bites. An implementation that merged on a fixed node count would get
    /// the first case wrong; one that never merged would get the second wrong.
    func test_aHundredThousandSiblingsFoldOnlyWhenTheViewportCannotHoldThem() async throws {
        let workload = ScaleRungs.stressFlatDirectory
        let outcome = await ScaleScanDriver.run(workload)
        let tree = ScanNodeTreemapRef(node: outcome.result.root)
        let total = outcome.result.root.subtreeBytes

        let roomy = TreemapSize(width: 2_560, height: 1_600)
        let roomyLayout = TreemapLayout.layout(tree: tree, viewport: roomy)
        XCTAssertEqual(roomyLayout.statistics.placedNodeCount, workload.fileCount + 1)
        XCTAssertEqual(roomyLayout.statistics.aggregateBoxCount, 0)
        XCTAssertEqual(roomyLayout.statistics.visibleBoxCount, workload.fileCount)
        XCTAssertLessThanOrEqual(
            roomyLayout.statistics.visibleBoxCount,
            TreemapLayoutStatistics.visibleBoxBound(forViewportArea: roomy.area)
        )

        let cramped = TreemapSize(width: 640, height: 400)
        let crampedLayout = TreemapLayout.layout(tree: tree, viewport: cramped)
        XCTAssertEqual(crampedLayout.statistics.aggregateBoxCount, 1, "one merge box per directory")
        XCTAssertLessThan(crampedLayout.statistics.visibleBoxCount, workload.fileCount / 10)
        XCTAssertLessThanOrEqual(
            crampedLayout.statistics.visibleBoxCount,
            TreemapLayoutStatistics.visibleBoxBound(forViewportArea: cramped.area)
        )
        XCTAssertFalse(crampedLayout.statistics.reachedRoundCap)

        // Merge, never disappear: every byte is still drawn at both sizes.
        for layout in [roomyLayout, crampedLayout] {
            XCTAssertEqual(layout.filledBoxes.reduce(Int64(0)) { $0 + $1.bytes }, total)
        }
    }

    // MARK: - Shared assertions

    private func assertBoundedLayout(
        of root: ScanNode,
        rung: String,
        recordingAgainst outcome: ScaleScanOutcome? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tree = ScanNodeTreemapRef(node: root)
        var widestViewportRecord: (TreemapSize, TreemapLayoutStatistics, TimeInterval)?

        for viewport in viewports {
            let began = Date()
            let layout = TreemapLayout.layout(tree: tree, viewport: viewport)
            let elapsed = Date().timeIntervalSince(began)
            let statistics = layout.statistics
            let area = viewport.width * viewport.height
            let bound = TreemapLayoutStatistics.visibleBoxBound(forViewportArea: area)

            XCTAssertLessThanOrEqual(
                statistics.visibleBoxCount, bound,
                """
                \(rung) at \(Int(viewport.width))×\(Int(viewport.height)): \
                \(statistics.visibleBoxCount) visible boxes against a merge-policy bound of \(bound).
                """,
                file: file, line: line
            )
            XCTAssertGreaterThan(statistics.visibleBoxCount, 0, "\(rung)", file: file, line: line)
            XCTAssertFalse(
                statistics.reachedRoundCap,
                "\(rung) at \(Int(viewport.width))×\(Int(viewport.height)) hit the merge round cap",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                statistics.maximumMergeRounds, TreemapMetrics.mergeRoundCap,
                "\(rung)", file: file, line: line
            )

            // Area truthfulness (spec §6.1, §9.3): the filled boxes tile the
            // whole viewport, so 100% of the positive bytes are on screen.
            XCTAssertEqual(
                statistics.coveredArea, area,
                accuracy: area * 1e-6,
                "\(rung) at \(Int(viewport.width))×\(Int(viewport.height)) did not tile its viewport",
                file: file, line: line
            )

            // No surviving *child* box is under the merge threshold on either
            // side — the fixpoint's whole job, and the reason the bound above
            // holds. An aggregate is exempt by construction: it is where the
            // slivers went, and a directory whose leftovers add up to a thin
            // strip has to draw that strip somewhere. Counting the two apart
            // rather than together is the difference between an assertion that
            // means something and one that is simply false.
            var childSlivers = 0
            var aggregateSlivers = 0
            for box in layout.boxes where !box.isSubdivided {
                let isSliver = box.frame.width < TreemapMetrics.mergeThresholdPoints
                    || box.frame.height < TreemapMetrics.mergeThresholdPoints
                guard isSliver else { continue }
                if box.isAggregate { aggregateSlivers += 1 } else { childSlivers += 1 }
            }
            XCTAssertEqual(
                childSlivers, 0,
                """
                \(rung) at \(Int(viewport.width))×\(Int(viewport.height)) left \(childSlivers) \
                sub-2 pt child boxes (\(aggregateSlivers) merge boxes were strips, which is allowed).
                """,
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                aggregateSlivers, statistics.aggregateBoxCount,
                "\(rung)", file: file, line: line
            )

            paint(layout, viewport: viewport)

            if viewport.width == viewports.last?.width {
                widestViewportRecord = (viewport, statistics, elapsed)
            }
        }

        guard let (viewport, statistics, elapsed) = widestViewportRecord else { return }
        print("""
            [performance] treemap \(rung) at \(Int(viewport.width))×\(Int(viewport.height)): \
            \(statistics.visibleBoxCount) visible, \(statistics.subdividedBoxCount) subdivided, \
            \(statistics.aggregateBoxCount) aggregates hiding \(statistics.mergedItemCount) items, \
            \(statistics.squarifyPasses) squarify passes, \
            \(String(format: "%.3f", elapsed)) s [diagnostic]
            """)

        if let outcome {
            let census = outcome.result.root.census()
            var record = ScaleScanDriver.record(
                outcome,
                manifest: manifestForRecording(rung: rung, census: census, outcome: outcome),
                hardLinkDuplicates: census.hardLinkDuplicates
            )
            record.treemapViewport = "\(Int(viewport.width))×\(Int(viewport.height))"
            record.apply(statistics)
            record.treemapDiagnosticLayoutSeconds = elapsed
            record.rung = "\(rung)-with-treemap"
            PerformanceRecordStore.shared.append(record, attachingTo: self)
        }
    }

    /// Walks the draw list the way the view does — fills, then hairlines, then
    /// outlines — into an offscreen bitmap.
    ///
    /// Not a pixel comparison: `MacDirStatTests` owns the light/dark rendering
    /// regressions, and a golden image of a two-million-node scan would prove
    /// nothing anybody could read. What this proves is that the draw list at
    /// scale is finite, has real geometry in it, and can be painted end to end
    /// without a crash — which is the "layout/draw ... and no crash" half of
    /// the ticket.
    private func paint(_ layout: TreemapLayoutResult<ScanNodeTreemapRef>, viewport: TreemapSize) {
        let width = Int(viewport.width)
        let height = Int(viewport.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return XCTFail("could not allocate a \(width)×\(height) bitmap")
        }

        for box in layout.boxes where !box.isSubdivided {
            let group = box.kindGroup ?? .other
            let colour = TreemapPalette.color(for: group, appearance: .light)
            context.setFillColor(
                red: CGFloat(colour.red), green: CGFloat(colour.green),
                blue: CGFloat(colour.blue), alpha: 1
            )
            context.fill(CGRect(
                x: box.frame.x, y: box.frame.y,
                width: box.frame.width, height: box.frame.height
            ))
        }
        context.setStrokeColor(gray: 0, alpha: 0.3)
        context.setLineWidth(TreemapMetrics.directoryOutlineWidthPoints)
        for box in layout.outlinedBoxes {
            context.stroke(CGRect(
                x: box.frame.x, y: box.frame.y,
                width: box.frame.width, height: box.frame.height
            ))
        }
        XCTAssertNotNil(context.makeImage())
    }

    private func manifestForRecording(
        rung: String,
        census: ScanNode.Census,
        outcome: ScaleScanOutcome
    ) -> WorkloadManifest {
        WorkloadManifest(
            rung: rung,
            directoryCount: census.directories,
            fileCount: census.files,
            logicalBytes: outcome.result.root.subtreeBytes,
            attributedBytes: outcome.result.root.subtreeBytes,
            unreadableEntries: census.unreadable,
            exclusions: outcome.result.exclusions.total,
            hardLinkDuplicates: census.hardLinkDuplicates,
            maximumDepth: census.maximumDirectoryDepth
        )
    }
}
