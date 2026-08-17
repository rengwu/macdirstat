import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Directory re-entry (spec §3.3, §3.4): the same directory reached at two
/// paths on one volume must contribute its bytes **once**.
///
/// The case that exists on every Mac is the APFS firmlink graft: `/` and
/// `/System/Volumes/Data` report the same volume identifier, so the device
/// check sees no boundary, and `/System/Volumes/Data/Users` is the very inode
/// already walked as `/Users`. The hard-link index cannot catch it — those
/// entries have a link count of 1, and they are directories rather than files.
///
/// Everything here is scripted, because a firmlink is the OS's to create and no
/// test may make one. What a real disk *can* prove — that macOS really does
/// hand out one identity for a directory reached two ways — is
/// `ScanCoreFileSystemTests`' subject.
final class RepeatedDirectoryTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")
    private let volumeB = FileSystemIdentity("volume-B")
    /// The one directory the grafted fixtures below reach by two names.
    private let sharedDirectory = FileSystemIdentity("inode-shared-directory")

    /// The shape of the bug, in miniature: `a-real` and `z-graft` are one
    /// directory under two names, exactly as `/Users` and
    /// `/System/Volumes/Data/Users` are.
    private func graftedTree(
        realName: String = "a-real",
        graftName: String = "z-graft"
    ) -> ScriptedEntry {
        let identity = sharedDirectory
        let children: [ScriptedEntry] = [
            .file("payload.bin", bytes: 100, volume: volumeA),
            .directory("nested", volume: volumeA, identity: FileSystemIdentity("inode-nested"), children: [
                .file("deep.bin", bytes: 20, volume: volumeA)
            ])
        ]
        return .directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory(realName, volume: volumeA, identity: identity, children: children),
            .directory(graftName, volume: volumeA, identity: identity, children: children)
        ])
    }

    // MARK: - Counted once

    func test_aDirectoryReachedAtTwoPathsIsCountedOnce() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: graftedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 120, "the grafted subtree's bytes are counted once")
        XCTAssertEqual(result.root.fileCount, 2, "and so are its files")
        XCTAssertEqual(
            probe.listedPaths, ["", "a-real", "a-real/nested"],
            "nothing beneath the second name is ever listed"
        )
        XCTAssertEqual(
            flatten(result.root),
            ["", "a-real", "a-real/nested", "a-real/nested/deep.bin", "a-real/payload.bin", "z-graft"],
            "one node per real directory, plus the second name itself"
        )
    }

    /// The second name stays visible and weightless — the rule the engine
    /// already applies to a second name for an inode (spec §3.4). Deleting it
    /// from the tree would be the dishonest answer: the directory really is
    /// there at that path.
    func test_theSecondNameStaysVisibleWeightlessAndNamesTheOwner() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: graftedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }
        guard let graft = node(result.root, at: "z-graft") else { return XCTFail("the second name vanished") }

        XCTAssertEqual(graft.subtreeDiskBytes, 0)
        XCTAssertEqual(graft.ownDiskBytes, 0)
        XCTAssertEqual(graft.fileCount, 0)
        XCTAssertTrue(graft.children.isEmpty)
        XCTAssertEqual(graft.attribution, .directoryCountedElsewhere(owner: ["scan-root", "a-real"]))
        XCTAssertTrue(graft.isFrozen)
    }

    /// Which name owns the bytes follows the traversal's own deterministic
    /// order — the first path to arrive, exactly as with a hard link. Naming
    /// the graft *first* moves the ownership with it.
    func test_theFirstPathInTraversalOrderOwnsTheBytes() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: graftedTree(realName: "z-second", graftName: "a-first")
        )

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 120)
        XCTAssertEqual(node(result.root, at: "a-first")?.subtreeDiskBytes, 120)
        XCTAssertEqual(
            node(result.root, at: "z-second")?.attribution,
            .directoryCountedElsewhere(owner: ["scan-root", "a-first"])
        )
        XCTAssertEqual(probe.listedPaths, ["", "a-first", "a-first/nested"])
    }

    // MARK: - Reporting: an exclusion, never an error

    func test_aRepeatedDirectoryIsAnExclusionAndLeavesTheTreeExact() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: graftedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.exclusions.byReason, [.repeatedDirectory: 1])
        XCTAssertTrue(result.errors.isEmpty, "nothing went wrong — a policy skipped it")
        XCTAssertEqual(result.completeness, .exact)
        XCTAssertEqual(result.root.readState, .complete, "ancestors stay Complete")
        XCTAssertEqual(node(result.root, at: "z-graft")?.readState, .complete)
    }

    func test_repeatedDirectoriesAreCountedApartFromOtherExclusions() async {
        let identity = FileSystemIdentity("inode-shared")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory("a-real", volume: volumeA, identity: identity, children: [
                .file("payload.bin", bytes: 8, volume: volumeA)
            ]),
            .directory("m-graft", volume: volumeA, identity: identity),
            .directory("n-graft", volume: volumeA, identity: identity),
            .directory("mounted", volume: volumeB, identity: FileSystemIdentity("inode-elsewhere")),
            .file("remote.bin", bytes: 1, volume: volumeA,
                  isUbiquitousItem: true, cloudStatus: .notDownloaded)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(
            result.exclusions.byReason,
            [.repeatedDirectory: 2, .crossedVolumeBoundary: 1, .remoteOnlyCloud: 1]
        )
        XCTAssertEqual(result.root.subtreeDiskBytes, 8)
    }

    // MARK: - The boundaries of the guard

    /// The rule `isOnRootVolume` already follows: an identity that could not be
    /// read is not evidence of anything, and omitting real bytes is the worse
    /// error. Two identity-less directories are both walked.
    func test_aDirectoryWhoseIdentityCannotBeReadIsAlwaysDescended() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory("one", volume: volumeA, children: [
                .file("a.bin", bytes: 30, volume: volumeA)
            ]),
            .directory("two", volume: volumeA, children: [
                .file("b.bin", bytes: 40, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 70, "an unknown identity descends — nothing is skipped")
        XCTAssertEqual(probe.listedPaths, ["", "one", "two"])
        XCTAssertTrue(result.exclusions.isEmpty)
    }

    /// Distinct directories with distinct identities — the ordinary case — are
    /// untouched by the guard.
    func test_distinctDirectoriesAreNeverSkipped() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory("one", volume: volumeA, identity: FileSystemIdentity("inode-1"), children: [
                .file("a.bin", bytes: 30, volume: volumeA)
            ]),
            .directory("two", volume: volumeA, identity: FileSystemIdentity("inode-2"), children: [
                .file("b.bin", bytes: 40, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 70)
        XCTAssertEqual(probe.listedPaths, ["", "one", "two"])
        XCTAssertTrue(result.exclusions.isEmpty)
    }

    /// The scan root is in the index from pre-flight, so a graft that points
    /// back at the root itself is caught rather than walked a second time.
    func test_aGraftBackToTheScanRootIsSkipped() async {
        let rootIdentity = FileSystemIdentity("inode-root")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: rootIdentity, children: [
            .file("payload.bin", bytes: 9, volume: volumeA),
            .directory("self-graft", volume: volumeA, identity: rootIdentity, children: [
                .file("payload.bin", bytes: 9, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 9)
        XCTAssertEqual(probe.listedPaths, [""])
        XCTAssertEqual(result.exclusions.byReason, [.repeatedDirectory: 1])
        XCTAssertEqual(
            node(result.root, at: "self-graft")?.attribution,
            .directoryCountedElsewhere(owner: ["scan-root"])
        )
    }

    /// A package is a directory the engine measures *through*, so a second name
    /// for one is the same case and gets the same answer.
    func test_aPackageReachedTwiceIsAlsoCountedOnce() async {
        let identity = FileSystemIdentity("inode-bundle")
        let contents: [ScriptedEntry] = [.file("Info.plist", bytes: 64, volume: volumeA)]
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory("A.app", volume: volumeA, identity: identity, isPackage: true, children: contents),
            .directory("Z.app", volume: volumeA, identity: identity, isPackage: true, children: contents)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 64)
        XCTAssertEqual(probe.listedPaths, ["", "A.app"])
        XCTAssertEqual(result.exclusions.byReason, [.repeatedDirectory: 1])
    }

    /// A directory on *another* volume that happens to report the same inode
    /// number is not the same directory. The device check runs first, so it is
    /// a boundary exclusion and never enters the index — nothing on the root
    /// volume can be skipped because a foreign volume reused an inode number.
    func test_aForeignVolumesIdentityNeverPoisonsTheIndex() async {
        let identity = FileSystemIdentity("inode-collision")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory("a-mounted", volume: volumeB, identity: identity, children: [
                .file("theirs.bin", bytes: 5_000, volume: volumeB)
            ]),
            .directory("z-ours", volume: volumeA, identity: identity, children: [
                .file("ours.bin", bytes: 70, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 70, "our own directory is still walked")
        XCTAssertEqual(probe.listedPaths, ["", "z-ours"])
        XCTAssertEqual(result.exclusions.byReason, [.crossedVolumeBoundary: 1])
    }

    // MARK: - A filesystem mounted inside the root's own volume

    /// `/` in miniature, with the numbers macOS actually reports (measured on
    /// this machine, 2026-08-17): the data volume's root carries the **same**
    /// file identity and the **same** volume identifier as `/`, while holding
    /// both the firmlinked names already reachable from `/` and entries that
    /// exist nowhere else (`.Spotlight-V100`, `.fseventsd`, `mnt`, `sw`).
    ///
    /// `System` sorts before `Users`, so arrival order alone would give the
    /// user's data to `/System/Volumes/Data/Users` and leave `/Users` an empty
    /// shell. Holding mount points back to the end of the walk is what puts the
    /// bytes under the path a person recognises.
    private func firmlinkedVolumeTree() -> ScriptedEntry {
        let usersIdentity = FileSystemIdentity("inode-users")
        let users: [ScriptedEntry] = [.file("big.bin", bytes: 1_000, volume: volumeA)]
        return .directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-2"), children: [
            .directory("System", volume: volumeA, identity: FileSystemIdentity("inode-system"), children: [
                .directory("Volumes", volume: volumeA, identity: FileSystemIdentity("inode-volumes"), children: [
                    // The data volume's root: same identity as the scan root.
                    .directory("Data", volume: volumeA, identity: FileSystemIdentity("inode-2"), children: [
                        .directory("Users", volume: volumeA, identity: usersIdentity, children: users),
                        .directory(".Spotlight-V100", volume: volumeA,
                                   identity: FileSystemIdentity("inode-spotlight"), children: [
                            .file("index.bin", bytes: 77, volume: volumeA)
                        ])
                    ])
                ])
            ]),
            .directory("Users", volume: volumeA, identity: usersIdentity, children: users)
        ])
    }

    private var dataVolumeMountPoint: Set<String> { [scanRootURL.path + "/System/Volumes/Data"] }

    func test_aMountPointInsideTheRootsOwnVolumeIsWalkedLastSoTheFamiliarPathOwnsTheBytes() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: firmlinkedVolumeTree(),
            mountPoints: dataVolumeMountPoint
        )

        guard let result = await runScan(probe, mode: .volumeRoot).result else {
            return XCTFail("expected a result")
        }

        XCTAssertEqual(result.root.subtreeDiskBytes, 1_077, "1,000 counted once, plus the 77 only the second root has")
        XCTAssertEqual(node(result.root, at: "Users")?.subtreeDiskBytes, 1_000,
                       "the path a person recognises owns the bytes")
        XCTAssertEqual(
            node(result.root, at: "System/Volumes/Data/Users")?.attribution,
            .directoryCountedElsewhere(owner: ["scan-root", "Users"])
        )
        XCTAssertEqual(
            probe.listedPaths.last, "System/Volumes/Data/.Spotlight-V100",
            "the mount point is walked after the ordinary tree: \(probe.listedPaths)"
        )
        XCTAssertEqual(result.exclusions.byReason, [.repeatedDirectory: 1])
        XCTAssertEqual(result.completeness, .exact)
    }

    /// The half of the rule that keeps the fix from becoming an under-count:
    /// two volume roots may share an inode number — `/` and
    /// `/System/Volumes/Data` both report inode 2 — so a mount point is never
    /// offered to the identity index. Skipping it would lose everything only it
    /// can reach.
    func test_aMountPointIsWalkedEvenWhenItsIdentityIsTheScanRootsOwn() async {
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: firmlinkedVolumeTree(),
            mountPoints: dataVolumeMountPoint
        )

        guard let result = await runScan(probe, mode: .volumeRoot).result else {
            return XCTFail("expected a result")
        }

        XCTAssertEqual(node(result.root, at: "System/Volumes/Data/.Spotlight-V100")?.subtreeDiskBytes, 77,
                       "an entry that exists only under the second root is still counted")
        XCTAssertTrue(probe.listedPaths.contains("System/Volumes/Data"))
    }

    /// What the identity guard does **alone**, with no mount table to tell it
    /// that the second root is a different directory: it takes the two roots
    /// for one, skips the whole second root, and the 77 bytes that live only
    /// there are lost.
    ///
    /// Nothing is ever counted twice — that is the guarantee, and it holds with
    /// or without the hint. But this is the reason the hint exists, and the
    /// reason a mount point is never offered to the index: on a real Mac this
    /// is `.Spotlight-V100`, `.DocumentRevisions-V100` and `.fseventsd`
    /// disappearing from a scan of `/`.
    func test_withoutTheMountTableTheSecondVolumeRootIsSkippedWholesale() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: firmlinkedVolumeTree())

        guard let result = await runScan(probe, mode: .volumeRoot).result else {
            return XCTFail("expected a result")
        }

        XCTAssertEqual(result.root.subtreeDiskBytes, 1_000, "nothing is double counted…")
        XCTAssertNil(node(result.root, at: "System/Volumes/Data/.Spotlight-V100"),
                     "…but what only the second root could reach is not counted at all")
        XCTAssertEqual(
            node(result.root, at: "System/Volumes/Data")?.attribution,
            .directoryCountedElsewhere(owner: ["scan-root"]),
            "the two volume roots share an inode number, so identity alone says they are one directory"
        )
        XCTAssertEqual(result.exclusions.byReason, [.repeatedDirectory: 1])
    }

    /// A mount point held back and never reached is exactly as Incomplete as an
    /// open directory: its total is a floor, and it must say so (spec §5.6).
    func test_aDeferredMountPointIsIncompleteWhenTheScanIsCancelledFirst() async {
        let scanner = Scanner()
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: firmlinkedVolumeTree(),
            beforeRequest: { request in
                if request.kind == .list && request.path == "Users" { scanner.cancel() }
            },
            mountPoints: dataVolumeMountPoint
        )

        let stream = await scanner.scan(makeRequest(probe: probe, mode: .volumeRoot))
        guard let result = await collectEvents(stream).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertFalse(probe.listedPaths.contains("System/Volumes/Data"),
                       "the deferred mount point was never reached: \(probe.listedPaths)")
        XCTAssertEqual(node(result.root, at: "System/Volumes/Data")?.readState, .incomplete,
                       "an unvisited deferred mount point is not Complete")
    }

    // MARK: - Hidden aliases of the whole filesystem

    /// `/.nofollow` in miniature. macOS hangs synthetic aliases of the whole
    /// volume off the root — `/.nofollow`, `/.vol`, `/.resolve` — and a scan of
    /// `/` really does reach every directory twice through them (measured on
    /// this machine, 2026-08-17: the first run of this fix attributed **all**
    /// 1.78 TB to `/.nofollow`, because a dot sorts before every letter).
    ///
    /// They are not mount points and their own identity is synthetic, so the
    /// only thing that separates them from the paths a person recognises is
    /// that they are hidden — which is why hidden subdirectories are opened
    /// after their visible siblings.
    func test_aHiddenAliasOfTheTreeCannotTakeTheBytesFromTheVisibleNames() async {
        let usersIdentity = FileSystemIdentity("inode-users")
        let users: [ScriptedEntry] = [.file("big.bin", bytes: 900, volume: volumeA)]
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory(".nofollow", volume: volumeA, identity: FileSystemIdentity("inode-synthetic"), children: [
                .directory("Users", volume: volumeA, identity: usersIdentity, children: users)
            ]),
            .directory("Users", volume: volumeA, identity: usersIdentity, children: users)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 900)
        XCTAssertEqual(node(result.root, at: "Users")?.subtreeDiskBytes, 900,
                       "the visible name keeps the bytes")
        XCTAssertEqual(
            node(result.root, at: ".nofollow/Users")?.attribution,
            .directoryCountedElsewhere(owner: ["scan-root", "Users"])
        )
        XCTAssertEqual(probe.listedPaths, ["", "Users", ".nofollow"],
                       "the hidden alias is opened after every visible sibling")
    }

    /// The rule is an *order*, not an exclusion: a hidden directory with
    /// contents of its own is walked in full, and the tree keeps its listing
    /// order regardless of when each child was opened.
    func test_aHiddenDirectoryIsStillWalkedInFullAndKeepsItsPlaceInTheTree() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("inode-root"), children: [
            .directory(".cache", volume: volumeA, identity: FileSystemIdentity("inode-cache"), children: [
                .file("blob.bin", bytes: 40, volume: volumeA)
            ]),
            .directory("visible", volume: volumeA, identity: FileSystemIdentity("inode-visible"), children: [
                .file("doc.bin", bytes: 2, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 42)
        XCTAssertEqual(node(result.root, at: ".cache")?.subtreeDiskBytes, 40)
        XCTAssertTrue(result.exclusions.isEmpty)
        XCTAssertEqual(probe.listedPaths, ["", "visible", ".cache"], "walked last…")
        XCTAssertEqual(
            flatten(result.root),
            ["", ".cache", ".cache/blob.bin", "visible", "visible/doc.bin"],
            "…and listed first, exactly where the listing put it"
        )
    }

    // MARK: - The positive control

    /// Proof that the fixtures above are not vacuous. With the guard switched
    /// off, the very same scripted tree doubles — every byte, every file, and
    /// the whole subtree of nodes — which is precisely the field report this
    /// ticket came from.
    func test_withoutTheGuardTheSameTreeDoubles() async {
        var options = ScanOptions(progressCadence: .everyChange, treeCadence: .everyChange)
        options.deduplicatesRepeatedDirectories = false
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: graftedTree())

        guard let result = await runScan(probe, options: options).result else {
            return XCTFail("expected a result")
        }

        XCTAssertEqual(result.root.subtreeDiskBytes, 240, "the guard is what makes the total 120")
        XCTAssertEqual(result.root.fileCount, 4)
        XCTAssertEqual(probe.listedPaths, ["", "a-real", "a-real/nested", "z-graft", "z-graft/nested"])
        XCTAssertTrue(result.exclusions.isEmpty)
    }
}
