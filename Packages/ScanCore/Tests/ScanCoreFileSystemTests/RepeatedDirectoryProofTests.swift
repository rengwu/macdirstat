import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Directory re-entry, on this machine's real filesystem (spec §3.3, §9.2).
///
/// Two halves, because macOS only lets a test have one of them:
///
/// 1. **The premise, measured.** A firmlink is the operating system's to
///    create — `/usr/share/firmlinks` is read at boot and no API offers a
///    second one — so the facts the guard rests on are asserted against the
///    graft Apple already ships: `/Users` and `/System/Volumes/Data/Users` are
///    one directory wearing two paths, and every fact the engine reads says so.
/// 2. **The behaviour, end to end.** A real staged tree, scanned through the
///    production probe, with one real directory presented under a second name —
///    an emulated firmlink at the seam, doing to the listing exactly what the
///    kernel does at `/`. Every identity, size and listing in it comes off the
///    disk; only the extra name is the test's.
final class RepeatedDirectoryProofTests: RealFixtureTestCase {
    private let dataVolumeRoot = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)

    private func skipUnlessHostHasFirmlinks() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dataVolumeRoot.path),
            "this host has no /System/Volumes/Data — nothing to measure the premise against"
        )
    }

    // MARK: - The premise, measured on the graft macOS already ships

    /// The bug in one assertion: two paths, one directory, and a device check
    /// that cannot tell.
    func test_theHostsFirmlinkGraftReportsOneIdentityAndOneVolumeAtTwoPaths() throws {
        try skipUnlessHostHasFirmlinks()
        let probe = FileManagerDirectoryProbe()

        for name in ["Users", "Applications", "Library"] {
            let direct = URL(fileURLWithPath: "/" + name, isDirectory: true)
            let grafted = dataVolumeRoot.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: direct.path),
                  FileManager.default.fileExists(atPath: grafted.path)
            else { continue }

            let a = try probe.metadata(of: direct)
            let b = try probe.metadata(of: grafted)

            XCTAssertNotNil(a.fileIdentity, "/\(name) has no readable identity")
            XCTAssertEqual(a.fileIdentity, b.fileIdentity,
                           "/\(name) and its firmlinked twin are one directory")
            XCTAssertEqual(a.volumeIdentifier, b.volumeIdentifier,
                           "…and macOS reports one volume for both, which is why the boundary check descends")
        }
    }

    /// Why the hard-link index cannot catch it: these are directories, and they
    /// report a link count of 1, so `claim` answers `.notALink` without ever
    /// reaching its map.
    func test_theHardLinkIndexCannotSeeAFirmlinkGraft() throws {
        try skipUnlessHostHasFirmlinks()
        let probe = FileManagerDirectoryProbe()
        let direct = try probe.metadata(of: URL(fileURLWithPath: "/Users", isDirectory: true))
        let grafted = try probe.metadata(of: dataVolumeRoot.appendingPathComponent("Users", isDirectory: true))

        XCTAssertEqual(direct.linkCount, 1)
        XCTAssertEqual(grafted.linkCount, 1)

        var index = HardLinkIndex(isEnabled: true)
        let first = ScanNode(name: "Users", kind: .directory, parent: nil)
        let second = ScanNode(name: "Users", kind: .directory, parent: nil)
        XCTAssertEqual(index.claim(direct, for: first), .notALink)
        XCTAssertEqual(index.claim(grafted, for: second), .notALink)
        XCTAssertEqual(index.count, 0, "nothing was indexed, so nothing could have been deduplicated")
    }

    /// And why a mount point is never offered to the visited index: the two
    /// volume roots share an identity while holding **different** entries.
    /// Treating them as one directory would lose whatever only the second one
    /// can reach.
    func test_theTwoVolumeRootsShareAnIdentityWhileHoldingDifferentEntries() throws {
        try skipUnlessHostHasFirmlinks()
        let probe = FileManagerDirectoryProbe()

        let systemRoot = try probe.metadata(of: URL(fileURLWithPath: "/", isDirectory: true))
        let dataRoot = try probe.metadata(of: dataVolumeRoot)
        XCTAssertEqual(systemRoot.fileIdentity, dataRoot.fileIdentity,
                       "both volume roots are inode 2, and macOS reports one volume identifier")

        let mounts = probe.mountPointPaths()
        XCTAssertTrue(mounts.contains("/"))
        XCTAssertTrue(mounts.contains(dataVolumeRoot.path),
                      "the data volume is a mount of its own — which is the only fact that tells them apart")

        let atSystemRoot = Set(try probe.list(URL(fileURLWithPath: "/", isDirectory: true)).map(\.name))
        let atDataRoot = Set(try probe.list(dataVolumeRoot).map(\.name))
        XCTAssertFalse(atDataRoot.subtracting(atSystemRoot).isEmpty,
                       "the data volume's root holds entries reachable nowhere else")
    }

    // MARK: - The behaviour, end to end on a real tree

    /// `kinds` — eleven real files, one per palette group — presented a second
    /// time as `zz-graft`, the way `/Users` is presented a second time under
    /// `/System/Volumes/Data`.
    private var graftedProbe: FirmlinkEmulatingProbe {
        FirmlinkEmulatingProbe(root: scanRoot, presenting: "kinds", alsoAs: "zz-graft")
    }

    func test_aDirectoryReachableTwiceUnderTheScanRootContributesOnce() async throws {
        let before = try fixture.fingerprint()
        let plainEvents = await runProductionScan(root: scanRoot)
        let graftedEvents = await runProductionScan(root: scanRoot, probe: graftedProbe)
        let plain = try XCTUnwrap(plainEvents.result)
        let grafted = try XCTUnwrap(graftedEvents.result)

        XCTAssertEqual(
            grafted.root.subtreeBytes, manifest.expectedAttributedBytes,
            "the second name added no bytes"
        )
        XCTAssertEqual(grafted.root.subtreeBytes, plain.root.subtreeBytes)
        XCTAssertEqual(grafted.root.fileCount, plain.root.fileCount, "and no files")
        XCTAssertEqual(
            flatten(grafted.root).count, flatten(plain.root).count + 1,
            "one node per real directory, plus the second name itself"
        )

        let graft = try XCTUnwrap(node(grafted.root, at: "zz-graft"))
        XCTAssertTrue(graft.children.isEmpty, "nothing beneath the second name was walked")
        XCTAssertEqual(graft.subtreeBytes, 0)
        XCTAssertEqual(graft.attribution, .directoryCountedElsewhere(owner: [scanRoot.lastPathComponent, "kinds"]))

        // An exclusion, not an error: nothing went wrong.
        XCTAssertEqual(grafted.exclusions.byReason, [.repeatedDirectory: 1])
        XCTAssertEqual(grafted.errors.byCategory, plain.errors.byCategory)
        XCTAssertEqual(grafted.root.readState, plain.root.readState, "ancestors are no less complete")

        let differences = try fixture.fingerprint().differences(from: before)
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    /// The positive control. The same real fixture, the same emulated firmlink,
    /// the guard switched off: eleven real files are counted twice and their
    /// 66 bytes are counted twice — which is the field report at 1/5,000,000
    /// scale, and the proof that the assertion above is not vacuous.
    func test_withoutTheGuardTheSameRealDirectoryIsCountedTwice() async throws {
        var options = terminalSnapshotsOnly
        options.deduplicatesRepeatedDirectories = false

        let events = await runProductionScan(root: scanRoot, probe: graftedProbe, options: options)
        let doubled = try XCTUnwrap(events.result)

        XCTAssertEqual(
            doubled.root.subtreeBytes,
            manifest.expectedAttributedBytes + RealFixtureManifest.paletteTotalBytes,
            "without the guard the grafted directory's bytes land twice"
        )
        XCTAssertEqual(
            node(doubled.root, at: "zz-graft")?.children.count,
            RealFixtureManifest.paletteFileNames.count,
            "…and every file under it is walked a second time"
        )
        XCTAssertTrue(doubled.exclusions.isEmpty)
    }
}

// MARK: - An emulated firmlink

/// The production probe with one directory presented under a second name.
///
/// No unprivileged API on macOS can graft a directory into a second path — no
/// `link(2)` on a directory, no firmlink, no mount without root — so the one
/// thing this test cannot stage on disk is staged at the seam instead. Every
/// other fact stays the filesystem's own: the second name carries the real
/// directory's real identity, and a listing under it is the real directory's
/// real listing, which is exactly what the kernel does for
/// `/System/Volumes/Data/Users`.
final class FirmlinkEmulatingProbe: DirectoryProbe, @unchecked Sendable {
    private let wrapped: DirectoryProbe
    private let root: URL
    private let target: String
    private let graft: String

    init(_ wrapped: DirectoryProbe = FileManagerDirectoryProbe(),
         root: URL, presenting target: String, alsoAs graft: String) {
        self.wrapped = wrapped
        self.root = root.standardizedFileURL
        self.target = target
        self.graft = graft
    }

    func list(_ url: URL) throws -> [EntryMeta] {
        var entries = try wrapped.list(resolving(url))
        guard url.standardizedFileURL == root else { return entries }
        guard var second = entries.first(where: { $0.name == target }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        second.name = graft
        entries.append(second)
        return entries
    }

    func metadata(of url: URL) throws -> EntryMeta { try wrapped.metadata(of: resolving(url)) }
    func volumeInfo(for url: URL) throws -> VolumeInfo { try wrapped.volumeInfo(for: resolving(url)) }
    func mountPointPaths() -> Set<String> { wrapped.mountPointPaths() }

    /// `<root>/<graft>/…` is `<root>/<target>/…`, at every depth.
    private func resolving(_ url: URL) -> URL {
        let components = url.standardizedFileURL.pathComponents
        let base = root.pathComponents
        guard components.count > base.count,
              Array(components.prefix(base.count)) == base,
              components[base.count] == graft
        else { return url }

        var resolved = root.appendingPathComponent(target, isDirectory: true)
        for component in components.dropFirst(base.count + 1) {
            resolved.appendPathComponent(component)
        }
        return resolved
    }
}
