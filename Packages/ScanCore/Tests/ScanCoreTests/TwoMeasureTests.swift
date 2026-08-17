import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// What the engine measures, since ticket 13: **blocks on disk**, with content
/// length carried beside them and rolled up the same way.
///
/// Every fixture here is a tree where the two measures disagree, because on a
/// tree where they agree nothing in this file could fail. The disagreements are
/// the real ones the field machine found: a sparse image that is a terabyte of
/// length on nothing at all, a system binary that is longer than it occupies, a
/// cloud placeholder that is not on the disk in any sense.
final class TwoMeasureTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    // MARK: - Both measures, rolled up

    func test_blocksDriveTheTotalAndContentLengthIsCarriedBesideIt() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            // A sparse disk image: 1 TiB of content, 34.6 GiB of blocks.
            .file("Docker.raw", bytes: 34_600, contentLength: 1_048_576, volume: volumeA),
            .directory("bin", volume: volumeA, children: [
                // A compressed system binary — the error running the other way.
                .file("ls", bytes: 41, contentLength: 154, volume: volumeA)
            ]),
            // An ordinary file, where the two agree.
            .file("plain.bin", bytes: 4_096, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 34_600 + 41 + 4_096)
        XCTAssertEqual(result.root.subtreeContentBytes, 1_048_576 + 154 + 4_096)

        // Both reachable from any node without walking its subtree.
        let image = node(result.root, at: "Docker.raw")
        XCTAssertEqual(image?.ownDiskBytes, 34_600)
        XCTAssertEqual(image?.ownContentBytes, 1_048_576)

        // The roll-up reaches every folder on the chain, in both measures.
        let bin = node(result.root, at: "bin")
        XCTAssertEqual(bin?.subtreeDiskBytes, 41)
        XCTAssertEqual(bin?.subtreeContentBytes, 154)
        XCTAssertEqual(bin?.ownDiskBytes, 0, "a folder occupies no blocks of its own")
        XCTAssertEqual(bin?.ownContentBytes, 0)
    }

    func test_aDirectoryTotalIsTheSumOfItsLeavesInBothMeasures() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("a", volume: volumeA, children: [
                .file("one.bin", bytes: 8_192, contentLength: 5, volume: volumeA),
                .directory("b", volume: volumeA, children: [
                    .file("two.bin", bytes: 0, contentLength: 3_221_225_472, volume: volumeA)
                ])
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(foldOwnDiskBytes(result.root), result.root.subtreeDiskBytes)
        XCTAssertEqual(foldOwnContentBytes(result.root), result.root.subtreeContentBytes)
        XCTAssertEqual(result.root.subtreeDiskBytes, 8_192)
        XCTAssertEqual(result.root.subtreeContentBytes, 5 + 3_221_225_472)
    }

    // MARK: - The on-disk figure decides readability (ticket 13)

    func test_anEntryWhoseBlocksCannotBeReadIsUnreadableAndKeepsNoLength() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("fine.bin", bytes: 4_096, volume: volumeA),
            // Its length reads perfectly well. It is still Unreadable, and the
            // length is never substituted: the two are different quantities and
            // only one of them is the measure.
            .file("blocks-unknown.bin", bytes: nil, contentLength: 9_999, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        let unreadable = node(result.root, at: "blocks-unknown.bin")
        XCTAssertEqual(unreadable?.readState, .unreadable)
        XCTAssertEqual(unreadable?.ownDiskBytes, 0)
        XCTAssertEqual(unreadable?.ownContentBytes, 0, "the readable length is not a consolation prize")
        XCTAssertEqual(result.root.subtreeDiskBytes, 4_096)
        XCTAssertEqual(result.root.subtreeContentBytes, 4_096, "no unread entry leaks into the other measure")
        XCTAssertEqual(result.errors.byCategory, [.unreadableEntry: 1])
        XCTAssertEqual(result.root.fileCount, 2, "it is still one item, and still listed")
    }

    /// Ticket 04's judgment call, now keyed on blocks: an entry of unknown size
    /// must never own an inode, because owning it would zero out a later name
    /// that *could* be read.
    func test_anEntryWithUnreadableBlocksNeverEntersTheIdentityIndex() async {
        let inode = FileSystemIdentity("inode-1")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("a-unknown.bin", bytes: nil, contentLength: 512,
                  volume: volumeA, linkCount: 2, identity: inode),
            .file("z-readable.bin", bytes: 4_096, contentLength: 512,
                  volume: volumeA, linkCount: 2, identity: inode)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        let readable = node(result.root, at: "z-readable.bin")
        XCTAssertEqual(readable?.attribution, .owned,
                       "the unreadable name claimed the inode and zeroed a name that could be read")
        XCTAssertEqual(readable?.ownDiskBytes, 4_096)
        XCTAssertEqual(readable?.ownContentBytes, 512)
        XCTAssertEqual(result.root.subtreeDiskBytes, 4_096)
    }

    // MARK: - Length without blocks: visible, and weightless

    /// The third-party cloud provider whose materialization state macOS cannot
    /// read. §3.4 counts "the present logical file" and the rule is unchanged —
    /// but the measure fixes the case on its own, because a placeholder occupies
    /// no blocks. Ten of these were 10.22 GiB each on the field machine.
    func test_aPlaceholderThatIsAllLengthAndNoBlocksCountsZeroAndStaysVisible() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("real.mov", bytes: 1_048_576, volume: volumeA),
            .file("placeholder.mov", bytes: 0, contentLength: 10_977_524_224,
                  volume: volumeA, isUbiquitousItem: true, cloudStatus: nil)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        let placeholder = node(result.root, at: "placeholder.mov")
        XCTAssertNotNil(placeholder, "it stays visible — it is a name the user has")
        XCTAssertEqual(placeholder?.ownDiskBytes, 0)
        XCTAssertEqual(placeholder?.ownContentBytes, 10_977_524_224,
                       "the inspector still has something to explain the empty rectangle with")
        XCTAssertEqual(placeholder?.readState, .complete, "nothing went wrong: it is simply not here")
        XCTAssertEqual(result.root.subtreeDiskBytes, 1_048_576)
        XCTAssertEqual(result.completeness, .exact)
        XCTAssertTrue(result.errors.isEmpty)

        // Weightless means no rectangle, which means nothing is hidden by
        // folding it into an aggregate.
        XCTAssertEqual(result.root.attributedNodeCount, 2, "root and one attributed file, and no third")
    }

    /// A sparse file is the same shape without the cloud: length that no scan
    /// can find on the disk, because it is not on the disk.
    func test_aSparseFileIsCountedAtItsBlocksAndNotAtItsLength() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file(".hidden.bin", bytes: 0, contentLength: 3_221_225_472, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.subtreeDiskBytes, 0)
        XCTAssertEqual(result.root.subtreeContentBytes, 3_221_225_472)
        XCTAssertEqual(node(result.root, at: ".hidden.bin")?.readState, .complete)
        XCTAssertEqual(result.root.attributedNodeCount, 0, "nothing here has a rectangle to lose")
    }

    // MARK: - Deduplication gives up both measures

    func test_aSecondNameForAnInodeGivesUpBlocksAndLengthAlike() async {
        let inode = FileSystemIdentity("inode-1")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("a-owner.bin", bytes: 4_096, contentLength: 5,
                  volume: volumeA, linkCount: 2, identity: inode),
            .file("z-duplicate.bin", bytes: 4_096, contentLength: 5,
                  volume: volumeA, linkCount: 2, identity: inode)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        let duplicate = node(result.root, at: "z-duplicate.bin")
        XCTAssertEqual(duplicate?.ownDiskBytes, 0)
        XCTAssertEqual(duplicate?.ownContentBytes, 0,
                       "two names share one set of blocks and one set of contents")
        XCTAssertEqual(result.root.subtreeDiskBytes, 4_096)
        XCTAssertEqual(result.root.subtreeContentBytes, 5)
        XCTAssertEqual(result.root.fileCount, 2, "a deduplicated name is still one item")
    }

    // MARK: - The other measure survives a snapshot

    func test_bothMeasuresSurviveTheFrozenSnapshot() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("deep", volume: volumeA, children: [
                .file("sparse.img", bytes: 8_192, contentLength: 1_073_741_824, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        let events = await runScan(probe)
        guard let snapshot = events.treeSnapshots.last else { return XCTFail("expected a tree snapshot") }

        XCTAssertEqual(snapshot.root.subtreeDiskBytes, 8_192)
        XCTAssertEqual(snapshot.root.subtreeContentBytes, 1_073_741_824)
        XCTAssertEqual(node(snapshot.root, at: "deep")?.subtreeContentBytes, 1_073_741_824)
    }
}
