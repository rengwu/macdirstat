import Foundation

/// The buffer between the traversal and the `AsyncStream` the UI iterates.
///
/// **Newest progress wins; the rest always arrives.** A slow consumer must not
/// build a backlog of stale progress snapshots, but `.started` and the terminal
/// event are the contract itself and may never be dropped. So `.progress` is
/// queued as a *slot*: it holds one value and keeps its place in the queue, and
/// re-emitting overwrites that value in place. A consumer that looks away for a
/// second comes back to the newest reading, exactly once, in the position the
/// first superseded one held.
///
/// `emit` is synchronous and never blocks the traversal; `next()` is the
/// pull side of `AsyncStream(unfolding:)`.
final class EventSink: @unchecked Sendable {
    private enum Slot {
        case reliable(ScanEvent)
        case progress
    }

    private let lock = NSLock()
    private var queue: [Slot] = []
    private var pendingProgress: ProgressSnapshot?
    private var progressQueued = false
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
        case .started, .finished, .failed:
            queue.append(.reliable(event))
        }

        handOffLocked()
    }

    /// Ends the stream. Anything already queued is still delivered first.
    ///
    /// A terminal event does not end the stream by itself. `ScanSession` emits
    /// that event, releases security-scoped access, and only then calls this
    /// method. Ending on emission let a fast consumer observe end-of-stream
    /// before that cleanup had happened.
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
            }
        }
        return nil
    }
}
