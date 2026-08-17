import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Filesystem-identity semantics (spec §3.4): hard links deduplicated by
/// identity so the same inode's bytes are counted once, APFS clones counted
/// separately because their identities genuinely differ, and packages measured
/// through while presenting as one collapsed item.
final class IdentityTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")
    private let inode7 = FileSystemIdentity("inode-7")
    private let inode8 = FileSystemIdentity("inode-8")

    // MARK: - Hard links

    /// The probe hands entries back reversed on purpose, so the owner is
    /// decided by the engine's own sort and nothing else.
    func test_theFirstPathInDeterministicOrderOwnsTheBytes() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("zeta.bin", bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode7),
            .file("alpha.bin", bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode7)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 4_096, "one inode's bytes are counted once")

        let owner = node(result.root, at: "alpha.bin")
        XCTAssertEqual(owner?.ownDiskBytes, 4_096)
        XCTAssertEqual(owner?.attribution, .owned)

        let duplicate = node(result.root, at: "zeta.bin")
        XCTAssertEqual(duplicate?.ownDiskBytes, 0, "the later path is visible with zero attributed bytes")
        XCTAssertEqual(duplicate?.attribution, .hardLinkElsewhere(owner: ["scan-root", "alpha.bin"]))
        XCTAssertEqual(duplicate?.readState, .complete, "a counted-elsewhere link is not an error")

        XCTAssertEqual(result.root.fileCount, 2, "both names are still entries in the tree")
        XCTAssertEqual(result.completeness, .exact)
    }

    /// Depth-first order across directories: `a` is walked to exhaustion before
    /// `b` is opened, so `a`'s name owns the inode.
    func test_ownershipFollowsDepthFirstOrderAcrossDirectories() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("b", volume: volumeA, children: [
                .file("link.bin", bytes: 900, volume: volumeA, linkCount: 2, identity: inode7)
            ]),
            .directory("a", volume: volumeA, children: [
                .file("link.bin", bytes: 900, volume: volumeA, linkCount: 2, identity: inode7)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 900)
        XCTAssertEqual(node(result.root, at: "a/link.bin")?.ownDiskBytes, 900)
        XCTAssertEqual(node(result.root, at: "a")?.subtreeDiskBytes, 900)
        XCTAssertEqual(node(result.root, at: "b/link.bin")?.ownDiskBytes, 0)
        XCTAssertEqual(node(result.root, at: "b")?.subtreeDiskBytes, 0,
                       "the duplicate rolls nothing up — the bytes are already counted under a/")
        XCTAssertEqual(node(result.root, at: "b/link.bin")?.attribution,
                       .hardLinkElsewhere(owner: ["scan-root", "a", "link.bin"]))
    }

    /// §9.3: identical runs produce identical node order *and* an identical
    /// hard-link owner. This is the reason the within-directory sort is
    /// locale-independent (ticket 03).
    func test_repeatedRunsAgreeOnNodeOrderAndOnTheOwner() async {
        func run() async -> (owner: String?, duplicates: [String], order: [String], total: Int64) {
            let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
                .file("Zebra.bin", bytes: 12, volume: volumeA, linkCount: 3, identity: inode7),
                .file("apple.bin", bytes: 12, volume: volumeA, linkCount: 3, identity: inode7),
                .file("Éclair.bin", bytes: 12, volume: volumeA, linkCount: 3, identity: inode7)
            ])
            let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)
            guard let result = await runScan(probe).result else { return (nil, [], [], -1) }
            return (
                owner: result.root.children.first { $0.attribution == .owned }?.name,
                duplicates: result.root.children.filter { $0.attribution != .owned }.map(\.name),
                order: flatten(result.root),
                total: result.root.subtreeDiskBytes
            )
        }

        let first = await run()
        let second = await run()

        XCTAssertEqual(first.order, second.order)
        XCTAssertEqual(first.order, ["", "Zebra.bin", "apple.bin", "Éclair.bin"],
                       "Unicode code-point order, the spec's treemap tie-break (§6.1)")
        XCTAssertEqual(first.owner, "Zebra.bin")
        XCTAssertEqual(first.owner, second.owner)
        XCTAssertEqual(first.duplicates, ["apple.bin", "Éclair.bin"])
        XCTAssertEqual(first.duplicates, second.duplicates)
        XCTAssertEqual(first.total, 12, "three names, one inode, counted once")
        XCTAssertEqual(first.total, second.total)
    }

    /// The scanner never goes looking for the inode's other names, so a link
    /// whose sibling lives outside the root simply owns its bytes.
    func test_aNameOutsideTheRootIsNeitherSoughtNorShown() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("inside.bin", bytes: 2_048, volume: volumeA, linkCount: 2, identity: inode7)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 2_048, "the only in-scope name owns the bytes")
        XCTAssertEqual(node(result.root, at: "inside.bin")?.attribution, .owned)
        XCTAssertEqual(result.root.children.map(\.name), ["inside.bin"], "no name from outside appears")
        XCTAssertEqual(probe.listedPaths, [""], "nothing was searched for the inode's other names")
    }

    // MARK: - Clones

    func test_distinctCloneIdentitiesEachContributeTheirLogicalLength() async {
        // An APFS clone shares blocks but has its own inode, so the identity
        // index never collides and each contributes its full logical length.
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("original.bin", bytes: 5_000, volume: volumeA, linkCount: 1, identity: inode7),
            .file("clone.bin", bytes: 5_000, volume: volumeA, linkCount: 1, identity: inode8)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 10_000, "clones are not deduplicated (spec §3.4)")
        XCTAssertEqual(node(result.root, at: "original.bin")?.attribution, .owned)
        XCTAssertEqual(node(result.root, at: "clone.bin")?.attribution, .owned)
    }

    // MARK: - When the index is consulted

    func test_aLinkCountOfOneBypassesTheIndexEvenWhenIdentitiesCollide() async {
        // Only a scripted filesystem can stage this: two entries reporting the
        // same identity at link count 1. If the index were consulted for them,
        // the second would be deduplicated — it must not be.
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("a.bin", bytes: 64, volume: volumeA, linkCount: 1, identity: inode7),
            .file("b.bin", bytes: 64, volume: volumeA, linkCount: 1, identity: inode7),
            .file("c.bin", bytes: 64, volume: volumeA, linkCount: nil, identity: inode7)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 192)
        for name in ["a.bin", "b.bin", "c.bin"] {
            XCTAssertEqual(node(result.root, at: name)?.attribution, .owned, "\(name) was deduplicated")
        }
    }

    func test_aVolumeWithoutHardLinkSupportBypassesTheIndexEntirely() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("a.bin", bytes: 64, volume: volumeA, linkCount: 2, identity: inode7),
            .file("b.bin", bytes: 64, volume: volumeA, linkCount: 2, identity: inode7)
        ])
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: tree,
            volumeInfo: VolumeInfo(isLocal: true, supportsHardLinks: false)
        )

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 128, "no dedup is possible where no hard link can exist")
        XCTAssertEqual(node(result.root, at: "b.bin")?.attribution, .owned)
    }

    /// The index itself, directly: the memory claim is that it holds only
    /// multiply-linked inodes, which no end-to-end assertion can show.
    func test_theIndexHoldsOnlyMultiplyLinkedEntries() {
        var index = HardLinkIndex(isEnabled: true)
        let node = ScanNode(name: "n", kind: .file, parent: nil)

        XCTAssertEqual(index.claim(EntryMeta(name: "single", linkCount: 1, fileIdentity: inode7), for: node), .notALink)
        XCTAssertEqual(index.claim(EntryMeta(name: "unknown", linkCount: nil, fileIdentity: inode7), for: node), .notALink)
        XCTAssertEqual(index.claim(EntryMeta(name: "no-identity", linkCount: 4, fileIdentity: nil), for: node), .notALink)
        XCTAssertEqual(index.count, 0, "nothing that cannot be a hard link may enter the index")

        XCTAssertEqual(index.claim(EntryMeta(name: "linked", linkCount: 2, fileIdentity: inode7), for: node), .owner)
        XCTAssertEqual(index.count, 1)

        let second = ScanNode(name: "second", kind: .file, parent: nil)
        guard case .duplicate(let owner) = index.claim(
            EntryMeta(name: "linked-again", linkCount: 2, fileIdentity: inode7), for: second
        ) else { return XCTFail("expected the second name to find the owner") }
        XCTAssertTrue(owner === node)
        XCTAssertEqual(index.count, 1, "a hit inserts nothing")
    }

    func test_aDisabledIndexNeverInsertsAnything() {
        var index = HardLinkIndex(isEnabled: false)
        let node = ScanNode(name: "n", kind: .file, parent: nil)

        XCTAssertEqual(index.claim(EntryMeta(name: "linked", linkCount: 2, fileIdentity: inode7), for: node), .notALink)
        XCTAssertEqual(index.claim(EntryMeta(name: "linked", linkCount: 2, fileIdentity: inode7), for: node), .notALink)
        XCTAssertEqual(index.count, 0)
    }

    // MARK: - Packages

    func test_aPackageIsMeasuredThroughButPresentsAsOneItem() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("loose.bin", bytes: 1_000, volume: volumeA),
            .directory("Media.app", volume: volumeA, isPackage: true, children: [
                .file("binary", bytes: 300, volume: volumeA),
                .directory("Contents", volume: volumeA, children: [
                    .file("Info.plist", bytes: 200, volume: volumeA),
                    .directory("Resources", volume: volumeA, children: [
                        .file("art.png", bytes: 24, volume: volumeA)
                    ])
                ])
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        guard let package = node(result.root, at: "Media.app") else { return XCTFail("expected the package") }
        XCTAssertEqual(package.kind, .package)
        XCTAssertEqual(package.subtreeDiskBytes, 524, "the aggregate is exact because the scan measured through")
        XCTAssertEqual(package.fileCount, 3)
        XCTAssertEqual(result.root.subtreeDiskBytes, 1_524)

        // Measured through, presented as one: the real children are in the
        // tree, and a view drawing `initiallyPresentedChildren` draws one box.
        XCTAssertFalse(package.children.isEmpty)
        XCTAssertEqual(package.initiallyPresentedChildren.count, 0)
        XCTAssertEqual(result.root.initiallyPresentedChildren.map(\.name), ["Media.app", "loose.bin"])

        // Expanding it later cannot change the aggregate: the children already
        // sum to it.
        XCTAssertEqual(package.children.reduce(0) { $0 + $1.subtreeDiskBytes }, package.subtreeDiskBytes)
        XCTAssertEqual(foldOwnDiskBytes(package), package.subtreeDiskBytes)
    }

    func test_aPackageNestedInsideAPackageIsStillMeasuredThrough() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("Outer.app", volume: volumeA, isPackage: true, children: [
                .directory("Helper.app", volume: volumeA, isPackage: true, children: [
                    .file("helper", bytes: 70, volume: volumeA)
                ]),
                .file("outer", bytes: 30, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(node(result.root, at: "Outer.app")?.subtreeDiskBytes, 100)
        XCTAssertEqual(node(result.root, at: "Outer.app/Helper.app")?.subtreeDiskBytes, 70)
        XCTAssertEqual(probe.listedPaths, ["", "Outer.app", "Outer.app/Helper.app"])
    }
}
