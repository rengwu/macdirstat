import Foundation

/// A cancellation flag that can be tripped **synchronously**, from anywhere.
///
/// Swift `Task` cancellation is the primary mechanism (spec §5.6) and is
/// honoured as well, but the UI's Cancel button must not have to hop to an
/// actor and then hope: it wants the traversal to observe the request at its
/// very next checkpoint, and it wants to keep consuming the stream afterwards
/// so it receives the partial result. A tripped flag stays tripped, matching
/// `Task.isCancelled`.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Holds the token of whichever scan is current, so `Scanner.cancel()` can be
/// `nonisolated` and therefore synchronous.
final class CancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CancellationToken?

    func set(_ token: CancellationToken?) {
        lock.lock()
        current = token
        lock.unlock()
    }

    func cancelCurrent() {
        lock.lock()
        let token = current
        lock.unlock()
        token?.cancel()
    }
}

/// A security-scoped access claim that is released **exactly once** — on
/// success, on failure, on cancellation, and on replacement (spec §5.6, §10).
///
/// The traversal's `defer` and the task-cancellation handler both call
/// `release()`; the flag makes the second call a no-op.
final class AccessScope: @unchecked Sendable {
    private let url: URL
    private let access: SecurityScopedAccess
    private let lock = NSLock()
    /// Whether a scope was actually started, and so whether a stop is owed —
    /// an ordinary local URL needs none.
    private var owed: Bool

    init(url: URL, access: SecurityScopedAccess) {
        self.url = url
        self.access = access
        self.owed = access.startAccessing(url)
    }

    func release() {
        lock.lock()
        let shouldStop = owed
        owed = false
        lock.unlock()
        if shouldStop {
            access.stopAccessing(url)
        }
    }
}
