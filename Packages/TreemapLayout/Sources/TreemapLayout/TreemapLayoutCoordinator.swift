import Foundation

/// Where a layout runs.
public enum TreemapLayoutExecution: Sendable, Equatable {
    /// Off the main thread, one at a time, newest request wins. The production
    /// setting: a layout must never be able to block the window, however large
    /// the tree grows (spec §6.4, ticket 14).
    case background
    /// Inline, on the calling thread, before ``TreemapLayoutCoordinator/request(tree:viewport:revision:)``
    /// returns. For callers that need the result in the same turn — tests that
    /// assert on geometry, and offscreen rendering — where the whole point is
    /// that there is nothing to wait for.
    case immediate
}

/// Keeps one draw list current for a tree that keeps changing, without ever
/// computing it on the main thread.
///
/// The view cannot simply lay out inside `draw(_:)`: at volume scale that is a
/// multi-second walk on the main thread, and a scan republishes its tree
/// several times a second. So layout is a *request*, the result arrives later,
/// and the view redraws when it does.
///
/// **One at a time, newest wins.** A request that arrives while a layout is
/// running does not start a second one — it replaces what runs next. During a
/// live resize that means the coordinator lags by at most one layout instead of
/// queueing dozens, and it never occupies more than one core. The running
/// layout is always allowed to finish rather than being abandoned: it is a
/// synchronous, allocation-light walk with nowhere to check for cancellation,
/// and its result is still a better picture than none.
///
/// The coordinator owns *when*, never *what*: the geometry is
/// ``TreemapLayout/layout(tree:viewport:budget:)``'s, unchanged and identical
/// on either execution setting.
@MainActor
public final class TreemapLayoutCoordinator<Node: TreemapInputNode & Sendable> {
    /// What a caller asked to see. Two requests are the same request when the
    /// tree revision and the viewport are the same — that is the whole of the
    /// cache key, and `revision` is the caller's to define (an identity, a
    /// generation counter, or both mixed together).
    public struct Request: Equatable, Sendable {
        public var revision: Int
        public var viewport: TreemapSize

        public init(revision: Int, viewport: TreemapSize) {
            self.revision = revision
            self.viewport = viewport
        }
    }

    public let execution: TreemapLayoutExecution

    /// The cap every layout this coordinator runs is computed under
    /// (``TreemapLayoutBudget``). Fixed for the coordinator's lifetime, so it
    /// is not part of ``Request``: changing it means a new coordinator and a
    /// fresh draw list, which is what the view does.
    public let budget: TreemapLayoutBudget

    /// The most recent draw list, which may describe an older request than the
    /// one currently outstanding. ``resultRequest`` says which.
    public private(set) var result: TreemapLayoutResult<Node>?
    public private(set) var resultRequest: Request?

    /// Called on the main actor whenever ``result`` changes.
    public var onResult: (() -> Void)?

    /// Diagnostics, so a caller can record what layout costs without timing it
    /// from outside and catching the wrong thing.
    public private(set) var layoutCount = 0
    public private(set) var lastLayoutSeconds: TimeInterval = 0
    public private(set) var maximumLayoutSeconds: TimeInterval = 0

    private var inFlight: Request?
    private var pending: (tree: Node, request: Request)?
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        execution: TreemapLayoutExecution = .background,
        budget: TreemapLayoutBudget = .unbounded
    ) {
        self.execution = execution
        self.budget = budget
    }

    /// Whether the held result is the one that was last asked for.
    public var isSettled: Bool { inFlight == nil && pending == nil }

    /// Asks for `tree` laid out in `viewport`. Cheap and idempotent: asking
    /// again for what is already held, or already running, does nothing.
    public func request(tree: Node, viewport: TreemapSize, revision: Int) {
        let request = Request(revision: revision, viewport: viewport)
        guard resultRequest != request else { return }

        switch execution {
        case .immediate:
            adopt(compute(tree: tree, request: request), for: request)
        case .background:
            guard inFlight != request else { return }
            pending = (tree, request)
            if inFlight == nil { startPending() }
        }
    }

    /// Forgets the held draw list — there is nothing to show. Any layout
    /// already running still lands; it is simply for a request nobody wants,
    /// and the next `request` supersedes it.
    public func invalidate() {
        guard result != nil || resultRequest != nil else { return }
        result = nil
        resultRequest = nil
        onResult?()
    }

    /// Waits until nothing is outstanding. For tests and for a caller that
    /// needs the settled geometry — never on a drawing path.
    public func settle() async {
        guard !isSettled else { return }
        await withCheckedContinuation { continuation in
            settleWaiters.append(continuation)
        }
    }

    // MARK: - Running

    private func startPending() {
        guard let (tree, request) = pending else { return }
        pending = nil
        inFlight = request
        // Copied out so the detached task captures a value, not the actor.
        let budget = self.budget
        Task.detached(priority: .userInitiated) { [weak self] in
            let began = ProcessInfo.processInfo.systemUptime
            let computed = TreemapLayout.layout(tree: tree, viewport: request.viewport, budget: budget)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            await self?.finish(computed, for: request, seconds: elapsed)
        }
    }

    private func finish(_ computed: TreemapLayoutResult<Node>, for request: Request, seconds: TimeInterval) {
        inFlight = nil
        record(seconds: seconds)
        adopt(computed, for: request)
        if pending != nil {
            startPending()
        } else {
            let waiters = settleWaiters
            settleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    private func compute(tree: Node, request: Request) -> TreemapLayoutResult<Node> {
        let began = ProcessInfo.processInfo.systemUptime
        let computed = TreemapLayout.layout(tree: tree, viewport: request.viewport, budget: budget)
        record(seconds: ProcessInfo.processInfo.systemUptime - began)
        return computed
    }

    private func record(seconds: TimeInterval) {
        layoutCount += 1
        lastLayoutSeconds = seconds
        maximumLayoutSeconds = max(maximumLayoutSeconds, seconds)
    }

    private func adopt(_ computed: TreemapLayoutResult<Node>, for request: Request) {
        result = computed
        resultRequest = request
        onResult?()
    }
}
