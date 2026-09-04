import Foundation

/// One directory listing being produced off the traversal thread.
///
/// The scanner is its only consumer. Completion can arrive on any worker, so
/// the condition protects the single result and lets the deterministic walk
/// wait only when it catches up with its small read-ahead window.
final class DirectoryListingFuture: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<[EntryMeta], Error>?
    private var discarded = false
    private var released = false
    private let releaseSlot: @Sendable () -> Void

    init(releaseSlot: @escaping @Sendable () -> Void) {
        self.releaseSlot = releaseSlot
    }

    func complete(_ result: Result<[EntryMeta], Error>) {
        condition.lock()
        if !discarded { self.result = result }
        condition.broadcast()
        condition.unlock()
    }

    func take() throws -> [EntryMeta] {
        condition.lock()
        while result == nil, !discarded { condition.wait() }
        let completed = result
        result = nil
        discarded = true
        let shouldRelease = markReleasedLocked()
        condition.unlock()
        if shouldRelease { releaseSlot() }
        guard let completed else { throw CancellationError() }
        return try completed.get()
    }

    /// Drops a speculative result whose directory was found to be a repeated
    /// identity before it was opened. A worker already inside FileManager may
    /// finish, but its potentially large array is never retained.
    func discard() {
        condition.lock()
        discarded = true
        result = nil
        condition.broadcast()
        let shouldRelease = markReleasedLocked()
        condition.unlock()
        if shouldRelease { releaseSlot() }
    }

    private func markReleasedLocked() -> Bool {
        guard !released else { return false }
        released = true
        return true
    }
}

/// A per-scan, capacity-bounded read-ahead queue.
///
/// A slot remains occupied until the traversal consumes (or discards) the
/// result, not merely until I/O finishes. That distinction bounds completed
/// listing memory as well as concurrent syscalls.
final class DirectoryListingPrefetcher: @unchecked Sendable {
    private let probe: DirectoryProbe
    private let queue: OperationQueue
    private let lock = NSLock()
    private let capacity: Int
    private var occupied = 0

    init(probe: DirectoryProbe, capacity: Int) {
        self.probe = probe
        self.capacity = max(1, capacity)
        self.queue = OperationQueue()
        queue.name = "MacDirStat directory listing prefetch"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = self.capacity
    }

    func schedule(_ url: URL) -> DirectoryListingFuture? {
        lock.lock()
        guard occupied < capacity else {
            lock.unlock()
            return nil
        }
        occupied += 1
        lock.unlock()

        let future = DirectoryListingFuture { [weak self] in self?.release() }
        queue.addOperation { [probe] in
            future.complete(Result { try probe.list(url) })
        }
        return future
    }

    func cancelAndWait() {
        queue.cancelAllOperations()
        queue.waitUntilAllOperationsAreFinished()
    }

    private func release() {
        lock.lock()
        occupied = max(0, occupied - 1)
        lock.unlock()
    }
}
