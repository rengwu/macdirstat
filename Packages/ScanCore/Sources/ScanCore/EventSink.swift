import Foundation

/// The buffer between the traversal and the `AsyncStream` the UI iterates.
///
/// **Buffering-newest, without losing the events that carry the contract.**
/// A slow consumer must not build an unbounded backlog of stale snapshots
/// (spec §5.5), but `.started` and the terminal event are the contract itself
/// and may never be dropped. So this sink queues `.progress` and `.tree` as
/// *slots*: a slot holds one value and keeps its place in the queue, and
/// re-emitting overwrites that value in place. A consumer that looks away for
/// a second comes back to the newest snapshot, exactly once, in the position
/// the first superseded one held — while `.started` and `.finished`/`.failed`
/// queue normally and always arrive.
///
/// `emit` is synchronous and never blocks the traversal; `next()` is the
/// pull side of `AsyncStream(unfolding:)`.
final class EventSink: @unchecked Sendable {
    private enum Slot {
        case reliable(ScanEvent)
        case progress
        case tree
    }

    private let lock = NSLock()
    private var queue: [Slot] = []
    private var pendingProgress: ProgressSnapshot?
    private var pendingTree: TreeSnapshot?
    private var progressQueued = false
    private var treeQueued = false
    private var producerFinished = false
    private var waiter: CheckedContinuation<ScanEvent?, Never>?

    func emit(_ event: ScanEvent) {
        lock.lock()
        if producerFinished {
            lock.unlock()
            return
        }

        switch event {
        case .progress(let snapshot):
            pendingProgress = snapshot
            if !progressQueued {
                progressQueued = true
                queue.append(.progress)
            }
        case .tree(let snapshot):
            pendingTree = snapshot
            if !treeQueued {
                treeQueued = true
                queue.append(.tree)
            }
        case .started, .finished, .failed:
            queue.append(.reliable(event))
            if event.isTerminal {
                producerFinished = true
            }
        }

        handOffLocked()
    }

    /// Ends the stream. Anything already queued is still delivered first.
    func finish() {
        lock.lock()
        producerFinished = true
        handOffLocked()
    }

    func next() async -> ScanEvent? {
        // The lock is only ever taken from synchronous helpers: a lock held
        // across a suspension point is a deadlock waiting for a slow day.
        switch takeNext() {
        case .event(let event): return event
        case .ended: return nil
        case .empty: break
        }
        return await withCheckedContinuation { continuation in
            park(continuation)
        }
    }

    private enum Pull {
        case event(ScanEvent)
        case ended
        case empty
    }

    private func takeNext() -> Pull {
        lock.lock()
        if let event = dequeueLocked() {
            lock.unlock()
            return .event(event)
        }
        let ended = producerFinished
        lock.unlock()
        return ended ? .ended : .empty
    }

    /// Stores the consumer's continuation, unless something arrived in the
    /// window between `takeNext()` and here.
    private func park(_ continuation: CheckedContinuation<ScanEvent?, Never>) {
        lock.lock()
        if let event = dequeueLocked() {
            lock.unlock()
            continuation.resume(returning: event)
            return
        }
        if producerFinished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        waiter = continuation
        lock.unlock()
    }

    // MARK: - Locked helpers

    /// Resumes a waiting consumer, if there is one and something to give it.
    /// Always unlocks. Resumption happens outside the lock.
    private func handOffLocked() {
        guard let continuation = waiter else {
            lock.unlock()
            return
        }
        if let event = dequeueLocked() {
            waiter = nil
            lock.unlock()
            continuation.resume(returning: event)
        } else if producerFinished {
            waiter = nil
            lock.unlock()
            continuation.resume(returning: nil)
        } else {
            lock.unlock()
        }
    }

    private func dequeueLocked() -> ScanEvent? {
        while !queue.isEmpty {
            let slot = queue.removeFirst()
            switch slot {
            case .reliable(let event):
                return event
            case .progress:
                progressQueued = false
                if let snapshot = pendingProgress {
                    pendingProgress = nil
                    return .progress(snapshot)
                }
            case .tree:
                treeQueued = false
                if let snapshot = pendingTree {
                    pendingTree = nil
                    return .tree(snapshot)
                }
            }
        }
        return nil
    }
}
