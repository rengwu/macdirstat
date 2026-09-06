import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

final class FastModeHardLinkTests: XCTestCase {
    func test_packageOwnerIsNotCountedAgainOutsideThePackage() async throws {
        try await check(paths: ["A.app/Contents/owner.bin", "z-outside.bin"])
    }

    func test_outsideOwnerIsNotCountedAgainInsideThePackage() async throws {
        try await check(paths: ["A-outside.bin", "Z.app/Contents/link.bin"])
    }

    func test_twoPackagesShareOneContribution() async throws {
        try await check(paths: ["A.app/Contents/owner.bin", "Z.app/Contents/link.bin"])
    }

    func test_linksWithinAPackageKeepTheirCountsAndDeterministicOwner() async throws {
        // Create in the opposite order to traversal. Hidden directories are
        // deferred; hidden files are not. The later outside link must point
        // to the same full owner path in both modes.
        try await check(paths: [
            "A.app/.hidden/link.bin",
            "A.app/Visible/link.bin",
            "A.app/.first.bin",
            "z-outside.bin",
        ])
    }

    func test_aLinkOutsideTheScanRootDoesNotRemoveThePackagesBytes() async throws {
        try await check(paths: ["A.app/Contents/owner.bin"], addOutsideLink: true)
    }

    func test_hiddenDirectoryLinksDoNotOwnBytesBeforeVisibleDirectoryLinks() async throws {
        try await check(paths: [
            "A.app/.hidden/link.bin",
            "A.app/Visible/link.bin",
            "z-outside.bin",
        ])
    }

    private func check(paths: [String], addOutsideLink: Bool = false) async throws {
        let fixture = try TemporaryFileSystemFixture(label: "fast-hard-links")
        defer { try? fixture.cleanUp() }
        let fm = FileManager.default
        let rootURL = fixture.directory.appendingPathComponent("scan-root")
        let owner = rootURL.appendingPathComponent(paths[0])
        for path in paths {
            try fm.createDirectory(
                at: rootURL.appendingPathComponent(path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let contentBytes = 1_048_576
        try Data(repeating: 0x59, count: contentBytes).write(to: owner)
        for path in paths.dropFirst() {
            try fm.linkItem(at: owner, to: rootURL.appendingPathComponent(path))
        }
        if addOutsideLink {
            try fm.linkItem(at: owner, to: fixture.directory.appendingPathComponent("outside.bin"))
        }

        let packages = Set(paths.compactMap { path -> String? in
            let name = String(path.split(separator: "/")[0])
            return name.hasSuffix(".app") ? name : nil
        })
        var expectedDiskBytes = try XCTUnwrap(owner.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize)
        for package in packages {
            let unique = rootURL.appendingPathComponent(package + "/unique.bin")
            try Data(repeating: 0x37, count: 4096).write(to: unique)
            expectedDiskBytes += try XCTUnwrap(unique.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize)
        }

        let detailedEvents = await runProductionScan(root: rootURL)
        let fastEvents = await runProductionScan(
            root: rootURL,
            options: ScanOptions(progressInterval: .infinity, packageScanMode: .summarized)
        )
        let detailed = try XCTUnwrap(detailedEvents.result)
        let fast = try XCTUnwrap(fastEvents.result)
        XCTAssertEqual(detailed.root.subtreeDiskBytes, Int64(expectedDiskBytes))
        XCTAssertEqual(fast.root.subtreeDiskBytes, Int64(expectedDiskBytes))
        XCTAssertEqual(fast.root.subtreeContentBytes, Int64(contentBytes + packages.count * 4096))
        XCTAssertEqual(fast.root.fileCount, Int64(paths.count + packages.count))
        XCTAssertEqual(fast.root.fileCount, detailed.root.fileCount)
        XCTAssertEqual(fast.root.folderDescendantCount, detailed.root.folderDescendantCount)
        XCTAssertEqual(fast.completeness, .exact)
        XCTAssertEqual(fast.errors.total, 0)
        XCTAssertEqual(fastEvents.progressSnapshots.last?.attributedDiskBytes, Int64(expectedDiskBytes))

        for child in fast.root.children {
            let normal = try XCTUnwrap(node(detailed.root, at: child.name))
            XCTAssertEqual(child.subtreeDiskBytes, normal.subtreeDiskBytes, child.name)
            XCTAssertEqual(child.subtreeContentBytes, normal.subtreeContentBytes, child.name)
            XCTAssertEqual(child.fileCount, normal.fileCount, child.name)
            XCTAssertEqual(child.attribution, normal.attribution, child.name)
            if packages.contains(child.name) {
                XCTAssertTrue(child.isPackageSummary)
                XCTAssertTrue(child.children.isEmpty, "Fast mode must keep the package compact")
            }
        }
    }
}
