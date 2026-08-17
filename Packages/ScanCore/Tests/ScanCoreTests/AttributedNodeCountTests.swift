import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// `ScanNode.attributedNodeCount` — the count a treemap aggregate reports
/// without walking what it folded (ticket 14).
///
/// The claim is narrow and exact: **the number of entries in a subtree that
/// carry attributed bytes**, maintained on the same ancestor walk as
/// `subtreeDiskBytes`, live at every instant. Every assertion here compares it
/// against a second, independent implementation — a plain recursive count over
/// the finished tree — because a roll-up that is wrong in the same way as its
/// oracle proves nothing.
final class AttributedNodeCountTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    /// A recursive count over the finished tree. Deliberately *not* the
    /// engine's incremental arithmetic: it asks each node the only question
    /// that matters — does this entry have a rectangle? — and adds them up.
    private func foldAttributedNodes(_ node: ScanNode) -> Int {
        var count = node.subtreeDiskBytes > 0 ? 1 : 0
        for child in node.children { count += foldAttributedNodes(child) }
        return count
    }

    private func assertCountsFold(_ root: ScanNode, file: StaticString = #filePath, line: UInt = #line) {
        var stack: [ScanNode] = [root]
        while let node = stack.popLast() {
            XCTAssertEqual(
                node.attributedNodeCount, foldAttributedNodes(node),
                "\(node.name) disagrees with an independent fold over its own subtree",
                file: file, line: line
            )
            stack.append(contentsOf: node.children)
        }
    }

    private func mixedTree() -> ScriptedEntry {
        .directory("scan-root", volume: volumeA, children: [
            .file("top.bin", bytes: 1_000, volume: volumeA),
            .directory("empty", volume: volumeA),
            .directory("docs", volume: volumeA, children: [
                .file("a.txt", bytes: 10, volume: volumeA),
                .file("b.txt", bytes: 20, volume: volumeA),
                .directory("nested", volume: volumeA, children: [
                    .file("deep.bin", bytes: 300, volume: volumeA)
                ])
            ]),
            .directory("media.app", volume: volumeA, isPackage: true, children: [
                .file("binary", bytes: 500, volume: volumeA),
                .directory("Resources", volume: volumeA, children: [
                    .file("art.png", bytes: 25, volume: volumeA)
                ])
            ])
        ])
    }

    func test_everyDirectoryCountsItsOwnAttributedDescendants() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: mixedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        // Hand-counted: root, top.bin, docs, a.txt, b.txt, nested, deep.bin,
        // media.app, binary, Resources, art.png — eleven. `empty` is not one of
        // them: it has no bytes, so it has no rectangle to lose.
        XCTAssertEqual(result.root.attributedNodeCount, 11)
        XCTAssertEqual(node(result.root, at: "docs")?.attributedNodeCount, 5)
        XCTAssertEqual(node(result.root, at: "docs/nested")?.attributedNodeCount, 2)
        XCTAssertEqual(node(result.root, at: "media.app")?.attributedNodeCount, 4)
        XCTAssertEqual(node(result.root, at: "empty")?.attributedNodeCount, 0)
        XCTAssertEqual(node(result.root, at: "top.bin")?.attributedNodeCount, 1)

        assertCountsFold(result.root)
    }

    /// The exclusion the count exists to make: an entry with no bytes has no
    /// rectangle, merged or not, so counting it would make *"N items below
    /// individual size"* mean something other than what it says (spec §6.2).
    func test_zeroAttributedEntriesAreNotCounted() async {
        let inode = FileSystemIdentity("inode-7")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("owner.bin", bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode),
            .file("second-name.bin", bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode),
            .file("zero.txt", bytes: 0, volume: volumeA),
            .symlink("link", volume: volumeA),
            .file("unreadable.bin", bytes: nil, volume: volumeA),
            .directory("all-empty", volume: volumeA, children: [
                .file("nothing.txt", bytes: 0, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        // Six entries below the root; exactly one of them owns bytes.
        XCTAssertEqual(result.root.children.count, 6)
        XCTAssertEqual(result.root.attributedNodeCount, 2, "the root and the one name that owns the inode")
        XCTAssertEqual(node(result.root, at: "second-name.bin")?.attributedNodeCount, 0)
        XCTAssertEqual(node(result.root, at: "zero.txt")?.attributedNodeCount, 0)
        XCTAssertEqual(node(result.root, at: "link")?.attributedNodeCount, 0)
        XCTAssertEqual(node(result.root, at: "unreadable.bin")?.attributedNodeCount, 0)
        XCTAssertEqual(node(result.root, at: "all-empty")?.attributedNodeCount, 0)

        assertCountsFold(result.root)
    }

    /// A directory becomes attributed the instant its subtree first carries
    /// bytes — and at that instant every ancestor gains it too. The chain is
    /// where an off-by-one would hide, because a directory has to be counted
    /// once by itself and once by each level above it.
    func test_aDeepChainCountsEveryDirectoryOnceAtEachLevel() async {
        var deepest = ScriptedEntry.directory("level-8", volume: volumeA, children: [
            .file("leaf.bin", bytes: 128, volume: volumeA)
        ])
        for level in stride(from: 7, through: 1, by: -1) {
            deepest = .directory("level-\(level)", volume: volumeA, children: [deepest])
        }
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .directory("scan-root", volume: volumeA, children: [deepest])
        )

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        // Root + eight directories + one file.
        XCTAssertEqual(result.root.attributedNodeCount, 10)
        XCTAssertEqual(node(result.root, at: "level-1")?.attributedNodeCount, 9)
        let deepestPath = (1...8).map { "level-\($0)" }.joined(separator: "/")
        XCTAssertEqual(node(result.root, at: deepestPath)?.attributedNodeCount, 2)
        assertCountsFold(result.root)
    }

    /// The count is what a treemap aggregate reports as "N items below
    /// individual size", so it has to fold exactly at every directory of the
    /// finished tree — not just at the root.
    func test_theCountFoldsExactlyAtEveryDirectory() async {
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: mixedTree())

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.attributedNodeCount, 11)
        assertCountsFold(result.root)
    }
}
