import Foundation

/// The scan engine's public entry point (spec §5.1).
public protocol Scanning: Sendable {
    /// Starts a scan and returns its event stream.
    ///
    /// Cancel either by cancelling the task that iterates the stream, or —
    /// when the partial result is wanted, which is the UI's case — by calling
    /// `cancel()` and continuing to iterate until `.finished(.cancelled)`.
    func scan(_ request: ScanRequest) async -> AsyncStream<ScanEvent>

    /// Requests cancellation of the current scan. Synchronous and idempotent.
    func cancel()
}

/// The scan engine.
///
/// One scan at a time (spec §5.3): starting a replacement cancels the current
/// scan and begins only after that scan has emitted its terminal
/// `.finished(.cancelled)`, so the two never contend on the device and the
/// replaced stream still delivers its partial result.
///
/// The traversal itself runs on a detached task, not on this actor's executor:
/// it is a long synchronous run of Foundation file I/O (spec §4.3 — the async
/// file APIs are macOS 12+, above the floor), and parking that on the actor
/// would make every `scan`/`cancel` call queue behind it.
public actor Scanner: Scanning {
    private let registry = CancellationRegistry()
    private var active: Task<Void, Never>?

    public init() {}

    public func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
        let previous = active
        previous?.cancel()
        registry.cancelCurrent()

        let token = CancellationToken()
        registry.set(token)

        let sink = EventSink()
        let task = Task.detached(priority: .utility) {
            // Begin only once the replaced scan has emitted its terminal event.
            await previous?.value
            if Task.isCancelled { token.cancel() }
            let session = ScanSession(request: request, sink: sink, token: token)
            await session.run()
        }
        active = task

        return AsyncStream(
            unfolding: { await sink.next() },
            onCancel: {
                token.cancel()
                task.cancel()
            }
        )
    }

    public nonisolated func cancel() {
        registry.cancelCurrent()
    }
}
