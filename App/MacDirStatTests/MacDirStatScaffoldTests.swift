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
        XCTAssertTrue(workspace.splitViewItems[1].viewController is TreemapPlaceholderViewController)
        XCTAssertTrue(workspace.splitViewItems[2].viewController is InspectorPlaceholderViewController)
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
        try Data(repeating: 0x4D, count: 1_537).write(to: folder.appendingPathComponent("payload.bin"))

        let model = ScanPresentationModel()
        let completed = expectation(description: "scan completed")
        model.onChange = {
            if model.phase == .completed { completed.fulfill() }
        }
        model.start(root: folder, mode: .folder)

        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(model.root?.subtreeBytes, 1_537)
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
