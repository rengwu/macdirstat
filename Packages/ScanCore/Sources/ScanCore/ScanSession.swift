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
        /// `fileResourceIdentifierKey`, carried from the parent's listing so
        /// the visited-directory check can be made when this frame is actually
        /// opened rather than when it was met (spec §3.3). A frame that is held
        /// back must take its verdict at its real arrival, not at its
        /// discovery.
        var identity: FileSystemIdentity?
        /// A filesystem mounted inside the root's own volume. Never offered to
        /// the visited-directory index: two volume roots may share an inode
        /// number, and skipping one would lose everything only it can reach.
        var isMountPoint: Bool = false
        var entries: [EntryMeta] = []
        var cursor: Int = 0
        var listed: Bool = false
        /// Hidden subdirectories, opened after this directory's visible ones.
        /// See ``ScanSession/traverse()``.
        var pendingHidden: [Frame] = []
    }

    private let request: ScanRequest
    private let sink: EventSink
    private let token: CancellationToken
    private let probe: DirectoryProbe
    private let clock: ScanClock
    private let batchSize: Int

    private let root: ScanNode
    private var rootVolume: FileSystemIdentity?
    private var rootIdentity: FileSystemIdentity?
    private var volumeCapacity: VolumeCapacity?

    /// Populated at pre-flight, once the volume's hard-link support is known.
    private var hardLinks = HardLinkIndex(isEnabled: false)
    /// Every directory this scan has descended, by filesystem identity, so a
    /// directory reachable at two paths is walked once (spec §3.3).
    private var visitedDirectories: VisitedDirectoryIndex
    /// Where filesystems are mounted, read once at pre-flight. An ordering
    /// hint, not a boundary: see ``DirectoryProbe/mountPointPaths()``.
    private var mountPointPaths: Set<String> = []
    private var diagnostics: ScanDiagnostics

    private var filesSeen: Int64 = 0
    private var directoriesSeen: Int64 = 0
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
        self.diagnostics = ScanDiagnostics(detailLimit: request.options.maxDetailedErrors)
        self.visitedDirectories = VisitedDirectoryIndex(
            isEnabled: request.options.deduplicatesRepeatedDirectories
        )
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
            errors: diagnostics.errors,
            exclusions: diagnostics.exclusions,
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
        // Capacity and free space are volume facts carried alongside the tree,
        // never folded into an attributed byte count (spec §3.5).
        volumeCapacity = request.mode == .volumeRoot ? info.capacity : nil
        // Where the volume cannot hold a hard link, the identity index and its
        // per-entry bookkeeping are skipped entirely (spec §3.4).
        hardLinks = HardLinkIndex(isEnabled: info.supportsHardLinks)
        // The root is the first directory opened, so it is the first identity
        // in the visited index: a graft that points back at the scan root is
        // re-entry like any other (spec §3.3).
        rootIdentity = meta.fileIdentity
        // One call for the whole scan. The scan root's own path is dropped:
        // it is where the walk starts, not something it could descend twice.
        mountPointPaths = probe.mountPointPaths()
        mountPointPaths.remove(request.root.path)
        directoriesSeen = 1
    }

    private static func preflightFailure(for error: Error, url: URL) -> ScanFailure {
        if let failure = error as? ScanFailure { return failure }
        return isMissing(error) ? .rootMissing(url) : .rootAccessDenied(url)
    }

    // MARK: - Traversal

    /// Returns `true` if the scan stopped because cancellation was requested.
    ///
    /// **Two paths to one directory: which one keeps it.** A directory the walk
    /// has already opened is never opened again (spec §3.3), so when the same
    /// directory is reachable twice the *first* path to it keeps its bytes and
    /// the second stays visible and weightless. Arrival order is therefore a
    /// presentation decision, and the walk makes two of them, both aimed at
    /// leaving the bytes on the path a person recognises:
    ///
    /// - **A mount point inside the root's own volume is opened last of all.**
    ///   `/System/Volumes/Data` is the data volume's own root, holding the
    ///   firmlinked names already reachable from `/` beside entries that live
    ///   nowhere else; walking it last leaves `/Users` owning `/Users`.
    /// - **A hidden subdirectory is opened after its visible siblings.** macOS
    ///   hangs synthetic aliases of the whole filesystem off the volume root —
    ///   `/.nofollow` lists the same top level as `/`, and sorts before every
    ///   real name in it — so without this the entire disk is attributed to a
    ///   directory no user has heard of.
    ///
    /// Neither changes what is counted, or how many times; both change only
    /// which of two paths to one directory is the one that carries it.
    private func traverse() -> Bool {
        var stack: [Frame] = [Frame(node: root, url: request.root, identity: rootIdentity)]
        // Mount points, held back until the ordinary walk has finished.
        var deferredMounts: [Frame] = []

        while !stack.isEmpty || !deferredMounts.isEmpty {
            if stack.isEmpty {
                // The ordinary tree is finished; now the mount points, in the
                // order they were met.
                stack.append(deferredMounts.removeFirst())
            }

            // Checkpoint A — once per directory.
            if isCancellationRequested {
                stopAtCancellation(openFrames(stack, deferredMounts))
                return true
            }

            let top = stack.count - 1

            // The visited-directory check, made as this directory is opened.
            if !stack[top].listed, !stack[top].isMountPoint,
               case .repeatVisit(let owner) = visitedDirectories.claim(stack[top].identity,
                                                                      for: stack[top].node) {
                // A second path to a directory already walked — the firmlink
                // graft under `/System/Volumes/Data` is the case every Mac has.
                // Its bytes were counted at the first path, so this name stays
                // visible and weightless, pointing at the owner, exactly as a
                // second name for a hard-linked inode does. Nothing went wrong,
                // so it is an exclusion and its ancestors stay Complete.
                diagnostics.exclude(.repeatedDirectory)
                stack[top].node.markDirectoryCountedElsewhere(owner: owner.pathComponents())
                stack[top].node.freeze()
                stack.removeLast()
                treeDirty = true
                emitIfDue()
                continue
            }

            if !stack[top].listed {
                currentPathTail = Self.pathTail(of: stack[top].url)
                do {
                    var entries = try probe.list(stack[top].url)
                    // Deterministic order, and locale-independent so two
                    // machines agree: identical trees must produce identical
                    // node order and identical hard-link ownership. Code-point
                    // order rather than `String <`, which would leave two names
                    // differing only in normalization tied and let the
                    // filesystem's listing order decide the owner — see
                    // ``NameOrder``.
                    entries.sort { NameOrder.precedes($0.name, $1.name) }
                    stack[top].entries = entries
                    stack[top].listed = true
                    treeDirty = true
                    emitIfDue()
                } catch {
                    // A directory we cannot read is a recoverable problem, not
                    // a failed scan: mark it, mark its ancestors, carry on. An
                    // entry that was listed with its parent and is gone by the
                    // time we descend is live change, not a permission
                    // problem — the two are counted apart (spec §3.5).
                    recordUnreadable(
                        stack[top].node,
                        category: Self.isMissing(error) ? .disappeared : .unreadableDirectory,
                        error: error
                    )
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

                if meta.cloudDownloadingStatus == .notDownloaded {
                    // A remote-only placeholder: omitted from the tree, counted
                    // as an exclusion, and never touched again — reading or
                    // listing it is what would start a download (spec §3.4).
                    diagnostics.exclude(.remoteOnlyCloud)
                    if batchCheckpointRequestsStop() {
                        stopAtCancellation(openFrames(stack, deferredMounts))
                        return true
                    }
                    throttledEmit()
                    continue
                }

                let kind = Self.kind(of: meta)
                let node = ScanNode(name: meta.name, kind: kind, parent: stack[top].node)
                stack[top].node.appendChild(node)
                treeDirty = true

                if kind == .directory || kind == .package {
                    directoriesSeen += 1
                    let childURL = stack[top].url.appendingPathComponent(meta.name)
                    if !isOnRootVolume(meta) {
                        // A different volume: the entry stays visible, but
                        // nothing beneath it is ever listed (spec §3.3, §5.4).
                        // Nothing went wrong — a policy skipped it — so it is an
                        // exclusion, not an error, and its ancestors stay
                        // Complete.
                        diagnostics.exclude(.crossedVolumeBoundary)
                        node.freeze()
                    } else {
                        let isMountPoint = mountPointPaths.contains(childURL.path)
                        let frame = Frame(
                            node: node,
                            url: childURL,
                            identity: meta.fileIdentity,
                            isMountPoint: isMountPoint
                        )
                        if isMountPoint {
                            deferredMounts.append(frame)
                        } else if Self.isHidden(meta.name) {
                            stack[top].pendingHidden.append(frame)
                        } else {
                            stack.append(frame)
                            descended = true
                            throttledEmit()
                            // Depth-first: the child is processed before this
                            // directory's remaining entries.
                            break
                        }
                    }
                } else {
                    attribute(node, meta)
                }

                if batchCheckpointRequestsStop() {
                    stopAtCancellation(openFrames(stack, deferredMounts))
                    return true
                }
                throttledEmit()
            }

            if descended { continue }

            if !stack[top].pendingHidden.isEmpty {
                // Every visible subdirectory is finished; the hidden ones go on
                // now, in listing order.
                let hidden = stack[top].pendingHidden
                stack[top].pendingHidden = []
                stack.append(contentsOf: hidden.reversed())
                continue
            }

            stack[top].node.freeze()
            stack.removeLast()
            treeDirty = true
            emitIfDue()
        }

        return false
    }

    /// Every directory the walk had started or promised to start: the open
    /// path, the hidden subdirectories waiting behind their visible siblings,
    /// and the mount points held back for the end.
    private func openFrames(_ stack: [Frame], _ deferredMounts: [Frame]) -> [Frame] {
        stack + stack.flatMap(\.pendingHidden) + deferredMounts
    }

    /// A dot-named entry. Hidden subdirectories are opened after their visible
    /// siblings, so a synthetic alias of the whole filesystem — `/.nofollow`,
    /// which sorts before every real name at the volume root — cannot take the
    /// bytes off the paths a person recognises (spec §3.3).
    private static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".")
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
                if case .duplicate(let owner) = hardLinks.claim(meta, for: node) {
                    // Another in-scope name reached this inode first and
                    // already counted its bytes. This name stays visible and
                    // weightless, with the owner's path so the UI can say
                    // where the bytes went (spec §3.4).
                    bytes = 0
                    node.markHardLinkElsewhere(owner: owner.pathComponents())
                }
            } else {
                // A size we could not read is never guessed (spec §3.5) — and
                // an entry with no size never enters the identity index, since
                // owning an inode whose length is unknown would zero out a
                // later name that *could* be read.
                recordUnreadable(node, category: .unreadableEntry, error: nil)
            }
        }

        node.attribute(ownBytes: bytes, isRegularFile: isRegularFile)
        node.freeze()

        guard bytes > 0 || isRegularFile else { return }
        // Roll up to every ancestor, so each open directory's total is live at
        // every instant (spec §3.1). A deduplicated name rolls up zero bytes —
        // it is still one entry, just not a second copy of the bytes.
        //
        // The attributed-entry count rides the same walk. It starts at this
        // leaf, if it has bytes at all, and grows by one each time a directory
        // on the chain becomes attributed for the first time: that directory is
        // a new attributed entry for everything above it, as well as for
        // itself.
        var newlyAttributed = bytes > 0 ? 1 : 0
        var ancestor = node.parent
        while let current = ancestor {
            if current.accumulate(bytes: bytes, files: isRegularFile ? 1 : 0, attributedNodes: newlyAttributed) {
                newlyAttributed += 1
            }
            ancestor = current.parent
        }
    }

    private func recordUnreadable(_ node: ScanNode, category: ErrorCategory, error: Error?) {
        node.markUnreadable()
        diagnostics.recordError(category, at: node, message: Self.message(for: category, error: error))
        var ancestor = node.parent
        while let current = ancestor {
            current.markIncomplete()
            ancestor = current.parent
        }
    }

    private static func message(for category: ErrorCategory, error: Error?) -> String {
        if let error = error { return (error as NSError).localizedDescription }
        switch category {
        case .unreadableDirectory: return "The contents of this folder could not be read."
        case .unreadableEntry: return "The size of this item could not be read."
        case .disappeared: return "This item was no longer there when the scan reached it."
        }
    }

    /// Whether an error means "it is not there", as opposed to "it cannot be
    /// read" — the difference between live change and a permission problem.
    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain
                && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError))
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
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

    /// Checkpoint B — reached after every batch of entries, so one enormous
    /// directory is no less cancellable than a deep one (spec §5.6).
    private func batchCheckpointRequestsStop() -> Bool {
        guard entriesSinceCancellationCheck >= batchSize else { return false }
        entriesSinceCancellationCheck = 0
        return isCancellationRequested
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

    /// Exclusions deliberately do not appear here: nothing went wrong, so a
    /// tree that skipped a boundary or a remote-only placeholder is still
    /// Exact (spec §3.5).
    private func completeness(stoppedEarly: Bool) -> Completeness {
        let unreadable = diagnostics.unreadableEntries
        if stoppedEarly || unreadable > 0 {
            return .incomplete(cancelled: stoppedEarly, unreadableEntries: unreadable)
        }
        return .exact
    }

    private static func pathTail(of url: URL) -> String {
        url.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/")
    }
}
