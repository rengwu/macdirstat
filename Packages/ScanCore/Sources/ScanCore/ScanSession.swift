import Foundation

/// One scan, start to terminal event.
///
/// A session is created inside the scan's own task and never escapes it, so
/// the mutable tree, the counters and the accumulators have exactly one
/// writer — the property spec §5.2 asks for, obtained by confinement rather
/// than by locking the hot path.
///
/// The traversal is **serial, iterative, depth-first** over an explicit stack
/// (spec §5.4). Serial because hard-link "first path" ownership is only
/// well-defined under a deterministic order, because it keeps every lock off
/// the hot path, and because a scan is confined to one device anyway.
/// Iterative because a filesystem's depth is the user's to choose, not ours to
/// survive on the call stack.
final class ScanSession {
    /// One open directory: its node, its URL, its listing, and how far through
    /// that listing we are.
    private struct Frame {
        let node: ScanNode
        let url: URL
        var entries: [EntryMeta] = []
        var cursor: Int = 0
        var listed: Bool = false
    }

    private let request: ScanRequest
    private let sink: EventSink
    private let token: CancellationToken
    private let probe: DirectoryProbe
    private let clock: ScanClock
    private let batchSize: Int

    private let root: ScanNode
    private var rootVolume: FileSystemIdentity?
    private var volumeCapacity: VolumeCapacity?

    private var filesSeen: Int64 = 0
    private var directoriesSeen: Int64 = 0
    private var unreadableEntries: Int = 0
    private var currentPathTail: String = ""

    private var startedAt: TimeInterval = 0
    private var lastProgressEmit: TimeInterval = -.infinity
    private var lastTreeEmit: TimeInterval = -.infinity
    private var progressSequence: UInt64 = 0
    private var treeGeneration: UInt64 = 0
    private var treeDirty = false
    private var entriesSinceClockRead = 0
    private var entriesSinceCancellationCheck = 0

    /// How often the clock is consulted when a cadence is time-based. Reading
    /// the clock per entry would put a syscall in the hot path for a decision
    /// that can only change every 66 ms.
    private static let clockReadInterval = 64

    init(request: ScanRequest, sink: EventSink, token: CancellationToken) {
        self.request = request
        self.sink = sink
        self.token = token
        self.probe = request.probe
        self.clock = request.options.clock
        self.batchSize = request.options.cancellationBatchSize
        self.root = ScanNode(name: request.root.lastPathComponent, kind: .directory, parent: nil)
    }

    // MARK: - Lifecycle

    func run() async {
        let scope = AccessScope(url: request.root, access: request.access)
        await withTaskCancellationHandler {
            runToTerminalEvent()
        } onCancel: {
            // Fires the instant the task is cancelled, even mid-listing, so the
            // claim is never held past the scan (spec §5.6).
            token.cancel()
            scope.release()
        }
        scope.release()
        sink.finish()
    }

    private func runToTerminalEvent() {
        startedAt = clock.now

        do {
            try preflight()
        } catch {
            sink.emit(.failed(Self.preflightFailure(for: error, url: request.root)))
            return
        }

        sink.emit(.started(root: request.root, mode: request.mode, volumeCapacity: volumeCapacity))
        emitIfDue()

        let stoppedEarly = traverse()

        emitFinalSnapshots()
        sink.emit(.finished(ScanResult(
            // Cancellation is terminal: once requested, a scan never reports
            // `.completed` (spec §5.6). Whether the *data* is short is a
            // separate question — a cancel that lands after the last directory
            // was read still leaves an exact tree.
            reason: (stoppedEarly || isCancellationRequested) ? .cancelled : .completed,
            root: root,
            completeness: completeness(stoppedEarly: stoppedEarly),
            volumeCapacity: volumeCapacity,
            elapsed: max(0, clock.now - startedAt)
        )))
    }

    // MARK: - Pre-flight

    /// The root-eligibility predicate (spec §3.3). This is the **only** place
    /// a scan can fail: once traversal starts, every filesystem problem is
    /// recorded and the scan carries on (spec §5.3).
    private func preflight() throws {
        let meta = try probe.metadata(of: request.root)

        guard !meta.isSymbolicLink, meta.isDirectory else {
            throw ScanFailure.rootNotDirectory(request.root)
        }

        let info = try probe.volumeInfo(for: request.root)
        guard info.isLocal else {
            // `volumeIsLocalKey == false` is precisely "network-mounted".
            throw ScanFailure.rootOnNetworkVolume(request.root)
        }

        rootVolume = meta.volumeIdentifier
        volumeCapacity = request.mode == .volumeRoot ? info.capacity : nil
        directoriesSeen = 1
    }

    private static func preflightFailure(for error: Error, url: URL) -> ScanFailure {
        if let failure = error as? ScanFailure { return failure }
        let nsError = error as NSError
        let missing =
            (nsError.domain == NSCocoaErrorDomain
                && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError))
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
        return missing ? .rootMissing(url) : .rootAccessDenied(url)
    }

    // MARK: - Traversal

    /// Returns `true` if the scan stopped because cancellation was requested.
    private func traverse() -> Bool {
        var stack: [Frame] = [Frame(node: root, url: request.root)]

        while !stack.isEmpty {
            // Checkpoint A — once per directory.
            if isCancellationRequested {
                stopAtCancellation(stack)
                return true
            }

            let top = stack.count - 1

            if !stack[top].listed {
                currentPathTail = Self.pathTail(of: stack[top].url)
                do {
                    var entries = try probe.list(stack[top].url)
                    // Deterministic order, and locale-independent so two
                    // machines agree: identical trees must produce identical
                    // node order and identical hard-link ownership.
                    entries.sort { $0.name < $1.name }
                    stack[top].entries = entries
                    stack[top].listed = true
                    treeDirty = true
                    emitIfDue()
                } catch {
                    // A directory we cannot read is a recoverable problem, not
                    // a failed scan: mark it, mark its ancestors, carry on.
                    recordUnreadable(stack[top].node)
                    stack[top].node.freeze()
                    stack.removeLast()
                    treeDirty = true
                    emitIfDue()
                    continue
                }
            }

            var descended = false
            while stack[top].cursor < stack[top].entries.count {
                let meta = stack[top].entries[stack[top].cursor]
                stack[top].cursor += 1
                entriesSinceCancellationCheck += 1

                let kind = Self.kind(of: meta)
                let node = ScanNode(name: meta.name, kind: kind, parent: stack[top].node)
                stack[top].node.appendChild(node)
                treeDirty = true

                if kind == .directory || kind == .package {
                    directoriesSeen += 1
                    if isOnRootVolume(meta) {
                        stack.append(Frame(
                            node: node,
                            url: stack[top].url.appendingPathComponent(meta.name)
                        ))
                        descended = true
                        throttledEmit()
                        // Depth-first: the child is processed before this
                        // directory's remaining entries.
                        break
                    }
                    // A different volume: the entry stays visible, but nothing
                    // beneath it is ever listed (spec §3.3, §5.4).
                    node.freeze()
                } else {
                    attribute(node, meta)
                }

                // Checkpoint B — after every batch of entries, so one enormous
                // directory is no less cancellable than a deep one.
                if entriesSinceCancellationCheck >= batchSize {
                    entriesSinceCancellationCheck = 0
                    if isCancellationRequested {
                        stopAtCancellation(stack)
                        return true
                    }
                }
                throttledEmit()
            }

            if descended { continue }

            stack[top].node.freeze()
            stack.removeLast()
            treeDirty = true
            emitIfDue()
        }

        return false
    }

    /// Everything still open when cancellation lands is Incomplete — its total
    /// is a floor, not a figure — and everything discovered is kept
    /// (spec §3.5, §5.6).
    private func stopAtCancellation(_ stack: [Frame]) {
        for frame in stack {
            frame.node.markIncomplete()
            frame.node.freeze()
        }
    }

    // MARK: - Attribution

    private func attribute(_ node: ScanNode, _ meta: EntryMeta) {
        let isRegularFile = node.kind == .file
        if isRegularFile { filesSeen += 1 }

        var bytes: Int64 = 0
        if isRegularFile {
            if let size = meta.fileSize {
                bytes = max(0, size)
            } else {
                // A size we could not read is never guessed (spec §3.5).
                recordUnreadable(node)
            }
        }

        node.attribute(ownBytes: bytes, isRegularFile: isRegularFile)
        node.freeze()

        guard bytes > 0 || isRegularFile else { return }
        // Roll up to every ancestor, so each open directory's total is live at
        // every instant (spec §3.1).
        var ancestor = node.parent
        while let current = ancestor {
            current.accumulate(bytes: bytes, files: isRegularFile ? 1 : 0)
            ancestor = current.parent
        }
    }

    private func recordUnreadable(_ node: ScanNode) {
        node.markUnreadable()
        unreadableEntries += 1
        var ancestor = node.parent
        while let current = ancestor {
            current.markIncomplete()
            ancestor = current.parent
        }
    }

    private static func kind(of meta: EntryMeta) -> NodeKind {
        // Symlinks first: a link to a directory reports `isDirectory` too, and
        // it must never be descended (spec §3.4).
        if meta.isSymbolicLink { return .symbolicLink }
        if meta.isDirectory { return meta.isPackage ? .package : .directory }
        if meta.isRegularFile { return .file }
        return .other
    }

    /// The device boundary (spec §3.3). An identifier we could not read is not
    /// evidence of a different device, and omitting real bytes is the worse
    /// error, so an unknown identifier descends.
    private func isOnRootVolume(_ meta: EntryMeta) -> Bool {
        guard let rootVolume = rootVolume, let volume = meta.volumeIdentifier else { return true }
        return volume == rootVolume
    }

    // MARK: - Emission

    private var isCancellationRequested: Bool {
        token.isCancelled || Task.isCancelled
    }

    private var emitsOnEveryChange: Bool {
        request.options.progressCadence == .everyChange || request.options.treeCadence == .everyChange
    }

    private func throttledEmit() {
        entriesSinceClockRead += 1
        if !emitsOnEveryChange && entriesSinceClockRead < Self.clockReadInterval { return }
        entriesSinceClockRead = 0
        emitIfDue()
    }

    private func emitIfDue() {
        let now = clock.now
        if Self.isDue(request.options.progressCadence, last: lastProgressEmit, now: now) {
            lastProgressEmit = now
            sink.emit(.progress(makeProgress(now: now)))
        }
        if treeDirty, Self.isDue(request.options.treeCadence, last: lastTreeEmit, now: now) {
            lastTreeEmit = now
            treeDirty = false
            sink.emit(.tree(makeTree()))
        }
    }

    /// The last frame the UI draws is always exact, whatever the cadence
    /// (spec §5.5).
    private func emitFinalSnapshots() {
        let now = clock.now
        lastProgressEmit = now
        lastTreeEmit = now
        treeDirty = false
        currentPathTail = ""
        sink.emit(.progress(makeProgress(now: now)))
        sink.emit(.tree(makeTree()))
    }

    private static func isDue(_ cadence: EmissionCadence, last: TimeInterval, now: TimeInterval) -> Bool {
        switch cadence {
        case .everyChange: return true
        case .terminalOnly: return false
        case .minimumInterval(let interval): return now - last >= interval
        }
    }

    private func makeProgress(now: TimeInterval) -> ProgressSnapshot {
        progressSequence += 1
        let elapsed = max(0, now - startedAt)
        let bytes = root.subtreeBytes
        return ProgressSnapshot(
            attributedBytes: bytes,
            filesSeen: filesSeen,
            directoriesSeen: directoriesSeen,
            currentPathTail: currentPathTail,
            elapsed: elapsed,
            bytesPerSecond: elapsed > 0 ? Double(bytes) / elapsed : 0,
            approximateFraction: approximateFraction(attributedBytes: bytes),
            sequence: progressSequence
        )
    }

    /// Volume scans only, and explicitly approximate: logical content bytes are
    /// not physical used bytes, so this is a reassurance bar, never a promise.
    /// A folder scan has nothing honest to divide by (spec §5.5).
    private func approximateFraction(attributedBytes: Int64) -> Double? {
        guard request.mode == .volumeRoot,
              let capacity = volumeCapacity,
              capacity.usedBytes > 0
        else { return nil }
        return min(Double(attributedBytes) / Double(capacity.usedBytes), 1.0)
    }

    private func makeTree() -> TreeSnapshot {
        treeGeneration += 1
        return TreeSnapshot(
            root: root.frozenSnapshot(parent: nil),
            liveTree: root,
            generation: treeGeneration
        )
    }

    private func completeness(stoppedEarly: Bool) -> Completeness {
        if stoppedEarly || unreadableEntries > 0 {
            return .incomplete(cancelled: stoppedEarly, unreadableEntries: unreadableEntries)
        }
        return .exact
    }

    private static func pathTail(of url: URL) -> String {
        url.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/")
    }
}
