import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

@MainActor
final class InspectorContentTests: XCTestCase {
    private let builder = InspectorContentBuilder(formatter: DisplayFormatter(locale: Locale(identifier: "en_US")))

    private func context(_ fixture: ScannedFixture) -> SelectionContext {
        SelectionContext(rootURL: fixture.root, rootNode: fixture.rootNode)
    }

    func test_aFileShowsIECSizeExactGroupedBytesFullPathAndKind() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("holiday.mp4", bytes: 1_536, in: root)
        }
        let node = try fixture.node(named: "holiday.mp4")
        // What it occupies, not what it is: 1,536 bytes of content are a whole
        // block on disk, and the block is the figure the app shows (ticket 13).
        let occupied = try onDiskBytes(of: fixture.root.appendingPathComponent("holiday.mp4"))

        let content = builder.content(for: .node(node), in: context(fixture))

        XCTAssertEqual(content.title, "holiday.mp4")
        XCTAssertEqual(content.subtitle, "Video")
        XCTAssertEqual(content.sizeCaption, "on disk")
        XCTAssertEqual(content.exactBytesText, groupedBytesText(occupied))
        XCTAssertGreaterThan(occupied, 1_536, "the fixture volume rounds a part-block file up")
        // The length is a whole display step away from the blocks, so the
        // inspector says so — and says it once.
        XCTAssertEqual(content.rows.filter { $0.label == "Content length" }.count, 1)
        XCTAssertEqual(content.path, fixture.root.appendingPathComponent("holiday.mp4").path)
        XCTAssertTrue(content.rows.contains(.init(label: "Kind", value: "Video")))
        XCTAssertTrue(content.showsActions)
        XCTAssertEqual(content.swatch, .kind(.video))
    }

    func test_aDirectoryReportsItsScannerCountsAndItsShareOfScanAndParent() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let inner = try makeDirectory("inner", in: root)
            let deeper = try makeDirectory("deeper", in: inner)
            try writeFile("a.bin", bytes: 300, in: inner)
            try writeFile("b.bin", bytes: 100, in: deeper)
            try writeFile("outside.bin", bytes: 600, in: root)
        }
        let inner = try fixture.node(named: "inner")

        let content = builder.content(for: .node(inner), in: context(fixture))

        // Three files, each smaller than a block, so each occupies exactly one:
        // `inner` holds two of the scan's three blocks.
        let occupied = try onDiskBytes(of: fixture.root.appendingPathComponent("inner/a.bin"))
            + onDiskBytes(of: fixture.root.appendingPathComponent("inner/deeper/b.bin"))

        XCTAssertEqual(content.subtitle, "Folder")
        XCTAssertEqual(content.sizeCaption, "total on disk")
        XCTAssertEqual(content.exactBytesText, groupedBytesText(occupied))
        XCTAssertTrue(content.rows.contains(.init(label: "Contains", value: "2 files · 1 folders")))
        XCTAssertTrue(content.rows.contains(.init(label: "% of scan", value: "66.7%")))
        XCTAssertTrue(content.rows.contains(.init(label: "% of parent", value: "66.7%")))
    }

    func test_theRootReportsOneHundredPercentOfItsParent() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("only.bin", bytes: 10, in: root)
        }

        let content = builder.content(for: .node(fixture.rootNode), in: context(fixture))

        XCTAssertTrue(content.rows.contains(.init(label: "% of parent", value: "100%")))
    }

    func test_aSymbolicLinkIsZeroBytesAndSaysItIsNeverFollowed() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("target.bin", bytes: 2_048, in: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias"),
                withDestinationURL: root.appendingPathComponent("target.bin")
            )
        }
        let link = try fixture.node(named: "alias")

        let content = builder.content(for: .node(link), in: context(fixture))

        XCTAssertEqual(content.sizeText, "0 bytes")
        XCTAssertEqual(content.sizeCaption, "no attributed bytes")
        XCTAssertEqual(content.exactBytesText, "0 bytes")
        XCTAssertTrue(content.notes.contains { $0.title == "Symbolic link — never followed." })
    }

    func test_aHardLinkNonOwnerIsZeroBytesAndNamesTheOwningPath() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let original = root.appendingPathComponent("first.bin")
            try Data(repeating: 0x2A, count: 4_096).write(to: original)
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("second.bin"))
        }

        // Whichever name the deterministic traversal reached first owns the
        // bytes; the other is the non-owner this test is about.
        let first = try fixture.node(named: "first.bin")
        let second = try fixture.node(named: "second.bin")
        let owner = first.subtreeDiskBytes > 0 ? first : second
        let nonOwner = first.subtreeDiskBytes > 0 ? second : first
        guard case .hardLinkElsewhere = nonOwner.attribution else {
            return XCTFail("the fixture did not produce a hard-link non-owner")
        }

        let content = builder.content(for: .node(nonOwner), in: context(fixture))

        XCTAssertEqual(content.exactBytesText, "0 bytes")
        let note = try XCTUnwrap(content.notes.first { $0.title == "Hard link — counted elsewhere." })
        XCTAssertTrue(
            note.detail.contains(fixture.root.appendingPathComponent(owner.name).path),
            "the note should carry the owning path, got: \(note.detail)"
        )
    }

    func test_aPackageIsOneItemAndSaysExpandingItSubdividesItsBox() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let package = try makeDirectory("Editor.app", in: root)
            let contents = try makeDirectory("Contents", in: package)
            try writeFile("Info.plist", bytes: 512, in: contents)
        }
        let package = try fixture.node(named: "Editor.app")

        XCTAssertEqual(package.kind, .package)
        let content = builder.content(for: .node(package), in: context(fixture))

        XCTAssertEqual(content.subtitle, "Package")
        XCTAssertEqual(content.sizeCaption, "total on disk")
        XCTAssertTrue(content.notes.contains { $0.title == "Package." })
        XCTAssertTrue(content.notes.contains { $0.detail.contains("subdivides its box") })
    }

    func test_anUnreadableEntryNeverGuessesASizeAndItsAncestorsAreIncomplete() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let locked = try makeDirectory("locked", in: root)
            try writeFile("hidden.bin", bytes: 64, in: locked)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        }
        let locked = try fixture.node(named: "locked")
        try XCTSkipIf(locked.readState == .complete, "this host let the scan read a chmod-000 directory")

        let content = builder.content(for: .node(locked), in: context(fixture))

        XCTAssertEqual(content.sizeText, "Unknown")
        XCTAssertEqual(content.sizeCaption, "not guessed")
        XCTAssertEqual(content.exactBytesText, "size never guessed")
        XCTAssertTrue(content.notes.contains { $0.title == "Unreadable." || $0.title == "Incomplete." })

        let rootContent = builder.content(for: .node(fixture.rootNode), in: context(fixture))
        XCTAssertTrue(rootContent.notes.contains { $0.title == "Incomplete." })
    }

    func test_aHiddenEntryIsLabelledHiddenBesideItsKind() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile(".secret.json", bytes: 20, in: root)
        }
        let hidden = try fixture.node(named: ".secret.json")

        XCTAssertEqual(builder.content(for: .node(hidden), in: context(fixture)).subtitle, "Code · Hidden")
    }

    // MARK: - The scan itself

    func test_theScanSummaryNamesTheFoldersThatCouldNotBeRead() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let locked = try makeDirectory("locked", in: root)
            try writeFile("hidden.bin", bytes: 64, in: locked)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        }
        let result = try XCTUnwrap(fixture.model.result)
        try XCTSkipIf(result.errors.isEmpty, "this host let the scan read a chmod-000 directory")

        let summary = try XCTUnwrap(builder.scanSummary(result: result, in: context(fixture)))

        XCTAssertEqual(summary.subtitle, "Completed with errors")
        XCTAssertTrue(summary.rows.contains(.init(label: "Folders not readable", value: "1")))
        XCTAssertTrue(
            summary.sampleNames.contains { $0.hasSuffix("/locked") },
            "the path is the point: a count says how wrong the total might be, a path says whether it matters"
        )
        XCTAssertTrue(summary.notes.contains { $0.severity == .error })
        XCTAssertFalse(summary.showsActions, "the scan is not a file")
    }

    func test_aScanThatReadEverythingSaysNothing() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("plain.bin", bytes: 100, in: root)
        }
        let result = try XCTUnwrap(fixture.model.result)

        XCTAssertNil(
            builder.scanSummary(result: result, in: context(fixture)),
            "an all-clear nobody asked for would push the placeholder off the pane for nothing"
        )
    }

    func test_theInspectorShowsTheScanSummaryWhileNothingIsSelected() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let locked = try makeDirectory("locked", in: root)
            try writeFile("hidden.bin", bytes: 64, in: locked)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        }
        try XCTSkipIf(
            fixture.model.result?.errors.isEmpty != false,
            "this host let the scan read a chmod-000 directory"
        )
        let (workspace, _, _) = fixture.makeWorkspace()
        // The harness builds the workspace from an already-finished scan, so
        // the terminal event that drives the panes in the app has to be
        // replayed here. `onChange` is the controller's own, set in its init.
        fixture.model.onChange?()

        XCTAssertEqual(
            workspace.inspectorViewController.content?.subtitle,
            "Completed with errors",
            "the state a window is in the moment a scan finishes"
        )

        workspace.selectionModel.select(.node(try fixture.node(named: "locked")), source: .tree)
        XCTAssertEqual(workspace.inspectorViewController.content?.title, "locked")

        workspace.selectionModel.clear()
        XCTAssertEqual(workspace.inspectorViewController.content?.subtitle, "Completed with errors")
    }

    // MARK: - The aggregate

    func test_anAggregateDescribesTheBucketAndOffersNoFileActions() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("big.bin", bytes: 1_000, in: root)
        }
        let descriptor = AggregateDescriptor(
            directory: fixture.rootNode,
            itemCount: 47,
            bytes: 3_072,
            mergedRootNames: (1...7).map { "tiny-\($0).bin" }
        )

        let content = builder.content(for: .aggregate(descriptor), in: context(fixture))

        XCTAssertEqual(content.title, "47 merged items")
        XCTAssertEqual(content.sizeText, "3.00 KiB")
        XCTAssertEqual(content.sizeCaption, "combined")
        XCTAssertEqual(content.exactBytesText, "3,072 bytes")
        XCTAssertTrue(content.rows.contains(.init(label: "Items", value: "47")))
        XCTAssertTrue(
            content.notes.contains { $0.title == "47 items below individual size, combined 3.00 KiB." },
            "the bucket must report its own combined count and size (§6.2)"
        )
        XCTAssertEqual(content.sampleNames.count, 5, "only a sample of the folded names is listed")
        XCTAssertEqual(content.additionalSampleCount, 2)
        XCTAssertNil(content.path, "an aggregate is not a file and has no path")
        XCTAssertFalse(content.showsActions, "an aggregate cannot be opened or revealed")
        XCTAssertEqual(content.swatch, .merged)
    }

    // MARK: - The two measures (ticket 13)

    /// The length line appears **when and only when** the two figures differ by
    /// more than a display step. A file whose length is a whole number of
    /// blocks gets no second line, because a row repeating the number above it
    /// is clutter on ~99% of rows.
    func test_theContentLengthLineAppearsOnlyWhenTheTwoMeasuresDiffer() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("aligned.bin", bytes: 4_096, in: root)
            try writeSparseFile("image.raw", length: 3 * 1_024 * 1_024 * 1_024, in: root)
        }

        let aligned = builder.content(for: .node(try fixture.node(named: "aligned.bin")), in: context(fixture))
        XCTAssertFalse(aligned.rows.contains { $0.label == "Content length" },
                       "a file that occupies what it is has nothing extra to say")

        let sparse = builder.content(for: .node(try fixture.node(named: "image.raw")), in: context(fixture))
        XCTAssertEqual(sparse.sizeText, "0 bytes")
        XCTAssertEqual(sparse.sizeCaption, "nothing on disk")
        XCTAssertTrue(sparse.rows.contains(.init(label: "Content length", value: "3.00 GiB")))
        XCTAssertTrue(
            sparse.notes.contains { $0.title == "3.00 GiB in length, nothing on disk." },
            "the striking case says so in words: \(sparse.notes.map(\.title))"
        )
    }

    /// A folder's line is the roll-up of both measures, not one file's — which
    /// is the whole reason content length is carried up the tree at all.
    func test_aFolderCarriesTheRolledUpLengthOfEverythingBeneathIt() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            let images = try makeDirectory("images", in: root)
            try writeSparseFile("a.raw", length: 2 * 1_024 * 1_024 * 1_024, in: images)
            try writeSparseFile("b.raw", length: 1_024 * 1_024 * 1_024, in: images)
        }

        let content = builder.content(for: .node(try fixture.node(named: "images")), in: context(fixture))

        XCTAssertTrue(content.rows.contains(.init(label: "Content length", value: "3.00 GiB")))
        XCTAssertEqual(content.sizeText, "0 bytes")
    }

    // MARK: - The tooltip says the same things

    func test_theTooltipCarriesNameBothByteFiguresKindAndFullPath() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            try writeFile("notes.pdf", bytes: 4_096, in: root)
        }
        let node = try fixture.node(named: "notes.pdf")

        let tooltip = builder.tooltip(for: .node(node), in: context(fixture))

        XCTAssertTrue(tooltip.contains("notes.pdf"))
        XCTAssertTrue(tooltip.contains("4.00 KiB"))
        XCTAssertTrue(tooltip.contains("4,096 bytes"))
        XCTAssertTrue(tooltip.contains("Document"))
        XCTAssertTrue(tooltip.contains(fixture.root.appendingPathComponent("notes.pdf").path))
    }

    func test_theAccessibilityLabelCarriesNameSizeAndKind() async throws {
        let fixture = try await ScannedFixture.make(in: self) { root in
            // A whole number of 4 KiB blocks, so what it occupies and what it
            // is are the same figure whatever the volume's block size.
            try writeFile("track.mp3", bytes: 4_096, in: root)
        }
        let node = try fixture.node(named: "track.mp3")

        XCTAssertEqual(
            builder.accessibilityLabel(for: .node(node)),
            "track.mp3, 4.00 KiB, Audio"
        )
        XCTAssertEqual(
            builder.accessibilityLabel(
                for: .aggregate(
                    AggregateDescriptor(directory: fixture.rootNode, itemCount: 9, bytes: 1_024, mergedRootNames: [])
                )
            ),
            "9 merged items, combined 1.00 KiB, aggregate"
        )
    }
}
