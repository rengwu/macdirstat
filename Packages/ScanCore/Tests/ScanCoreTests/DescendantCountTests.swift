import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// The three tallies of **names** the UI reads in O(1):
/// `ScanNode.presentedDescendantCount` (the tree's Items column),
/// `ScanNode.folderDescendantCount` (the inspector's "Contains" row) and
/// `ScanResult.visibleTotals` (the status line).
///
/// They are three different questions and this file keeps them apart. The tree
/// stops at a package because a package presents as one item; the inspector
/// walks through one because "Contains" asks what is inside; the status line
/// classifies a package as a file because that is the row the tree shows.
/// Collapsing any two of them into `fileCount` or `attributedNodeCount` would
/// change what a number on screen means.
///
/// Every assertion is checked against a second implementation written here from
/// the semantics, not from the engine's fold — a count that is wrong in the same
/// way as its oracle proves nothing. Where a value is worth naming, it is also
/// hand-counted in the test.
final class DescendantCountTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    // MARK: - Independent oracles

    /// `presentedDescendants(node) = Σ children: 1 + (child is a package ? 0 : presentedDescendants(child))`
    private func foldPresentedDescendants(_ node: ScanNode) -> Int {
        var count = 0
        for child in node.children {
            count += 1
            if child.kind != .package { count += foldPresentedDescendants(child) }
        }
        return count
    }

    /// `folderDescendants(node) = Σ children: (child is directory-like ? 1 : 0) + folderDescendants(child)`
    private func foldFolderDescendants(_ node: ScanNode) -> Int {
        var count = 0
        for child in node.children {
            if child.isDirectoryLike { count += 1 }
            count += foldFolderDescendants(child)
        }
        return count
    }

    /// The status line's own classification, unchanged from the walk this work
    /// replaced: a `.directory` is a folder and is descended, everything else
    /// is a file, and nothing below a package is counted separately.
    private func foldVisibleTotals(_ root: ScanNode) -> (files: Int, folders: Int) {
        var files = 0
        var folders = 0
        var stack = root.children
        while let current = stack.popLast() {
            switch current.kind {
            case .directory:
                folders += 1
                stack.append(contentsOf: current.children)
            case .package, .file, .symbolicLink, .other:
                files += 1
                if current.kind != .package { stack.append(contentsOf: current.children) }
            }
        }
        return (files, folders)
    }

    /// Both stored counts, at **every** node of the finished tree. A count that
    /// is right at the root and wrong three levels down is still a wrong Items
    /// cell.
    private func assertCountsFold(
        _ root: ScanNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var stack: [ScanNode] = [root]
        while let node = stack.popLast() {
            XCTAssertEqual(
                node.presentedDescendantCount, foldPresentedDescendants(node),
                "\(node.name): presented descendants disagree with an independent fold",
                file: file, line: line
            )
            XCTAssertEqual(
                node.folderDescendantCount, foldFolderDescendants(node),
                "\(node.name): folder descendants disagree with an independent fold",
                file: file, line: line
            )
            stack.append(contentsOf: node.children)
        }
    }

    private func assertVisibleTotalsFold(
        _ result: ScanResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = foldVisibleTotals(result.root)
        XCTAssertEqual(result.visibleTotals.files, expected.files,
                       "status files", file: file, line: line)
        XCTAssertEqual(result.visibleTotals.folders, expected.folders,
                       "status folders", file: file, line: line)
    }

    // MARK: - Names, not bytes

    /// The counts are about entries in the tree, so everything weightless still
    /// counts: an empty file, an empty directory, a symlink, an entry whose
    /// size could not be read. `attributedNodeCount` excludes every one of
    /// these, which is exactly why it cannot stand in for these.
    func test_weightlessEntriesStillCountAsItems() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("payload.bin", bytes: 4_096, volume: volumeA),
            .file("zero.txt", bytes: 0, volume: volumeA),
            .directory("empty", volume: volumeA),
            .symlink("link", volume: volumeA),
            .file("unreadable.bin", bytes: nil, volume: volumeA),
            .directory("locked", volume: volumeA, listFailure: CocoaError(.fileReadNoPermission), children: [
                .file("hidden-away.bin", bytes: 99, volume: volumeA)
            ])
        ])

        guard let result = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)).result
        else { return XCTFail("expected a result") }

        // Six names below the root, and none of them has anything below it in
        // the tree — the unreadable directory contributed no children.
        XCTAssertEqual(result.root.presentedDescendantCount, 6)
        XCTAssertEqual(result.root.folderDescendantCount, 2, "empty and locked")
        XCTAssertEqual(node(result.root, at: "empty")?.presentedDescendantCount, 0)
        XCTAssertEqual(node(result.root, at: "locked")?.presentedDescendantCount, 0)
        // The same tree, counted by rectangles: only the one file with blocks.
        XCTAssertEqual(result.root.attributedNodeCount, 2)

        // Status semantics: `empty` and `locked` are folders, the other four
        // are files.
        XCTAssertEqual(result.visibleTotals.files, 4)
        XCTAssertEqual(result.visibleTotals.folders, 2)

        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)
    }

    /// A hard-linked inode reached by two names is one set of bytes and **two
    /// items**: both names have a row. The byte and file semantics are
    /// untouched by this work, and are asserted here so a later change to the
    /// counts cannot quietly move them.
    func test_bothNamesOfAHardLinkedInodeCountAsItems() async {
        let inode = FileSystemIdentity("inode-7")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("a", volume: volumeA, children: [
                .file("owner.bin", bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode)
            ]),
            .directory("b", volume: volumeA, children: [
                .file("second-name.bin", bytes: 4_096, volume: volumeA, linkCount: 2, identity: inode)
            ])
        ])

        guard let result = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)).result
        else { return XCTFail("expected a result") }

        let owner = node(result.root, at: "a/owner.bin")
        let second = node(result.root, at: "b/second-name.bin")
        XCTAssertEqual(second?.attribution, .hardLinkElsewhere(owner: ["scan-root", "a", "owner.bin"]))

        // Two directories and two file names.
        XCTAssertEqual(result.root.presentedDescendantCount, 4)
        XCTAssertEqual(result.root.folderDescendantCount, 2)
        XCTAssertEqual(node(result.root, at: "b")?.presentedDescendantCount, 1,
                       "a name that owns no bytes is still a name")
        XCTAssertEqual(result.visibleTotals.files, 2)
        XCTAssertEqual(result.visibleTotals.folders, 2)

        // Untouched: the bytes are counted once, both names have a file count.
        XCTAssertEqual(result.root.subtreeDiskBytes, 4_096)
        XCTAssertEqual(owner?.ownDiskBytes, 4_096)
        XCTAssertEqual(second?.ownDiskBytes, 0)
        XCTAssertEqual(result.root.fileCount, 2)

        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)
    }

    /// A second path to a directory already walked keeps its name and loses its
    /// subtree — so it counts once, where it appears, and contributes nothing
    /// below itself.
    func test_aRepeatedDirectoryNameCountsOnceWhereItAppears() async {
        let shared = FileSystemIdentity("dir-shared")
        // Named so the walk meets the real directory first: arrival order
        // decides which of two paths keeps the subtree, and the walk lists a
        // directory's entries in name order.
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("dir-root"), children: [
            .directory("a-real", volume: volumeA, identity: shared, children: [
                .file("one.bin", bytes: 10, volume: volumeA),
                .file("two.bin", bytes: 20, volume: volumeA)
            ]),
            .directory("z-graft", volume: volumeA, identity: shared, children: [
                .file("one.bin", bytes: 10, volume: volumeA),
                .file("two.bin", bytes: 20, volume: volumeA)
            ])
        ])

        guard let result = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)).result
        else { return XCTFail("expected a result") }

        let graft = node(result.root, at: "z-graft")
        XCTAssertEqual(graft?.attribution, .directoryCountedElsewhere(owner: ["scan-root", "a-real"]))
        XCTAssertEqual(graft?.children.count, 0, "the second path is never listed")

        // `a-real` with its two files, plus the `z-graft` name itself.
        XCTAssertEqual(result.root.presentedDescendantCount, 4)
        XCTAssertEqual(result.root.folderDescendantCount, 2)
        XCTAssertEqual(graft?.presentedDescendantCount, 0)
        XCTAssertEqual(result.visibleTotals.files, 2)
        XCTAssertEqual(result.visibleTotals.folders, 2)

        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)
    }

    // MARK: - Packages

    /// A package containing ordinary directories and a nested package — the
    /// case where the two per-node counts must disagree, and where each of them
    /// has to be right at four different depths.
    func test_aPackageStopsTheItemsWalkAndNotTheFolderWalk() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("readme.txt", bytes: 10, volume: volumeA),
            .directory("Apps", volume: volumeA, children: [
                .directory("Outer.app", volume: volumeA, isPackage: true, children: [
                    .file("binary", bytes: 500, volume: volumeA),
                    .directory("Resources", volume: volumeA, children: [
                        .file("art.png", bytes: 25, volume: volumeA),
                        .directory("Assets", volume: volumeA, children: [
                            .file("icon.png", bytes: 5, volume: volumeA)
                        ])
                    ]),
                    .directory("Nested.appex", volume: volumeA, isPackage: true, children: [
                        .file("plugin", bytes: 30, volume: volumeA),
                        .directory("Support", volume: volumeA, children: [
                            .file("data.bin", bytes: 3, volume: volumeA)
                        ])
                    ])
                ])
            ])
        ])

        guard let result = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)).result
        else { return XCTFail("expected a result") }

        let apps = node(result.root, at: "Apps")
        let outer = node(result.root, at: "Apps/Outer.app")
        let resources = node(result.root, at: "Apps/Outer.app/Resources")
        let assets = node(result.root, at: "Apps/Outer.app/Resources/Assets")
        let nested = node(result.root, at: "Apps/Outer.app/Nested.appex")
        let support = node(result.root, at: "Apps/Outer.app/Nested.appex/Support")

        // Items — presentation semantics. `Apps` sees `Outer.app` as one item
        // and stops; the root sees `readme.txt`, `Apps` and `Outer.app`.
        XCTAssertEqual(apps?.presentedDescendantCount, 1)
        XCTAssertEqual(result.root.presentedDescendantCount, 3)
        // The package row still describes its own contents: binary, Resources,
        // art.png, Assets, icon.png, Nested.appex — six, stopping again at the
        // nested package.
        XCTAssertEqual(outer?.presentedDescendantCount, 6)
        XCTAssertEqual(resources?.presentedDescendantCount, 3)
        XCTAssertEqual(assets?.presentedDescendantCount, 1)
        // And the nested package describes its own contents in turn.
        XCTAssertEqual(nested?.presentedDescendantCount, 3)
        XCTAssertEqual(support?.presentedDescendantCount, 1)

        // "Contains" — scanner semantics. A package is a folder and the walk
        // goes straight through it: Outer.app, Resources, Assets, Nested.appex,
        // Support.
        XCTAssertEqual(result.root.folderDescendantCount, 6, "Apps plus the five below it")
        XCTAssertEqual(apps?.folderDescendantCount, 5)
        XCTAssertEqual(outer?.folderDescendantCount, 4)
        XCTAssertEqual(nested?.folderDescendantCount, 1)
        XCTAssertEqual(resources?.folderDescendantCount, 1)

        // Status — a package is one item, filed under files, and nothing below
        // it is counted: readme.txt and Outer.app are the files, Apps the
        // folder.
        XCTAssertEqual(result.visibleTotals.files, 2)
        XCTAssertEqual(result.visibleTotals.folders, 1)

        // The three are genuinely different numbers on the same tree.
        XCTAssertEqual(result.root.fileCount, 6, "the scanner's own file tally is unchanged")

        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)
    }

    // MARK: - Depth

    /// Depth is the user's to choose. The finalization pass uses an explicit
    /// frame stack for the same reason the traversal does, and this is the
    /// fixture that would blow a recursive one.
    func test_aDeepChainIsFinalizedWithoutRecursion() async {
        let depth = 512
        var deepest = ScriptedEntry.directory("level-\(depth)", volume: volumeA, children: [
            .file("leaf.bin", bytes: 128, volume: volumeA)
        ])
        for level in stride(from: depth - 1, through: 1, by: -1) {
            deepest = .directory("level-\(level)", volume: volumeA, children: [deepest])
        }

        guard let result = await runScan(ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .directory("scan-root", volume: volumeA, children: [deepest])
        )).result else { return XCTFail("expected a result") }

        // Every level plus the leaf file.
        XCTAssertEqual(result.root.presentedDescendantCount, depth + 1)
        XCTAssertEqual(result.root.folderDescendantCount, depth)
        XCTAssertEqual(node(result.root, at: "level-1")?.presentedDescendantCount, depth)
        XCTAssertEqual(result.visibleTotals.files, 1)
        XCTAssertEqual(result.visibleTotals.folders, depth)

        // The deepest few levels, so an off-by-one at the bottom is caught too.
        let deepestPath = (1...depth).map { "level-\($0)" }.joined(separator: "/")
        XCTAssertEqual(node(result.root, at: deepestPath)?.presentedDescendantCount, 1)
        XCTAssertEqual(node(result.root, at: deepestPath)?.folderDescendantCount, 0)

        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)
    }

    /// A root with many direct children and nothing beneath them: the shape the
    /// finalization pass must not answer with a second collection the size of
    /// the tree.
    func test_aVeryWideDirectoryIsFinalizedInOnePass() async {
        let width = 20_000
        let flat = ScriptedEntry.directory("scan-root", volume: volumeA, children: (0..<width).map { index in
            .file(String(format: "f%05d.bin", index), bytes: 1, volume: volumeA)
        })

        guard let result = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: flat)).result
        else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.presentedDescendantCount, width)
        XCTAssertEqual(result.root.folderDescendantCount, 0)
        XCTAssertEqual(result.visibleTotals.files, width)
        XCTAssertEqual(result.visibleTotals.folders, 0)
        assertVisibleTotalsFold(result)
    }

    // MARK: - Cancellation

    /// A partial tree is a published tree, so it has to be finalized too — the
    /// counts must describe the nodes that exist, not the ones the scan would
    /// have reached.
    func test_aCancelledScanPublishesAFinalizedPartialTree() async {
        let scanner = Scanner()
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: (0..<8).map { index in
            .directory(String(format: "d%03d", index), volume: volumeA, children: [
                .file("f.bin", bytes: 10, volume: volumeA),
                .directory("inner", volume: volumeA, children: [
                    .file("g.bin", bytes: 20, volume: volumeA)
                ])
            ])
        })
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: tree,
            beforeRequest: { request in
                if request.kind == .list, request.path == "d002" { scanner.cancel() }
            }
        )

        let events = await collectEvents(await scanner.scan(makeRequest(probe: probe)))
        guard let result = events.result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertGreaterThan(result.root.children.count, 0, "a cancelled scan hands over what it reached")

        // The whole point: the stored counts on a partial tree are the counts of
        // the partial tree, not zeroes and not the counts of the tree that was
        // never built.
        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)
        XCTAssertEqual(
            result.visibleTotals.files + result.visibleTotals.folders,
            result.root.presentedDescendantCount,
            "the status totals partition the root's presented descendants"
        )
    }

    /// The stop *inside* one enormous directory: the frames that were open when
    /// cancellation landed are the ones most likely to be finalized wrong.
    func test_aScanCancelledMidDirectoryStillCountsWhatItKept() async {
        let scanner = Scanner()
        let flat = ScriptedEntry.directory("scan-root", volume: volumeA, children: (0..<5_000).map { index in
            .file(String(format: "f%05d.bin", index), bytes: 1, volume: volumeA)
        })
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: flat,
            beforeRequest: { request in
                if request.kind == .list { scanner.cancel() }
            }
        )

        let events = await collectEvents(await scanner.scan(makeRequest(
            probe: probe,
            options: ScanOptions(progressInterval: .infinity, cancellationBatchSize: 256)
        )))
        guard let result = events.result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.root.children.count, 256)
        XCTAssertEqual(result.root.presentedDescendantCount, 256)
        XCTAssertEqual(result.visibleTotals, VisibleTreeTotals(files: 256, folders: 0))
        assertCountsFold(result.root)
    }

    // MARK: - The whole matrix at once

    /// Everything above in one tree, folded at every node — the guard against a
    /// rule that is right in isolation and wrong beside its neighbour.
    func test_everyNodeOfAMixedTreeAgreesWithAnIndependentFold() async {
        let inode = FileSystemIdentity("inode-9")
        let shared = FileSystemIdentity("dir-shared")
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, identity: FileSystemIdentity("dir-root"), children: [
            .file("top.bin", bytes: 1_000, volume: volumeA),
            .file("zero.txt", bytes: 0, volume: volumeA),
            .symlink("alias", looksLikeDirectory: true, volume: volumeA, children: [
                .file("never-listed.bin", bytes: 1_000_000, volume: volumeA)
            ]),
            .directory("empty", volume: volumeA),
            .directory("docs", volume: volumeA, identity: shared, children: [
                .file("a.txt", bytes: 10, volume: volumeA),
                .file("link-owner.bin", bytes: 512, volume: volumeA, linkCount: 2, identity: inode),
                .directory("nested", volume: volumeA, children: [
                    .file("deep.bin", bytes: 300, volume: volumeA),
                    .file("no-size.bin", bytes: nil, volume: volumeA)
                ])
            ]),
            .directory("docs-again", volume: volumeA, identity: shared, children: [
                .file("a.txt", bytes: 10, volume: volumeA)
            ]),
            .file("link-second.bin", bytes: 512, volume: volumeA, linkCount: 2, identity: inode),
            .directory("Media.app", volume: volumeA, isPackage: true, children: [
                .file("binary", bytes: 500, volume: volumeA),
                .directory("Resources", volume: volumeA, children: [
                    .file("art.png", bytes: 25, volume: volumeA),
                    .directory("Plugins", volume: volumeA, children: [
                        .directory("One.appex", volume: volumeA, isPackage: true, children: [
                            .file("p.bin", bytes: 7, volume: volumeA)
                        ])
                    ])
                ])
            ]),
            .directory("unreadable", volume: volumeA, listFailure: CocoaError(.fileReadNoPermission), children: [
                .file("gone.bin", bytes: 4_096, volume: volumeA)
            ])
        ])

        guard let result = await runScan(ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)).result
        else { return XCTFail("expected a result") }

        assertCountsFold(result.root)
        assertVisibleTotalsFold(result)

        // Named, so a silent change to the semantics fails here and not only in
        // the oracle. The nine names below the root, plus docs' five (a.txt,
        // link-owner.bin, nested, and nested's two) — fourteen. Media.app's
        // interior is not among them.
        XCTAssertEqual(result.root.presentedDescendantCount, 14)
        // Every directory-like descendant, package interiors included:
        // Media.app, Resources, Plugins, One.appex, docs, docs/nested,
        // docs-again, empty, unreadable.
        XCTAssertEqual(result.root.folderDescendantCount, 9)
        XCTAssertEqual(result.visibleTotals.folders, 5,
                       "empty, docs, docs/nested, docs-again, unreadable")
        XCTAssertEqual(result.visibleTotals.files, 9)
        // binary, Resources, art.png, Plugins, One.appex — the nested package
        // is one item and stops the walk again.
        XCTAssertEqual(node(result.root, at: "Media.app")?.presentedDescendantCount, 5)
        XCTAssertEqual(node(result.root, at: "Media.app")?.folderDescendantCount, 3)
        XCTAssertEqual(node(result.root, at: "docs-again")?.presentedDescendantCount, 0,
                       "a second path to a walked directory has no children to count")
    }
}
