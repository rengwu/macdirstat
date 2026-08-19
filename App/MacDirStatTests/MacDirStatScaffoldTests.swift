import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

@MainActor
final class DisplayFormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private let deDE = Locale(identifier: "de_DE")

    func test_iecBoundariesAndThreeSignificantFigures() {
        let formatter = DisplayFormatter(locale: enUS)

        XCTAssertEqual(formatter.bytes(0), "0 bytes")
        XCTAssertEqual(formatter.bytes(1), "1 byte")
        XCTAssertEqual(formatter.bytes(1_023), "1,023 bytes")
        XCTAssertEqual(formatter.bytes(1_024), "1.00 KiB")
        XCTAssertEqual(formatter.bytes(1_536), "1.50 KiB")
        XCTAssertEqual(formatter.bytes(12 * 1_024), "12.0 KiB")
        XCTAssertEqual(formatter.bytes(123 * 1_024), "123 KiB")
        XCTAssertEqual(formatter.bytes(1_024 * 1_024), "1.00 MiB")
        XCTAssertEqual(formatter.bytes(1_024 * 1_024 * 1_024), "1.00 GiB")
        XCTAssertEqual(formatter.bytes(1_024 * 1_024 * 1_024 * 1_024), "1.00 TiB")
    }

    func test_roundingCarryWithinAnIECUnitUsesGrouping() {
        let formatter = DisplayFormatter(locale: enUS)
        let roundsToOneThousandKiB = Int64(999.5 * 1_024)

        XCTAssertEqual(formatter.bytes(roundsToOneThousandKiB), "1,000 KiB")
    }

    func test_decimalSeparatorLocalizesWithoutChangingIECLabels() {
        let formatter = DisplayFormatter(locale: deDE)

        XCTAssertEqual(formatter.bytes(1_536), "1,50 KiB")
        XCTAssertEqual(formatter.exactBytes(1_234_567), "1.234.567 bytes")
        XCTAssertEqual(formatter.count(1_234_567), "1.234.567")
    }

    func test_percentFloorRoundingAndExtremes() {
        let formatter = DisplayFormatter(locale: enUS)

        XCTAssertEqual(formatter.percentage(0), "0%")
        XCTAssertEqual(formatter.percentage(0.049), "< 0.1%")
        XCTAssertEqual(formatter.percentage(0.05), "0.1%")
        XCTAssertEqual(formatter.percentage(12.34), "12.3%")
        XCTAssertEqual(formatter.percentage(100), "100.0%")
        XCTAssertEqual(formatter.share(childBytes: 1, parentBytes: 10_000), "< 0.1%")
    }

    /// The throughput reading is items per second, and no bytes-per-second
    /// figure survives anywhere (ticket 13). The scanner reads directory
    /// listings and never file contents, so a byte rate here was never a disk
    /// speed — before the measure changed it was not even a rate of real bytes.
    func test_throughputCountsItemsAndNeverBytes() {
        let formatter = DisplayFormatter(locale: enUS)

        XCTAssertEqual(formatter.throughput(0), "0 items/s")
        XCTAssertEqual(formatter.throughput(12_345.6), "12,345 items/s")
        XCTAssertEqual(formatter.throughput(-1), "0 items/s")
        for reading in [0.0, 1_024.0, 5_000_000.0] {
            let text = formatter.throughput(reading)
            XCTAssertFalse(text.contains("KiB"), text)
            XCTAssertFalse(text.contains("MiB"), text)
            XCTAssertFalse(text.contains("bytes"), text)
        }
    }
}

/// The status line, as data (ticket 13).
@MainActor
final class StatusBarSummaryTests: XCTestCase {
    private let formatter = DisplayFormatter(locale: Locale(identifier: "en_US"))

    private func text(
        phase: ScanPhase,
        root: ScanNode?,
        result: ScanResult? = nil,
        volumeCapacity: VolumeCapacity? = nil
    ) -> String? {
        StatusBarViewController.text(
            phase: phase,
            root: root,
            progress: nil,
            result: result,
            volumeCapacity: volumeCapacity,
            formatter: formatter
        )
    }

    /// **A finished volume scan reconciles out loud.** Counted against used, in
    /// that order, so the figure the map is made of is next to the figure the
    /// volume itself reports.
    func test_aFinishedVolumeScanShowsItsCountedTotalAgainstVolumeUsed() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("payload.bin", bytes: 4_096, in: root)
        }
        let counted = fixture.rootNode.subtreeDiskBytes

        let line = try XCTUnwrap(
            text(
                phase: .completed,
                root: fixture.rootNode,
                volumeCapacity: VolumeCapacity(totalBytes: 1_000_000, availableBytes: 1_000_000 - counted)
            )
        )

        XCTAssertTrue(line.contains("\(formatter.bytes(counted)) counted"), line)
        XCTAssertTrue(line.contains("\(formatter.bytes(counted)) used"), line)
    }

    /// It appears **even when the two agree** — agreement at a fraction of a
    /// percent is the evidence that the picture is real, and it can only be
    /// read as evidence if it is there every time.
    func test_theReconciliationLineAppearsWhenTheFiguresDisagreeToo() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("payload.bin", bytes: 4_096, in: root)
        }

        let line = try XCTUnwrap(
            text(
                phase: .completed,
                root: fixture.rootNode,
                volumeCapacity: VolumeCapacity(totalBytes: 100 * 1_024 * 1_024, availableBytes: 0)
            )
        )

        XCTAssertTrue(line.contains("counted"), line)
        XCTAssertTrue(line.contains("100 MiB used"), line)
    }

    /// **Cancelled (§7.3):** an "● Incomplete — scan cancelled" chip at the head
    /// of the line, and the partial total is retained beside it — the results
    /// stay there to browse, they are simply a lower bound now.
    func test_aCancelledScanFlagsIncompleteAtTheHeadOfTheStatusBar() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("payload.bin", bytes: 4_096, in: root)
        }

        let line = try XCTUnwrap(text(phase: .cancelled, root: fixture.rootNode))

        XCTAssertTrue(line.hasPrefix("● Incomplete — scan cancelled"), line)
        XCTAssertTrue(line.contains(formatter.bytes(fixture.rootNode.subtreeDiskBytes)), line)
    }

    /// **Completed with errors (§7.3):** the count of what could not be read is
    /// surfaced in the line, which is what marks the total a lower bound.
    func test_aScanThatCompletedWithErrorsCountsThemInTheStatusBar() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let locked = try makeDirectory("locked", in: root)
            try writeFile("inside.bin", bytes: 4_096, in: locked)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        }
        let result = try XCTUnwrap(fixture.model.result)
        try XCTSkipIf(result.errors.isEmpty, "this host let the scan read a chmod-000 directory")

        let line = try XCTUnwrap(text(phase: .completed, root: fixture.rootNode, result: result))

        XCTAssertTrue(line.contains("\(formatter.count(Int64(result.errors.total))) errors"), line)
    }

    /// A folder scan has no volume to reconcile against, so it says nothing it
    /// cannot back up.
    func test_aFolderScanSaysNothingAboutVolumeUsed() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("payload.bin", bytes: 4_096, in: root)
        }

        let line = try XCTUnwrap(text(phase: .completed, root: fixture.rootNode))

        XCTAssertFalse(line.contains("used"), line)
        XCTAssertFalse(line.contains("counted"), line)
        XCTAssertTrue(line.hasPrefix(formatter.bytes(fixture.rootNode.subtreeDiskBytes)), line)
    }
}

@MainActor
final class SourceChooserTests: XCTestCase {
    func test_classifiesAllSourceKindsAndFiltersIneligibleSourcesFromTheResolvedChooser() {
        let root = URL(fileURLWithPath: "/Volumes")
        let candidates = [
            VolumeSourceFacts(url: root.appendingPathComponent("Macintosh HD"), name: "Macintosh HD", isLocal: true, isInternal: true),
            VolumeSourceFacts(url: root.appendingPathComponent("USB"), name: "USB", isLocal: true, isInternal: false, isRemovable: true),
            VolumeSourceFacts(url: root.appendingPathComponent("Share"), name: "Share", isLocal: false),
            VolumeSourceFacts(url: root.appendingPathComponent("Cloud"), name: "Cloud", isLocal: true, isUbiquitous: true),
            VolumeSourceFacts(url: root.appendingPathComponent("Image"), name: "Image", isLocal: true, isDiskImage: true),
        ]

        let choices = candidates.map(SourceChooserModel.classify)
        XCTAssertEqual(choices.map(\.eligibility), [
            .eligible,
            .eligible,
            .ineligible(reason: "Network volumes aren’t supported."),
            .ineligible(reason: "Cloud storage roots aren’t supported."),
            .ineligible(reason: "Disk images aren’t supported."),
        ])
        XCTAssertEqual(SourceChooserModel.visibleChoices(from: candidates).map(\.name), ["Macintosh HD", "USB"])
        XCTAssertEqual(choices[0].detail, "Internal disk")
        XCTAssertEqual(choices[1].detail, "External disk")
    }

    func test_escapeDismissesTheChooser() {
        let controller = SourceChooserViewController(choices: [])
        var dismissed = false
        controller.onCancel = { dismissed = true }

        controller.cancelOperation(nil)

        XCTAssertTrue(dismissed)
    }
}

@MainActor
final class AppShellTests: XCTestCase {
    func test_mainMenuAndShellAreProgrammaticAndReadOnly() {
        let menu = MainMenu.make()
        let allTitles = menu.items.flatMap { item in
            [item.title] + (item.submenu?.items.map(\.title) ?? [])
        }
        XCTAssertFalse(allTitles.contains(where: { ["Delete", "Clean", "Move", "Rename"].contains($0) }))

        let controller = MainWindowController()
        let workspace = controller.workspaceViewController
        XCTAssertEqual(workspace.splitViewItems.count, 3)
        XCTAssertTrue(workspace.splitViewItems[0].viewController is DirectoryTreeViewController)
        XCTAssertTrue(workspace.splitViewItems[1].viewController is TreemapPaneViewController)
        XCTAssertTrue(workspace.splitViewItems[2].viewController is InspectorViewController)
        XCTAssertFalse(workspace.splitViewItems[1].canCollapse)
        XCTAssertTrue(workspace.splitViewItems[2].canCollapse)
        XCTAssertEqual(workspace.splitViewItems[2].preferredThicknessFraction, 300.0 / 1_100.0, accuracy: 0.0001)
        XCTAssertEqual(workspace.splitViewItems[2].minimumThickness, 260)
        XCTAssertEqual(workspace.splitViewItems[2].maximumThickness, 360)
        XCTAssertLessThan(workspace.splitViewItems[1].holdingPriority, workspace.splitViewItems[2].holdingPriority)
        XCTAssertNotNil(controller.window?.toolbar)
        XCTAssertEqual(controller.window?.toolbarStyle, .unified)
        XCTAssertNotNil(controller.statusBarController.view.superview)
    }

    /// §7.2: "every split divider drags". The tree pane's own drag has to have
    /// somewhere to go, and has to be catchable on a 1 pt hairline.
    func test_treePaneIsResizableAndItsDividerIsCatchable() {
        let controller = MainWindowController()
        let workspace = controller.workspaceViewController
        let tree = workspace.splitViewItems[0]

        XCTAssertEqual(tree.minimumThickness, WorkspaceSplitViewController.treeMinimumThickness)
        XCTAssertEqual(tree.maximumThickness, WorkspaceSplitViewController.treeMaximumThickness)
        XCTAssertGreaterThan(
            tree.maximumThickness - tree.minimumThickness, 200,
            "a range this pane cannot travel in is a fixed pane wearing a divider"
        )
        // Wide enough for all four columns at their design widths at once.
        XCTAssertGreaterThanOrEqual(tree.maximumThickness, 220 + 90 + 116 + 72)

        controller.window?.setContentSize(NSSize(width: 1_400, height: 800))
        workspace.splitView.layoutSubtreeIfNeeded()
        let split = workspace.splitView

        for dividerIndex in 0..<2 {
            let grab = workspace.splitView(split, additionalEffectiveRectOfDividerAt: dividerIndex)
            let edge = split.arrangedSubviews[dividerIndex].frame.maxX
            XCTAssertLessThan(grab.minX, edge, "divider \(dividerIndex) has no slop on its leading side")
            XCTAssertGreaterThan(grab.maxX, edge, "divider \(dividerIndex) has no slop on its trailing side")
            XCTAssertEqual(
                grab.width,
                split.dividerThickness + 2 * WorkspaceSplitViewController.dividerGrabSlop,
                accuracy: 0.001
            )
            XCTAssertEqual(grab.height, split.bounds.height, accuracy: 0.001)
        }

        // A collapsed pane has no hairline, so it gets no band over the pane
        // that took its place.
        workspace.splitViewItems[2].isCollapsed = true
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.splitView(split, additionalEffectiveRectOfDividerAt: 1), .zero)
    }

    func test_treeUsesSourceListWithSettledColumnsAndDefaultSizeSort() {
        let controller = DirectoryTreeViewController(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))
        controller.loadView()

        XCTAssertEqual(controller.outlineView.style, .sourceList)
        XCTAssertEqual(controller.outlineView.tableColumns.map(\.title), ["Name", "Size", "%", "Items"])
        XCTAssertEqual(controller.outlineView.sortDescriptors.first?.key, TreeColumn.size.rawValue)
        XCTAssertEqual(controller.outlineView.sortDescriptors.first?.ascending, false)
    }
}

@MainActor
final class ScanPresentationModelTests: XCTestCase {
    func test_aSuspendedScanDoesNotBlockMainActorWork() async {
        let scanner = SuspendedScanner()
        let model = ScanPresentationModel(scanner: scanner)
        var mainActorEventRan = false

        model.start(root: URL(fileURLWithPath: "/tmp/paused"), mode: .folder)
        await Task.yield()
        mainActorEventRan = true

        XCTAssertTrue(mainActorEventRan)
        XCTAssertEqual(model.phase, .scanning)
        model.cancel()
    }

    func test_aRealFolderScanCompletesWithExactTotals() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDirStat-AppTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = folder.appendingPathComponent("payload.bin")
        try Data(repeating: 0x4D, count: 1_537).write(to: payload)
        // What it occupies, not what it is: the app measures blocks on disk
        // and 1,537 bytes are a whole block of them (ticket 13).
        let occupied = try payload.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize ?? -1

        let model = ScanPresentationModel()
        let completed = expectation(description: "scan completed")
        model.onChange = {
            if model.phase == .completed { completed.fulfill() }
        }
        model.start(root: folder, mode: .folder)

        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(model.root?.subtreeDiskBytes, Int64(occupied))
        XCTAssertEqual(model.root?.subtreeContentBytes, 1_537, "the length is carried beside it")
        XCTAssertEqual(model.root?.fileCount, 1)
        XCTAssertEqual(model.result?.reason, .completed)
    }
}

private actor SuspendedScanner: Scanning {
    func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            continuation.yield(.started(root: request.root, mode: request.mode, volumeCapacity: nil))
        }
    }

    nonisolated func cancel() {}
}
