import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The production adapter, read directly — what `FileManager` and the URL
/// resource keys actually report for each staged case (spec §5.1, §9.2).
///
/// The scan-level consequences are `RealFilesystemSemanticsTests`'; this suite
/// pins the facts those consequences rest on, so a wrong total there can be
/// told apart from a wrong reading here.
final class ProductionProbeTests: RealFixtureTestCase {
    private let probe = FileManagerDirectoryProbe()

    private func rootEntries() throws -> [String: EntryMeta] {
        Dictionary(uniqueKeysWithValues: try probe.list(scanRoot).map { ($0.name, $0) })
    }

    func test_listingIncludesHiddenEntriesAndNamesThemByComponent() throws {
        let entries = try rootEntries()

        // Hidden files and directories are included (spec §3.4).
        let hidden = try XCTUnwrap(entries[".hidden.bin"])
        XCTAssertTrue(hidden.isRegularFile)
        XCTAssertEqual(hidden.name, ".hidden.bin", "a name is the last component, never a path")
    }

    func test_aSparseFileReportsItsLogicalLengthAndNotItsAllocation() throws {
        let hidden = try XCTUnwrap(try rootEntries()[".hidden.bin"])
        XCTAssertEqual(hidden.fileSize, RealFixtureManifest.hiddenSparseBytes)

        // Read separately — the probe deliberately never fetches this key. A
        // sparse 3 GiB file occupies almost nothing, so a probe that reported
        // allocation instead of logical length could not produce this number.
        let allocated = try scanRoot.appendingPathComponent(".hidden.bin")
            .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? -1
        XCTAssertLessThan(Int64(allocated), RealFixtureManifest.hiddenSparseBytes / 1000,
                          "the fixture's sparse file was materialized; the case it stages is gone")
    }

    func test_extendedAttributesAndAResourceForkAreNotContentBytes() throws {
        let xattrFile = try XCTUnwrap(try rootEntries()["xattr.bin"])
        XCTAssertEqual(xattrFile.fileSize, RealFixtureManifest.xattrDataForkBytes)
        XCTAssertGreaterThan(listxattr(scanRoot.appendingPathComponent("xattr.bin").path, nil, 0, 0), 0,
                             "the fixture's extended attributes are missing")
    }

    func test_aSymbolicLinkIsReportedAsALinkAndNeverAsADirectory() throws {
        let entries = try rootEntries()

        for name in ["link-to-hidden", "broken-link", "loop-link"] {
            let link = try XCTUnwrap(entries[name], name)
            XCTAssertTrue(link.isSymbolicLink, name)
            XCTAssertFalse(link.isRegularFile, name)
            // The one that matters: `loop-link` points at its own ancestor
            // directory, and the resource values still say "not a directory",
            // so nothing can be tempted to descend it.
            XCTAssertFalse(link.isDirectory, name)
        }
    }

    func test_aBrokenSymbolicLinkIsStillListedAndDescribed() throws {
        let broken = try XCTUnwrap(try rootEntries()["broken-link"])
        XCTAssertTrue(broken.isSymbolicLink)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scanRoot.appendingPathComponent("nothing-here.bin").path
        ))
    }

    func test_hardLinkedNamesShareOneIdentityAndReportALinkCountAboveOne() throws {
        let entries = try rootEntries()
        let owner = try XCTUnwrap(entries["a-owner.bin"])
        let duplicate = try XCTUnwrap(entries["z-duplicate.bin"])

        XCTAssertEqual(owner.linkCount, 3, "two names in scope plus the one outside it")
        XCTAssertEqual(duplicate.linkCount, 3)
        XCTAssertEqual(owner.fileIdentity, duplicate.fileIdentity)
        XCTAssertEqual(owner.fileSize, RealFixtureManifest.hardLinkBytes)
        XCTAssertEqual(duplicate.fileSize, RealFixtureManifest.hardLinkBytes,
                       "both names report the inode's length; deduplication is the engine's job")
    }

    func test_anAPFSCloneIsADistinctIdentityWithOneLink() throws {
        try XCTSkipUnless(manifest.supportsCloning, "this volume cannot clone; the scripted case is the mandatory one")

        let entries = try rootEntries()
        let owner = try XCTUnwrap(entries["a-owner.bin"])
        let clone = try XCTUnwrap(entries["clone.bin"])

        XCTAssertNotEqual(owner.fileIdentity, clone.fileIdentity,
                          "a clone is its own inode, which is why it is not deduplicated (spec §3.4)")
        XCTAssertEqual(clone.linkCount, 1)
    }

    func test_aRealPackageIsFlaggedAsAPackageAndItsContentsAreOrdinary() throws {
        let package = try XCTUnwrap(try rootEntries()["Fixture.app"])
        XCTAssertTrue(package.isDirectory)
        XCTAssertTrue(package.isPackage)

        let contents = try probe.list(manifest.packageDirectory.appendingPathComponent("Contents"))
        XCTAssertEqual(contents.first(where: { $0.name == "Info.plist" })?.fileSize, manifest.infoPlistBytes)
    }

    func test_everyEntryCarriesTheRootsVolumeIdentifier() throws {
        let rootVolume = try probe.metadata(of: scanRoot).volumeIdentifier
        XCTAssertNotNil(rootVolume, "without this the device-boundary check cannot fire at all")

        for entry in try probe.list(scanRoot) {
            XCTAssertEqual(entry.volumeIdentifier, rootVolume, entry.name)
        }
    }

    func test_listingAnUnreadableDirectoryFailsAsAPermissionProblemNotAMissingOne() throws {
        XCTAssertNotEqual(getuid(), 0, "this case is meaningless as root")

        XCTAssertThrowsError(try probe.list(manifest.lockedDirectory)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, NSFileReadNoPermissionError)
        }
    }

    func test_metadataOfAMissingItemFailsAsNoSuchFile() throws {
        XCTAssertThrowsError(try probe.metadata(of: scanRoot.appendingPathComponent("nothing-here"))) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, NSFileReadNoSuchFileError)
        }
    }

    func test_volumeInfoReportsALocalVolumeThatSupportsHardLinks() throws {
        let info = try probe.volumeInfo(for: scanRoot)
        XCTAssertTrue(info.isLocal, "the test temporary directory must be on a local volume")
        XCTAssertTrue(info.supportsHardLinks)
        let capacity = try XCTUnwrap(info.capacity)
        XCTAssertGreaterThan(capacity.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(capacity.totalBytes, capacity.availableBytes)
    }

    // MARK: - The fallback for an entry whose resource values cannot be read

    func test_theStatFallbackDescribesAKindAndALogicalLength() throws {
        let meta = FileManagerDirectoryProbe.entryMeta(
            name: "a-owner.bin",
            byStattingPathAt: scanRoot.appendingPathComponent("a-owner.bin").path
        )
        XCTAssertTrue(meta.isRegularFile)
        XCTAssertEqual(meta.fileSize, RealFixtureManifest.hardLinkBytes)
        // Left nil on purpose: an identity built here would not compare equal
        // to the opaque ones every other entry carries, and a hard link that
        // failed to match its owner would be counted twice.
        XCTAssertNil(meta.fileIdentity)
        XCTAssertNil(meta.linkCount)
    }

    func test_theStatFallbackDescribesASymlinkAsItselfNotAsItsTarget() throws {
        let meta = FileManagerDirectoryProbe.entryMeta(
            name: "link-to-hidden",
            byStattingPathAt: scanRoot.appendingPathComponent("link-to-hidden").path
        )
        XCTAssertTrue(meta.isSymbolicLink)
        XCTAssertFalse(meta.isRegularFile)
        XCTAssertNil(meta.fileSize, "a link has no content length of its own")
    }

    func test_anEntryThatVanishedEntirelyKeepsItsNameAndGuessesNothing() throws {
        let meta = FileManagerDirectoryProbe.entryMeta(
            name: "gone.bin",
            byStattingPathAt: scanRoot.appendingPathComponent("gone.bin").path
        )
        XCTAssertEqual(meta.name, "gone.bin")
        XCTAssertNil(meta.fileSize)
        XCTAssertFalse(meta.isDirectory)
        XCTAssertFalse(meta.isRegularFile)
        XCTAssertFalse(meta.isSymbolicLink)
    }

    func test_anUnrecognizedCloudStatusCountsThePresentFile() {
        // The third-party provider case (spec §3.4): `nil` means "count what is
        // there", not "omit it".
        XCTAssertNil(FileManagerDirectoryProbe.cloudStatus(nil))
        XCTAssertEqual(FileManagerDirectoryProbe.cloudStatus(.notDownloaded), .notDownloaded)
        XCTAssertEqual(FileManagerDirectoryProbe.cloudStatus(.downloaded), .downloaded)
        XCTAssertEqual(FileManagerDirectoryProbe.cloudStatus(.current), .current)
    }
}
