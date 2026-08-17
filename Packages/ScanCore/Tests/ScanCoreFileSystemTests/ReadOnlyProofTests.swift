import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The read-only proof on a real filesystem (spec §9.2, §10, and the map's
/// non-negotiable): a full production scan of a real tree leaves that tree
/// byte-for-byte as it found it, and the adapter that drove it calls no API
/// that could have done otherwise.
///
/// The fingerprint covers the fixture's **whole owned directory**, not just the
/// scan root — so a scan that reached out of scope, or that touched the
/// out-of-scope hard link, would show up here too.
final class ReadOnlyProofTests: RealFixtureTestCase {
    func test_aFullScanOfTheRealFixtureChangesNothing() async throws {
        let before = try fixture.fingerprint()

        let events = await runProductionScan(root: scanRoot)
        let result = try XCTUnwrap(events.result)

        // The proof is only worth something if the scan actually did the work.
        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.root.subtreeDiskBytes, manifest.expectedAttributedDiskBytes)
        XCTAssertGreaterThan(before.entries.count, 100, "the fixture did not stage")

        let after = try fixture.fingerprint()
        let differences = after.differences(from: before)
        XCTAssertEqual(differences, [], "the scan changed the tree:\n" + differences.joined(separator: "\n"))
    }

    func test_repeatedScansStillChangeNothing() async throws {
        let before = try fixture.fingerprint()

        for _ in 0..<3 {
            _ = await runProductionScan(root: scanRoot)
        }

        let differences = try fixture.fingerprint().differences(from: before)
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    /// A scan that fails at pre-flight, and a scan that is cancelled part-way,
    /// are terminal paths too — neither may leave a mark.
    func test_neitherAFailedNorACancelledScanChangesAnything() async throws {
        let before = try fixture.fingerprint()

        let missing = scanRoot.appendingPathComponent("nothing-here", isDirectory: true)
        _ = await runProductionScan(root: missing)

        let scanner = Scanner()
        let probe = InterceptingProbe { _, index in
            if index == 2 { scanner.cancel() }
        }
        let stream = await scanner.scan(makeProductionRequest(root: scanRoot, probe: probe))
        let cancelled = await collectEvents(stream)
        XCTAssertEqual(cancelled.result?.reason, .cancelled)

        let differences = try fixture.fingerprint().differences(from: before)
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    // MARK: - The adapter's own source

    /// Read-only is structural, not a matter of discipline (spec §10). The
    /// seam has no write/download/open-data requirement — `ScanCoreTests`
    /// holds that line — and this asserts the production implementation
    /// behind it calls no such API either. Asserted against the source text
    /// because Swift offers no way to ask a type what it called.
    private static let bannedCalls = [
        "startdownloading", "evictubiquitous",       // would fetch a cloud placeholder
        "createfile", "createdirectory", "removeitem", "trashitem",
        "moveitem", "copyitem", "linkitem", "replaceitem", "setattributes",
        "filehandle", "outputstream", "contentsoffile", "contents(atpath",
        "data(contentsof",                            // would read file contents
        ".write(", "fwrite", "unlink(", "truncate(", "chmod(", "setxattr("
    ]

    private var probeSource: String {
        get throws {
            let sourceFile = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ScanCoreFileSystemTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // ScanCore (package root)
                .appendingPathComponent("Sources/ScanCore/FileManagerDirectoryProbe.swift")
            return try String(contentsOf: sourceFile, encoding: .utf8)
        }
    }

    /// Code lines only: prose in a doc comment about downloading nothing must
    /// not be mistaken for a call.
    private var probeCode: String {
        get throws {
            try probeSource
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.isEmpty }
                .joined(separator: "\n")
                .lowercased()
        }
    }

    func test_theProductionProbeCallsNoWriteDownloadOrContentsAPI() throws {
        let code = try probeCode
        XCTAssertTrue(code.contains("struct filemanagerdirectoryprobe"),
                      "the adapter moved; this guard must move with it")

        for banned in Self.bannedCalls {
            XCTAssertFalse(
                code.contains(banned),
                "FileManagerDirectoryProbe calls something matching \"\(banned)\" — it must stay listing + metadata only"
            )
        }
    }

    func test_theProductionProbeExposesExactlyTheFourSeamMethods() throws {
        let publicFunctions = try probeSource
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public func ") }

        XCTAssertEqual(publicFunctions, [
            "public func list(_ url: URL) throws -> [EntryMeta] {",
            "public func metadata(of url: URL) throws -> EntryMeta {",
            "public func volumeInfo(for url: URL) throws -> VolumeInfo {",
            // `getmntinfo(3)`: the mount table, read once per scan, so a
            // filesystem mounted inside the root's own volume is walked last
            // rather than shadowing the paths a person recognises (spec §3.3).
            "public func mountPointPaths() -> Set<String> {"
        ])
    }

    /// The mount table this machine actually reports, through the seam. It has
    /// to contain the root, and everything in it has to be an absolute path —
    /// the comparison the traversal makes is a string one.
    func test_theProbeReadsThisMachinesMountTable() {
        let mounts = FileManagerDirectoryProbe().mountPointPaths()

        XCTAssertTrue(mounts.contains("/"), "every Mac has a root mount")
        XCTAssertTrue(mounts.allSatisfy { $0.hasPrefix("/") })
        XCTAssertTrue(mounts.allSatisfy { $0 == "/" || !$0.hasSuffix("/") },
                      "a trailing slash would never match a URL's path")
        // The fixture is an ordinary directory on the boot volume, so nothing
        // beneath it can be a mount point.
        XCTAssertFalse(mounts.contains(scanRoot.path))
    }

    /// The fixture stages no ubiquitous item, and nothing in a scan of it can
    /// have asked for one.
    func test_noEntryInTheRealFixtureIsACloudItem() throws {
        let entries = try FileManagerDirectoryProbe().list(scanRoot)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { !$0.isUbiquitousItem })
        XCTAssertTrue(entries.allSatisfy { $0.cloudDownloadingStatus == nil })
    }
}
