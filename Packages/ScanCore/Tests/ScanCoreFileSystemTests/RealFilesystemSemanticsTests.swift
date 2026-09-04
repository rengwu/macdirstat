import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Every semantic settled in tickets 03 and 04, seen happening on real files
/// (spec §3.1, §3.4, §3.5, §9.2).
///
/// The scripted suite proves these against metadata a test wrote by hand. This
/// one proves the production adapter reads the same facts out of a filesystem
/// that really has a sparse file, a looping symlink, two names for one inode,
/// a package, a 64-level chain and a directory nobody may read.
final class RealFilesystemSemanticsTests: RealFixtureTestCase {
    private var events: [ScanEvent] = []
    private var result: ScanResult!
    private var root: ScanNode!

    private func scan() async throws {
        events = await runProductionScan(root: scanRoot)
        result = try XCTUnwrap(events.result)
        root = result.root
    }

    /// What the manifest says one staged file occupies. Block counts are the
    /// host volume's business — a 5-byte file is a whole block on APFS and
    /// might not be somewhere else — so the fixture reads them once and every
    /// expectation here comes from that reading rather than from a constant.
    private func blocks(_ path: String) -> Int64 {
        manifest.attributedDiskBytesByPath[path] ?? -1
    }

    // MARK: - Totals

    func test_theScanTotalsMatchTheManifestExactly() async throws {
        try await scan()

        XCTAssertEqual(root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes)
        XCTAssertEqual(root.subtreeContentBytes, manifest.expectedAttributedContentBytes)
        XCTAssertEqual(root.fileCount, manifest.expectedFileCount)

        // The two are not close, and that is the point of this fixture: four
        // gigabytes of the content figure is two files occupying nothing.
        XCTAssertGreaterThan(
            root.subtreeContentBytes - root.subtreeDiskBytes,
            RealFixtureManifest.hiddenSparseBytes,
            "the sparse files stopped diverging from what they occupy"
        )

        let final = try XCTUnwrap(events.progressSnapshots.last)
        XCTAssertEqual(final.attributedDiskBytes, manifest.expectedAttributedDiskBytes)
        XCTAssertEqual(final.filesSeen, manifest.expectedFileCount)
        XCTAssertEqual(final.directoriesSeen, manifest.expectedDirectoryCount)
        XCTAssertEqual(final.currentPathTail, "", "the last snapshot is not still scanning something")
    }

    func test_fastModeMeasuresAPackageAsOneAtomicNode() async throws {
        let options = ScanOptions(
            progressInterval: .infinity,
            packageScanMode: .summarized
        )
        let fastEvents = await runProductionScan(root: scanRoot, options: options)
        let fastResult = try XCTUnwrap(fastEvents.result)
        let package = try XCTUnwrap(node(fastResult.root, at: "Fixture.app"))

        XCTAssertTrue(package.isPackageSummary)
        XCTAssertTrue(package.children.isEmpty, "fast mode must not build the app's interior tree")
        XCTAssertEqual(
            package.subtreeDiskBytes,
            blocks("Fixture.app/Contents/Info.plist")
                + blocks("Fixture.app/Contents/Resources/Sparse.bin")
        )
        XCTAssertEqual(
            package.subtreeContentBytes,
            manifest.infoPlistBytes + RealFixtureManifest.packageSparseBytes
        )
        XCTAssertEqual(package.fileCount, 2)
        XCTAssertEqual(package.folderDescendantCount, 2)
        XCTAssertEqual(
            fastResult.root.folderDescendantCount,
            Int(manifest.expectedDirectoryCount - 1)
        )
        XCTAssertEqual(fastResult.root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes)
        XCTAssertEqual(fastResult.root.subtreeContentBytes, manifest.expectedAttributedContentBytes)
    }

    func test_aFolderScanReportsNoCapacityAndNoCompletionFraction() async throws {
        try await scan()

        XCTAssertNil(result.volumeCapacity)
        XCTAssertNil(events.progressSnapshots.last?.approximateFraction,
                     "a folder scan has nothing honest to divide by (spec §5.5)")
    }

    /// The same tree, scanned twice, must produce the same node order and the
    /// same hard-link owner — the property the locale-independent within-
    /// directory sort exists for (ticket 03).
    func test_twoScansOfTheSameTreeAgreeOnOrderAndOwnership() async throws {
        try await scan()
        let firstOrder = flatten(root)
        let firstOwner = node(root, at: "z-duplicate.bin")?.attribution

        try await scan()

        XCTAssertEqual(flatten(root), firstOrder)
        XCTAssertEqual(node(root, at: "z-duplicate.bin")?.attribution, firstOwner)
    }

    func test_childrenAreOrderedByNameSoEqualSizedEntriesAreStable() async throws {
        try await scan()

        let names = root.children.map(\.name)
        XCTAssertEqual(names, names.sorted(), "the within-directory order is name-ascending")
        let a = try XCTUnwrap(names.firstIndex(of: "equal-a.bin"))
        let b = try XCTUnwrap(names.firstIndex(of: "equal-b.bin"))
        XCTAssertLessThan(a, b)
        XCTAssertEqual(node(root, at: "equal-a.bin")?.ownDiskBytes,
                       node(root, at: "equal-b.bin")?.ownDiskBytes)
    }

    // MARK: - Sizes

    /// **The fixture's headline case, pinned** (ticket 13). Three gigabytes of
    /// content length on however many blocks `ftruncate` actually allocated —
    /// zero, on every filesystem that supports sparse files. The attributed
    /// figure is asserted against the manifest's own reading of the staged
    /// file, so a later change to what the engine measures cannot move it
    /// quietly.
    func test_aSparseHiddenFileIsCountedAtItsBlocksAndCarriesItsLengthBeside() async throws {
        try await scan()

        let hidden = try XCTUnwrap(node(root, at: ".hidden.bin"))
        XCTAssertEqual(hidden.ownDiskBytes, manifest.hiddenSparseDiskBytes,
                       "the sparse file is attributed its allocated size and nothing else")
        XCTAssertEqual(hidden.ownContentBytes, RealFixtureManifest.hiddenSparseBytes,
                       "and its length is carried beside it, unchanged")
        XCTAssertLessThan(hidden.ownDiskBytes, RealFixtureManifest.hiddenSparseBytes / 1_000,
                          "a 3 GiB sparse file that occupies megabytes is not sparse")
        XCTAssertEqual(hidden.kind, .file)
        XCTAssertEqual(hidden.readState, .complete, "nothing went wrong: it is simply not on the disk")
        XCTAssertGreaterThan(RealFixtureManifest.hiddenSparseBytes, Int64(Int32.max),
                             "and its length does not fit in 32 bits")
    }

    func test_anEmptyFileIsOneItemOfZeroBytes() async throws {
        try await scan()

        let empty = try XCTUnwrap(node(root, at: "empty.bin"))
        XCTAssertEqual(empty.ownDiskBytes, 0)
        XCTAssertEqual(empty.ownContentBytes, 0)
        XCTAssertEqual(empty.fileCount, 1)
    }

    func test_anAliasNamedOrdinaryFileIsAttributedNormally() async throws {
        try await scan()

        let alias = try XCTUnwrap(node(root, at: "legacy.alias"))
        XCTAssertEqual(alias.kind, .file)
        XCTAssertEqual(alias.ownDiskBytes, blocks("legacy.alias"))
        XCTAssertEqual(alias.ownContentBytes, RealFixtureManifest.aliasBytes)
    }

    func test_extendedAttributeBytesAreNotContentBytes() async throws {
        try await scan()

        let file = try XCTUnwrap(node(root, at: "xattr.bin"))
        XCTAssertEqual(file.ownContentBytes, RealFixtureManifest.xattrDataForkBytes,
                       "a resource fork is metadata, not content (spec §3.1)")
        XCTAssertEqual(file.ownDiskBytes, blocks("xattr.bin"))
        XCTAssertLessThan(file.ownDiskBytes,
                          Int64(RealFixtureManifest.resourceForkBytes) + 4_096,
                          "a resource fork stored as an extended attribute is not blocks of the data fork")
    }

    // MARK: - Symlinks

    func test_symbolicLinksAreVisibleWeightlessAndNeverFollowed() async throws {
        try await scan()

        for name in ["link-to-hidden", "broken-link", "loop-link"] {
            let link = try XCTUnwrap(node(root, at: name), name)
            XCTAssertEqual(link.kind, .symbolicLink, name)
            XCTAssertEqual(link.ownDiskBytes, 0, name)
            XCTAssertEqual(link.subtreeDiskBytes, 0, name)
            XCTAssertEqual(link.fileCount, 0, name)
            XCTAssertTrue(link.children.isEmpty, name)
        }

        // The link to a 3 GiB file contributes nothing, even though the file it
        // points at is the largest thing in the tree.
        XCTAssertEqual(root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes)
    }

    /// `loop-link` points at its own ancestor. That the scan terminated at all,
    /// with exactly one node for the link and no repeated path, is the proof.
    func test_anAncestorLoopSymlinkCannotProduceATraversalLoop() async throws {
        try await scan()

        let paths = flatten(root)
        XCTAssertEqual(paths.filter { $0 == "loop-link" }.count, 1)
        XCTAssertTrue(paths.allSatisfy { !$0.contains("loop-link/") })
        XCTAssertEqual(Set(paths).count, paths.count, "no path appears twice")
    }

    // MARK: - Hard links and clones

    func test_theFirstInScopeNameOwnsTheInodeAndTheSecondIsWeightless() async throws {
        try await scan()

        let owner = try XCTUnwrap(node(root, at: "a-owner.bin"))
        XCTAssertEqual(owner.ownDiskBytes, blocks("a-owner.bin"))
        XCTAssertEqual(owner.ownContentBytes, RealFixtureManifest.hardLinkBytes)
        XCTAssertEqual(owner.attribution, .owned)

        let duplicate = try XCTUnwrap(node(root, at: "z-duplicate.bin"))
        XCTAssertEqual(duplicate.ownDiskBytes, 0)
        XCTAssertEqual(duplicate.ownContentBytes, 0,
                       "two names share one set of blocks and one set of contents")
        XCTAssertEqual(duplicate.attribution, .hardLinkElsewhere(owner: manifest.hardLinkOwnerPath))
        XCTAssertEqual(duplicate.fileCount, 1, "a deduplicated name is still one item (ticket 04)")
    }

    func test_theHardLinkNameOutsideTheRootIsNeitherSoughtNorShown() async throws {
        try await scan()

        XCTAssertFalse(flatten(root).contains { $0.hasSuffix("x-outside-link.bin") })
        // It is still there — the scan simply has no business with it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: manifest.outsideDirectory.appendingPathComponent("x-outside-link.bin").path
        ))
    }

    func test_anAPFSCloneIsCountedSeparately() async throws {
        try XCTSkipUnless(manifest.supportsCloning, "this volume cannot clone; the scripted case is the mandatory one")
        try await scan()

        let clone = try XCTUnwrap(node(root, at: "clone.bin"))
        XCTAssertEqual(clone.ownDiskBytes, blocks("clone.bin"))
        XCTAssertEqual(clone.ownContentBytes, RealFixtureManifest.hardLinkBytes)
        XCTAssertEqual(clone.attribution, .owned, "distinct identities are not deduplicated (spec §3.4)")
        // Ticket 13 accepted this direction of error out loud: a clone shares
        // its source's blocks and both report them in full, so a clone-heavy
        // volume over-reports where content length under-reported it.
        XCTAssertEqual(clone.ownDiskBytes, node(root, at: "a-owner.bin")?.ownDiskBytes,
                       "a clone reports the same blocks as its source, and both are counted")
    }

    // MARK: - Packages

    func test_aRealPackageIsMeasuredThroughAndPresentedAsOneItem() async throws {
        try await scan()

        let package = try XCTUnwrap(node(root, at: "Fixture.app"))
        XCTAssertEqual(package.kind, .package)
        XCTAssertEqual(package.subtreeDiskBytes,
                       blocks("Fixture.app/Contents/Info.plist")
                           + blocks("Fixture.app/Contents/Resources/Sparse.bin"),
                       "the rollup is exact at scan time")
        XCTAssertEqual(package.subtreeContentBytes,
                       manifest.infoPlistBytes + RealFixtureManifest.packageSparseBytes,
                       "and the length beside it is measured through the package too")
        XCTAssertEqual(package.fileCount, 2)
        XCTAssertFalse(package.children.isEmpty, "its real children are in the tree")
        XCTAssertTrue(package.initiallyPresentedChildren.isEmpty, "and it presents as one box")

        // The second sparse file: a gigabyte of length one level inside a
        // package that is measured through.
        let sparse = try XCTUnwrap(node(root, at: "Fixture.app/Contents/Resources/Sparse.bin"))
        XCTAssertEqual(sparse.ownDiskBytes, manifest.packageSparseDiskBytes)
        XCTAssertEqual(sparse.ownContentBytes, RealFixtureManifest.packageSparseBytes)
    }

    // MARK: - Depth

    func test_aSixtyFourDirectoryChainIsTraversedToItsLeaf() async throws {
        try await scan()

        let leaf = try XCTUnwrap(node(root, at: manifest.chainLeafRelativePath))
        XCTAssertEqual(leaf.ownDiskBytes, blocks(manifest.chainLeafRelativePath))
        XCTAssertEqual(leaf.ownContentBytes, RealFixtureManifest.chainLeafBytes)
        // root + 64 chain directories + the leaf file.
        XCTAssertEqual(depth(of: root), RealFixtureManifest.chainDepth + 2)
        XCTAssertEqual(node(root, at: "chain-01")?.subtreeDiskBytes,
                       blocks(manifest.chainLeafRelativePath),
                       "64 levels of roll-up carry the leaf's blocks to the top of the chain")
        XCTAssertEqual(node(root, at: "chain-01")?.subtreeContentBytes,
                       RealFixtureManifest.chainLeafBytes)
    }

    // MARK: - Resilience

    func test_anUnreadableDirectoryIsRecordedWithoutAbortingItsSibling() async throws {
        XCTAssertNotEqual(getuid(), 0, "this case is meaningless as root")
        try await scan()

        // The scan ran to completion: a directory nobody may read is a
        // recoverable problem, not a failed scan (spec §5.3).
        XCTAssertEqual(result.reason, .completed)
        XCTAssertNil(events.failure)

        let locked = try XCTUnwrap(node(root, at: "locked"))
        XCTAssertEqual(locked.readState, .unreadable)
        XCTAssertEqual(locked.subtreeDiskBytes, 0, "its real bytes are not guessed (spec §3.5)")
        XCTAssertTrue(locked.children.isEmpty)

        // Its ancestor says so, and the result says so.
        XCTAssertEqual(root.readState, .incomplete)
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 1))

        // The readable sibling was scanned anyway.
        XCTAssertEqual(node(root, at: "readable-sibling/sibling.bin")?.ownDiskBytes,
                       blocks("readable-sibling/sibling.bin"))
    }

    func test_theUnreadableDirectoryIsCountedOnceAsAPermissionProblem() async throws {
        try await scan()

        XCTAssertEqual(result.errors.total, 1)
        XCTAssertEqual(result.errors.byCategory[.unreadableDirectory], 1)
        XCTAssertNil(result.errors.byCategory[.disappeared])
        XCTAssertFalse(result.errors.truncated)

        let record = try XCTUnwrap(result.errors.details.first)
        XCTAssertEqual(record.category, .unreadableDirectory)
        XCTAssertEqual(record.path, [scanRoot.lastPathComponent, "locked"])
        XCTAssertFalse(record.message.isEmpty)
    }

    func test_everyPaletteGroupHasAFileAndTheirBytesRollUp() async throws {
        try await scan()

        let kinds = try XCTUnwrap(node(root, at: "kinds"))
        XCTAssertEqual(kinds.children.map(\.name), RealFixtureManifest.paletteFileNames.sorted())
        XCTAssertEqual(
            kinds.subtreeDiskBytes,
            RealFixtureManifest.paletteFileNames.reduce(0) { $0 + blocks("kinds/\($1)") }
        )
        XCTAssertEqual(kinds.subtreeContentBytes, RealFixtureManifest.paletteTotalBytes)
        XCTAssertEqual(kinds.fileCount, Int64(RealFixtureManifest.paletteFileNames.count))
        XCTAssertTrue(kinds.children.allSatisfy { $0.kind == .file },
                      "a fixed extension does not make an entry anything but a file")
    }

    // MARK: - What the traversal asked the filesystem for

    /// One shallow listing per directory entered, and not one call beneath a
    /// symlink — the two claims the tree's shape alone cannot make (spec §8.2,
    /// §9.3).
    func test_eachDirectoryIsListedExactlyOnceAndNoLinkIsEverListed() async throws {
        let listed = SharedPaths()
        let probe = InterceptingProbe { url, _ in listed.append(url.path) }

        let events = await runProductionScan(root: scanRoot, probe: probe)
        XCTAssertEqual(events.result?.reason, .completed)

        let paths = listed.paths
        XCTAssertEqual(Int64(paths.count), manifest.expectedDirectoryCount,
                       "one listing per directory, including the one that failed")
        XCTAssertEqual(Set(paths).count, paths.count, "no directory is listed twice")
        for name in ["loop-link", "link-to-hidden", "broken-link"] {
            XCTAssertFalse(paths.contains { $0.contains("/\(name)") }, name)
        }
    }

    // MARK: - Live change

    /// Live change is best-effort, and the two halves of it look different on a
    /// real filesystem (spec §3.5, and the map's note against this ticket).
    ///
    /// A **directory** that vanishes after its parent listed it is caught: its
    /// own listing is a second call, and that call fails with "no such file".
    /// A **file** that vanishes is not, and cannot be: it was described
    /// entirely by its parent's listing and is never read again (spec §8.2), so
    /// it is still counted at the length that listing reported. Seen here
    /// happening rather than argued about.
    func test_aVanishedDirectoryIsRecordedButAVanishedFileIsStillCounted() async throws {
        let sibling = scanRoot.appendingPathComponent("readable-sibling", isDirectory: true)
        let file = scanRoot.appendingPathComponent("xattr.bin")

        // Both are listed with the root, and both are removed once that listing
        // is done — before the walk reaches either of them.
        let probe = InterceptingProbe { _, index in
            guard index == 2 else { return }
            try? FileManager.default.removeItem(at: sibling)
            try? FileManager.default.removeItem(at: file)
        }

        events = await runProductionScan(root: scanRoot, probe: probe)
        result = try XCTUnwrap(events.result)
        root = result.root

        // The directory: caught, marked, and counted as live change rather than
        // as a permission problem.
        let vanished = try XCTUnwrap(node(root, at: "readable-sibling"))
        XCTAssertEqual(vanished.readState, .unreadable)
        XCTAssertEqual(vanished.subtreeDiskBytes, 0)
        XCTAssertEqual(result.errors.byCategory[.disappeared], 1)

        // The file: not caught, and still carrying the size the listing gave.
        let stale = try XCTUnwrap(node(root, at: "xattr.bin"))
        XCTAssertEqual(stale.ownDiskBytes, blocks("xattr.bin"))
        XCTAssertEqual(stale.ownContentBytes, RealFixtureManifest.xattrDataForkBytes)
        XCTAssertEqual(stale.readState, .complete)

        // The scan still completes; only the sibling's bytes are missing.
        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(root.subtreeDiskBytes,
                       manifest.expectedAttributedDiskBytes - blocks("readable-sibling/sibling.bin"))
        XCTAssertEqual(result.errors.total, 2, "the unreadable directory and the vanished one")
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 2))
    }

    /// **What the two spellings of one name do on a real volume** (ticket 15).
    ///
    /// The scripted suite decides the order; only a filesystem can say whether
    /// the pair can exist at all. macOS is not one answer here: an APFS volume
    /// that is case-insensitive is normalization-*insensitive* too, so the
    /// second `mkdir` collides and the directory holds one entry; a
    /// case-sensitive APFS volume, an exFAT stick or a disk image keeps both.
    /// This test runs on whichever kind it finds, asserts what that kind
    /// implies, and prints which one it was — so a green run on a laptop is
    /// never mistaken for proof the pair was ordered.
    func test_aVolumeThatKeepsBothSpellingsOfOneNameOrdersThemByCodePoint() async throws {
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let manager = FileManager.default
        let directory = fixture.directory.appendingPathComponent("normalization", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        try manager.createDirectory(
            at: directory.appendingPathComponent(precomposed, isDirectory: true),
            withIntermediateDirectories: false
        )
        let second = directory.appendingPathComponent(decomposed, isDirectory: true)
        let volumeKeepsBoth = (try? manager.createDirectory(at: second, withIntermediateDirectories: false)) != nil

        let events = await runProductionScan(root: directory)
        let scanned = try XCTUnwrap(events.result)
        let names = scanned.root.children.map { Array($0.name.utf8) }

        if volumeKeepsBoth {
            print("[fixture] this volume keeps both spellings of one name")
            XCTAssertEqual(names, [Array(decomposed.utf8), Array(precomposed.utf8)],
                           "U+0065 precedes U+00E9, so the decomposed name sorts first")
        } else {
            print("[fixture] this volume folds the two spellings into one name")
            XCTAssertEqual(names.count, 1, "a normalization-insensitive volume kept one of them")
        }
    }

    /// Nothing in this fixture crosses a volume boundary or is a remote-only
    /// placeholder, so there is nothing to exclude — and an exclusion count of
    /// zero is what keeps "Incomplete" meaning "something went wrong".
    func test_nothingIsExcluded() async throws {
        try await scan()

        XCTAssertEqual(result.exclusions.total, 0)
        XCTAssertTrue(result.exclusions.byReason.isEmpty)
    }
}
