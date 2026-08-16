import XCTest
@testable import ScanCore
import ScanCoreTestSupport

/// Resilience (spec §3.5, §5.7): a recoverable filesystem problem never fails
/// the scan and never guesses a size. The entry is Unreadable, its ancestors
/// are Incomplete, its siblings carry on, the scan still reaches `.completed`,
/// the category counts are exact, and the detail list is bounded.
final class ResilienceTests: XCTestCase {
    private let volumeA = FileSystemIdentity("volume-A")

    private var permissionDenied: Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)
    }

    private var vanished: Error {
        CocoaError(.fileNoSuchFile)
    }

    // MARK: - Siblings continue, ancestors are honest

    func test_anUnreadableDirectoryDoesNotAbortItsSiblings() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("a-before", volume: volumeA, children: [
                .file("a.bin", bytes: 100, volume: volumeA)
            ]),
            .directory("b-locked", volume: volumeA, listFailure: permissionDenied, children: [
                .file("never-seen.bin", bytes: 999_999, volume: volumeA)
            ]),
            .directory("c-after", volume: volumeA, children: [
                .file("c.bin", bytes: 200, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .completed, "a recoverable error still reaches completion")
        XCTAssertEqual(result.root.subtreeBytes, 300, "the sibling after the failure was still measured")
        XCTAssertEqual(probe.listedPaths, ["", "a-before", "b-locked", "c-after"])

        let locked = node(result.root, at: "b-locked")
        XCTAssertEqual(locked?.readState, .unreadable)
        XCTAssertEqual(locked?.subtreeBytes, 0, "an unreadable directory's size is not guessed")
        XCTAssertTrue(locked?.children.isEmpty == true)

        XCTAssertEqual(result.root.readState, .incomplete)
        XCTAssertEqual(node(result.root, at: "a-before")?.readState, .complete)
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 1))

        XCTAssertEqual(result.errors.total, 1)
        XCTAssertEqual(result.errors.byCategory, [.unreadableDirectory: 1])
        XCTAssertFalse(result.errors.truncated)
        XCTAssertEqual(result.errors.details.map(\.path), [["scan-root", "b-locked"]])
        XCTAssertEqual(result.errors.details.first?.category, .unreadableDirectory)
    }

    func test_everyAffectedAncestorIsIncompleteAndUnaffectedOnesAreNot() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("clean", volume: volumeA, children: [
                .file("ok.bin", bytes: 10, volume: volumeA)
            ]),
            .directory("outer", volume: volumeA, children: [
                .directory("inner", volume: volumeA, children: [
                    .directory("locked", volume: volumeA, listFailure: permissionDenied),
                    .file("sibling.bin", bytes: 20, volume: volumeA)
                ])
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(node(result.root, at: "outer/inner/locked")?.readState, .unreadable)
        XCTAssertEqual(node(result.root, at: "outer/inner")?.readState, .incomplete)
        XCTAssertEqual(node(result.root, at: "outer")?.readState, .incomplete)
        XCTAssertEqual(result.root.readState, .incomplete)
        XCTAssertEqual(node(result.root, at: "clean")?.readState, .complete,
                       "a subtree with nothing wrong in it is not tainted")
        XCTAssertEqual(node(result.root, at: "outer/inner/sibling.bin")?.readState, .complete)
        XCTAssertEqual(result.root.subtreeBytes, 30)
    }

    func test_malformedMetadataIsAnUnreadableEntryWithNoGuessedSize() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("known.bin", bytes: 700, volume: volumeA),
            .file("malformed.bin", bytes: nil, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.root.subtreeBytes, 700, "no synthetic figure fills the gap")
        XCTAssertEqual(node(result.root, at: "malformed.bin")?.readState, .unreadable)
        XCTAssertEqual(node(result.root, at: "malformed.bin")?.ownBytes, 0)
        XCTAssertEqual(result.errors.byCategory, [.unreadableEntry: 1])
        XCTAssertEqual(result.errors.details.map(\.path), [["scan-root", "malformed.bin"]])
    }

    /// The categories are separate counts, and each one is exact.
    func test_categoryCountsAreExactAcrossMixedFailures() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("locked-1", volume: volumeA, listFailure: permissionDenied),
            .directory("locked-2", volume: volumeA, listFailure: permissionDenied),
            .directory("gone", volume: volumeA, listFailure: vanished),
            .file("bad-1.bin", bytes: nil, volume: volumeA),
            .file("bad-2.bin", bytes: nil, volume: volumeA),
            .file("bad-3.bin", bytes: nil, volume: volumeA),
            .file("fine.bin", bytes: 5, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.errors.byCategory, [
            .unreadableDirectory: 2,
            .disappeared: 1,
            .unreadableEntry: 3
        ])
        XCTAssertEqual(result.errors.total, 6)
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 6))
        XCTAssertEqual(result.root.subtreeBytes, 5)
        XCTAssertTrue(result.exclusions.isEmpty, "nothing here was excluded by policy")
    }

    // MARK: - Bounded error detail

    func test_anErrorStormKeepsAnExactTotalAndOnlyTheFirstThousandRecords() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: (0..<2_500).map { index in
            .directory(String(format: "d%04d", index), volume: volumeA, listFailure: permissionDenied)
        })
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(
            probe,
            options: ScanOptions(progressCadence: .terminalOnly, treeCadence: .terminalOnly)
        ).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .completed, "2,500 failures still do not fail the scan")
        XCTAssertEqual(result.errors.total, 2_500, "the running total stays exact past the cap")
        XCTAssertEqual(result.errors.byCategory[.unreadableDirectory], 2_500)
        XCTAssertEqual(result.errors.details.count, 1_000)
        XCTAssertTrue(result.errors.truncated)
        XCTAssertEqual(result.errors.details.first?.path, ["scan-root", "d0000"],
                       "the retained records are the first ones, in traversal order")
        XCTAssertEqual(result.errors.details.last?.path, ["scan-root", "d0999"])
        XCTAssertEqual(result.completeness, .incomplete(cancelled: false, unreadableEntries: 2_500))
        XCTAssertEqual(result.root.children.count, 2_500, "every failing entry is still visible")
    }

    func test_theDetailCapIsConfigurableAndTruncationTracksIt() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: (0..<7).map { index in
            .directory("d\(index)", volume: volumeA, listFailure: permissionDenied)
        })
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(
            probe,
            options: ScanOptions(maxDetailedErrors: 3)
        ).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.errors.total, 7)
        XCTAssertEqual(result.errors.details.count, 3)
        XCTAssertTrue(result.errors.truncated)
    }

    func test_aScanWithNothingWrongCarriesAnEmptySummary() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .file("a.bin", bytes: 3, volume: volumeA)
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(result.errors.truncated)
        XCTAssertTrue(result.exclusions.isEmpty)
        XCTAssertEqual(result.completeness, .exact)
    }

    // MARK: - Live change

    /// A barrier probe: the entry is listed by its parent, then vanishes before
    /// the walk reaches it. That is a recoverable error — not a retry, not a
    /// second pass, not a restart.
    func test_anEntryThatVanishesAfterBeingListedIsARecoverableError() async {
        let tree = ScriptedEntry.directory("scan-root", volume: volumeA, children: [
            .directory("a-stable", volume: volumeA, children: [
                .file("a.bin", bytes: 11, volume: volumeA)
            ]),
            // Listed with its parent, gone by the time the walk descends.
            .directory("b-vanishing", volume: volumeA, listFailure: vanished, children: [
                .file("never-seen.bin", bytes: 1_000, volume: volumeA)
            ]),
            .directory("c-stable", volume: volumeA, children: [
                .file("c.bin", bytes: 22, volume: volumeA)
            ])
        ])
        let probe = ScriptedDirectoryProbe(rootURL: scanRootURL, root: tree)

        guard let result = await runScan(probe).result else { return XCTFail("expected a result") }

        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.errors.byCategory, [.disappeared: 1],
                       "a disappearance is its own category, not a permission failure")
        XCTAssertEqual(node(result.root, at: "b-vanishing")?.readState, .unreadable)
        XCTAssertEqual(result.root.subtreeBytes, 33)

        // No second pass and no automatic restart: every directory was listed
        // exactly once, the vanished one included.
        XCTAssertEqual(probe.listedPaths, ["", "a-stable", "b-vanishing", "c-stable"])
        XCTAssertEqual(Set(probe.listedPaths).count, probe.listedPaths.count, "a path was listed twice")
        XCTAssertEqual(probe.requests.filter { $0.kind == .metadata }.map(\.path), [""],
                       "only the root is ever read by metadata — no re-read of the vanished entry")
    }

    func test_aVanishedRootIsAPreFlightFailureNotARecoverableError() async {
        // The one place a scan can fail at all (spec §5.3) — and it fails
        // before any node exists to mark.
        let probe = ScriptedDirectoryProbe(
            rootURL: scanRootURL,
            root: .directory("scan-root", volume: volumeA),
            metadataFailure: vanished
        )

        let events = await runScan(probe)

        XCTAssertEqual(events.failure, .rootMissing(scanRootURL))
        XCTAssertNil(events.result)
    }
}
