import XCTest
@testable import TreemapLayout

/// ``TreemapLayoutCoordinator`` — the rule that a layout never runs on the
/// thread that draws (ticket 14).
///
/// The geometry is not under test here; the seventy-odd tests around this one
/// own that, and the coordinator changes none of it. What is under test is
/// *when* and *where*: that background work leaves the calling thread free,
/// that a storm of requests produces one layout at a time rather than a queue
/// of them, and that the last request always wins in the end.
@MainActor
final class LayoutCoordinatorTests: XCTestCase {
    private let viewport = TreemapSize(width: 520, height: 390)

    private func tree(seed: Int64 = 1) -> TreemapTree {
        TreemapTree(directory: "root", children: (0..<200).map {
            TreemapTree(name: String(format: "item-%03d.dat", $0), bytes: seed * Int64($0 + 1) * 4_096)
        })
    }

    // MARK: - Immediate

    func test_immediateExecutionHasTheResultBeforeItReturns() {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .immediate)
        var notifications = 0
        coordinator.onResult = { notifications += 1 }

        coordinator.request(tree: tree(), viewport: viewport, revision: 1)

        XCTAssertNotNil(coordinator.result)
        XCTAssertTrue(coordinator.isSettled)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(coordinator.layoutCount, 1)
        XCTAssertEqual(coordinator.resultRequest, .init(revision: 1, viewport: viewport))
    }

    func test_askingAgainForWhatIsAlreadyHeldDoesNothing() {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .immediate)
        coordinator.request(tree: tree(), viewport: viewport, revision: 1)
        coordinator.request(tree: tree(), viewport: viewport, revision: 1)
        coordinator.request(tree: tree(), viewport: viewport, revision: 1)

        XCTAssertEqual(coordinator.layoutCount, 1)
    }

    func test_eitherExecutionProducesTheSameGeometry() async {
        let inline = TreemapLayoutCoordinator<TreemapTree>(execution: .immediate)
        let background = TreemapLayoutCoordinator<TreemapTree>(execution: .background)

        inline.request(tree: tree(), viewport: viewport, revision: 1)
        background.request(tree: tree(), viewport: viewport, revision: 1)
        await background.settle()

        let a = inline.result?.boxes.map(\.frame) ?? []
        let b = background.result?.boxes.map(\.frame) ?? []
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b, "the thread a layout runs on must not move a rectangle")
    }

    // MARK: - Background

    func test_backgroundExecutionReturnsBeforeTheLayoutExists() async {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .background)

        coordinator.request(tree: tree(), viewport: viewport, revision: 1)

        XCTAssertNil(coordinator.result, "the layout was computed on the calling thread")
        XCTAssertFalse(coordinator.isSettled)

        await coordinator.settle()
        XCTAssertNotNil(coordinator.result)
        XCTAssertTrue(coordinator.isSettled)
        XCTAssertEqual(coordinator.resultRequest?.revision, 1)
    }

    /// A live resize, or a scan republishing its tree: many requests arrive
    /// while one layout is running. The coordinator must collapse them, not
    /// queue them — and must still finish on the newest.
    func test_aStormOfRequestsCollapsesToOneLayoutAtATimeAndEndsOnTheNewest() async {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .background)

        for revision in 1...50 {
            coordinator.request(
                tree: tree(seed: Int64(revision)),
                viewport: TreemapSize(width: 500 + Double(revision), height: 390),
                revision: revision
            )
        }
        await coordinator.settle()

        XCTAssertEqual(coordinator.resultRequest?.revision, 50, "the newest request must be the one on screen")
        XCTAssertEqual(coordinator.result?.viewport, TreemapSize(width: 550, height: 390))
        XCTAssertLessThanOrEqual(
            coordinator.layoutCount, 2,
            "fifty requests during one layout must not become fifty layouts"
        )
        XCTAssertGreaterThanOrEqual(coordinator.layoutCount, 1)
    }

    /// The intermediate state the drawing path has to cope with: a result that
    /// is real, but describes an older request than the one outstanding.
    func test_theHeldResultSaysWhichRequestItDescribes() async {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .background)
        coordinator.request(tree: tree(), viewport: viewport, revision: 1)
        await coordinator.settle()

        let wider = TreemapSize(width: 900, height: 390)
        coordinator.request(tree: tree(), viewport: wider, revision: 2)

        XCTAssertEqual(coordinator.resultRequest?.viewport, viewport, "still the geometry for the old size")
        XCTAssertFalse(coordinator.isSettled)

        await coordinator.settle()
        XCTAssertEqual(coordinator.resultRequest?.viewport, wider)
    }

    func test_invalidateDropsTheResultAndNotifies() async {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .background)
        coordinator.request(tree: tree(), viewport: viewport, revision: 1)
        await coordinator.settle()

        var notifications = 0
        coordinator.onResult = { notifications += 1 }
        coordinator.invalidate()

        XCTAssertNil(coordinator.result)
        XCTAssertNil(coordinator.resultRequest)
        XCTAssertEqual(notifications, 1)
        coordinator.invalidate()
        XCTAssertEqual(notifications, 1, "invalidating nothing notifies nobody")
    }

    func test_settleReturnsImmediatelyWhenThereIsNothingOutstanding() async {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .background)
        await coordinator.settle()
        XCTAssertTrue(coordinator.isSettled)
        XCTAssertEqual(coordinator.layoutCount, 0)
    }

    /// The instrument the performance suite records against: the coordinator
    /// times its own layouts, so a caller measuring from outside cannot
    /// accidentally time the wait instead of the work.
    func test_theCoordinatorRecordsWhatItsLayoutsCost() async {
        let coordinator = TreemapLayoutCoordinator<TreemapTree>(execution: .background)
        coordinator.request(tree: tree(), viewport: viewport, revision: 1)
        await coordinator.settle()

        XCTAssertGreaterThan(coordinator.lastLayoutSeconds, 0)
        XCTAssertEqual(coordinator.maximumLayoutSeconds, coordinator.lastLayoutSeconds)
        XCTAssertLessThan(coordinator.lastLayoutSeconds, 5, "a 200-entry fixture is not a five-second layout")
    }
}
