import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Entry-type semantics from spec §3.4: hidden entries are included, symlinks
/// are visible, weightless and never followed. Hard links, clones, packages and
/// cloud placeholders live in `IdentityTests` and `ExclusionTests`.
final class EntrySemanticsTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    func test_hiddenFilesAndDirectoriesAreIncludedAndRollUp() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file(".hidden-large.bin", bytes: 2 << 30, volume: volumeA),
            .directory(".config", volume: volumeA, children: [
                .file("settings", bytes: 40, volume: volumeA)
            ]),
            .file("visible.bin", bytes: 10, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeBytes, (2 << 30) + 50)
        XCTAssertEqual(node(result.root, at: ".hidden-large.bin")?.ownBytes, 2 << 30)
        XCTAssertEqual(node(result.root, at: ".config/settings")?.ownBytes, 40)
        XCTAssertEqual(result.root.fileCount, 3)
    }

    func test_symbolicLinksAreVisibleZeroByteLeavesAndAreNeverFollowed() async {
        // The link reports `isDirectory` and a 2 GiB `fileSize`, exactly as a
        // link to a large directory-backed target would. Neither may tempt the
        // walk: no bytes, no descent.
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("real.bin", bytes: 1_000, volume: volumeA),
            .symlink("link-to-file", volume: volumeA),
            .symlink("link-to-dir", looksLikeDirectory: true, volume: volumeA, children: [
                .file("must-never-be-seen.bin", bytes: 999_999, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeBytes, 1_000, "a symlink contributes no content bytes")
        for name in ["link-to-file", "link-to-dir"] {
            let link = node(result.root, at: name)
            XCTAssertEqual(link?.kind, .symbolicLink)
            XCTAssertEqual(link?.ownBytes, 0)
            XCTAssertEqual(link?.subtreeBytes, 0)
            XCTAssertTrue(link?.children.isEmpty == true)
        }
        XCTAssertEqual(probe.listedPaths, [""], "no link is ever listed: \(probe.listedPaths)")
        XCTAssertEqual(result.completeness, .exact, "an unfollowed link is normal, not an error")
    }

    /// The loop and the broken link — the two cases that would hang or throw a
    /// follower. Real fixtures arrive with the production probe in ticket 05;
    /// scripted here so the rule is proven now.
    func test_symbolicLinkLoopAndBrokenLinkTerminateTheWalk() async {
        // "loop" is a link whose scripted children lead back to a sibling
        // directory; "broken" is a link with no readable target at all.
        var loopChildren: [ScriptedEntry] = []
        loopChildren.append(.symlink("back-to-root", looksLikeDirectory: true, volume: volumeA))
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("dir", volume: volumeA, children: [
                .symlink("loop", looksLikeDirectory: true, volume: volumeA, children: loopChildren),
                .file("payload.bin", bytes: 64, volume: volumeA)
            ]),
            ScriptedEntry(meta: EntryMeta(
                name: "broken",
                isSymbolicLink: true,
                fileSize: nil,
                volumeIdentifier: volumeA
            ))
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.root.subtreeBytes, 64)
        XCTAssertEqual(probe.listedPaths, ["", "dir"])
        XCTAssertEqual(node(result.root, at: "broken")?.kind, .symbolicLink)
        XCTAssertEqual(node(result.root, at: "broken")?.ownBytes, 0)
        XCTAssertEqual(result.completeness, .exact,
                       "an unreadable size on a link is not an unreadable entry — links have no bytes to read")
    }

    func test_aNodeRebuildsItsAbsoluteURLFromTheParentChain() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("a", volume: volumeA, children: [
                .directory("b", volume: volumeA, children: [
                    .file("c.bin", bytes: 1, volume: volumeA)
                ])
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        let leaf = node(result.root, at: "a/b/c.bin")
        XCTAssertEqual(leaf?.pathComponents(), ["scan-root", "a", "b", "c.bin"])
        XCTAssertEqual(leaf?.url(root: scanRootURL).path, "/scan-root/a/b/c.bin")
    }
}
