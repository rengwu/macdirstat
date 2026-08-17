import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

/// The tree the window is handed has to be one tree.
///
/// It used to be two. The engine republished the tree several times a second by
/// copying the folders it was still working on and reusing the finished ones by
/// reference — and those reused nodes kept pointing up at the *live* tree the
/// scan thread was still writing to. Two things fell out of that: the % column
/// divided by a total that was still being written, and a selection held across
/// a republish could outlive the copy it came from, because the upward pointer
/// does not keep its target alive.
///
/// These are the assertions that fail on that design and pass on one tree.
@MainActor
final class PublishedTreeIntegrityTests: XCTestCase {
    private func makeFixture() async throws -> ScannedFixture {
        try await ScannedFixture.make(in: self) { root in
            let alpha = try makeDirectory("alpha", in: root)
            try writeFile("a1.bin", bytes: 4_000, in: alpha)
            try writeFile("a2.bin", bytes: 8_000, in: alpha)
            let nested = try makeDirectory("nested", in: alpha)
            try writeFile("n1.bin", bytes: 2_000, in: nested)
            let beta = try makeDirectory("beta", in: root)
            try writeFile("b1.bin", bytes: 16_000, in: beta)
        }
    }

    /// Every node hangs from the parent it points at. A tree that fails this is
    /// spliced, and every figure derived from `parent` is derived from the wrong
    /// node.
    func test_everyNodeHangsFromTheParentItPointsAt() async throws {
        let fixture = try await makeFixture()

        var mismatches: [String] = []
        var stack = [fixture.rootNode]
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            for child in node.children {
                if child.parent !== node {
                    mismatches.append("\(child.name) hangs from \(node.name) but points at \(child.parent?.name ?? "nil")")
                }
                stack.append(child)
            }
        }
        XCTAssertGreaterThan(visited, 5, "the fixture must have some depth to it")
        XCTAssertEqual(mismatches, [], "the published tree is spliced")
    }

    /// The % column reads `node.parent.subtreeDiskBytes`. That denominator has
    /// to be the total of the folder the row actually sits in, and it has to
    /// hold still.
    func test_shareOfParentUsesTheRealParentTotal() async throws {
        let fixture = try await makeFixture()
        let alpha = try fixture.node(named: "alpha")
        let nested = try fixture.node(named: "nested")

        XCTAssertTrue(nested.parent === alpha, "nested must sit inside alpha")
        let denominator = try XCTUnwrap(nested.parent?.subtreeDiskBytes)
        XCTAssertEqual(denominator, alpha.subtreeDiskBytes)
        XCTAssertGreaterThan(denominator, 0)
        XCTAssertLessThanOrEqual(nested.subtreeDiskBytes, denominator,
                                 "a child cannot hold more than the folder it is in")

        // The scan is over; nothing may still be moving.
        let again = try XCTUnwrap(nested.parent?.subtreeDiskBytes)
        XCTAssertEqual(denominator, again)
    }

    /// A selection is one node, held on its own. Rebuilding its path walks the
    /// parent chain, so the chain has to stay alive and stay correct — this is
    /// the read that used to touch freed memory.
    func test_aHeldSelectionCanStillNameItsOwnPath() async throws {
        let fixture = try await makeFixture()
        let (workspace, actions, _) = fixture.makeWorkspace()
        let nested = try fixture.node(named: "n1.bin")

        workspace.selectionModel.select(.node(nested), source: .tree)

        let url = try XCTUnwrap(workspace.selectedURL)
        XCTAssertEqual(url, fixture.root
            .appendingPathComponent("alpha")
            .appendingPathComponent("nested")
            .appendingPathComponent("n1.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the rebuilt path must be the file that is really there")

        workspace.openSelection()
        XCTAssertEqual(actions.opened, [url])
    }

    /// While a scan runs the panes stay empty and the card carries the numbers.
    /// The tree arrives once, with the terminal event.
    func test_theTreeArrivesOnlyWhenTheScanFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDirStat-Terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 {
            let directory = try makeDirectory("d\(index)", in: root)
            try writeFile("f.bin", bytes: 1_000, in: directory)
        }

        let model = ScanPresentationModel()
        var rootWhileScanning: [ScanNode?] = []
        let finished = expectation(description: "scan finished")
        model.onChange = {
            if model.phase == .scanning { rootWhileScanning.append(model.root) }
            if model.phase == .completed { finished.fulfill() }
        }
        model.start(root: root, mode: .folder)
        await fulfillment(of: [finished], timeout: 20)
        model.onChange = nil

        XCTAssertFalse(rootWhileScanning.isEmpty, "the card must have been fed progress")
        XCTAssertTrue(rootWhileScanning.allSatisfy { $0 == nil },
                      "no tree may be published before the scan is finished with it")
        XCTAssertNotNil(model.root, "the finished scan hands over its tree")
        XCTAssertEqual(model.root?.children.count, 40)
    }
}
