import Foundation

/// One scan, start to terminal event.
///
/// A session is created inside the scan's own task and never escapes it, so the
/// mutable tree, the counters and the accumulators have exactly one writer —
/// obtained by confinement rather than by locking the hot path. The tree is
/// handed to the UI once, with the terminal event, and never touched again.
///
/// The traversal commits **serially, iteratively, depth-first** over an explicit
/// stack. A bounded production-only window may fetch independent directory
/// listings ahead, but their nodes, hard-link ownership, errors and progress
/// are applied only when the deterministic cursor reaches them. Iterative
/// because a filesystem's depth is the user's to choose, not ours to survive
/// on the call stack.
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
        /// Fast mode may replace this package's detailed walk with one
        /// aggregate measurement when the probe supports it.
        var summarizePackage: Bool = false
        var entries: [EntryMeta] = []
        var cursor: Int = 0
        var listed: Bool = false
        /// A listing started while an earlier sibling was being traversed.
        var prefetchedListing: DirectoryListingFuture?
        /// Read-ahead keyed by this frame's deterministic entry index. Results
        /// are attached to child frames only when that index is committed.
        var prefetchedChildren: [Int: DirectoryListingFuture] = [:]
        /// Hidden subdirectories, opened after this directory's visible ones.
        /// See ``ScanSession/traverse()``.
        var pendingHidden: [Frame] = []
    }

    private let request: ScanRequest
    private let sink: EventSink
    private let token: CancellationToken
    private let probe: DirectoryProbe
    private let clock: ScanClock
    private let progressInterval: TimeInterval
    private let batchSize: Int
    private let listingPrefetcher: DirectoryListingPrefetcher?

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
    /// The progress card's running measure. The mutable tree has no reader
    /// until the terminal event, so its per-directory totals are finalized in
    /// one post-order pass instead of being updated through every ancestor for
    /// every file.
    private var attributedDiskBytes: Int64 = 0
    private var currentPathTail: String = ""

    private var startedAt: TimeInterval = 0
    private var lastProgressEmit: TimeInterval = -.infinity
    private var progressSequence: UInt64 = 0
    /// Sticky: once the counted total has passed the volume's used figure, the
    /// completion percentage is gone for the rest of the scan.
    private var fractionWithdrawn = false
    private var entriesSinceClockRead = 0
    private var entriesSinceCancellationCheck = 0
    /// Prevents two aliases for one not-yet-opened directory from both being
    /// speculatively listed. The first entry in deterministic order reserves
    /// the identity; the normal visited index still decides ownership.
    private var prefetchedDirectoryIdentities: Set<FileSystemIdentity> = []

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
        self.progressInterval = request.options.progressInterval
        self.batchSize = request.options.cancellationBatchSize
        self.listingPrefetcher = request.options.directoryPrefetchConcurrency > 1
            && request.probe is any ConcurrentDirectoryListingProbe
            ? DirectoryListingPrefetcher(
                probe: request.probe,
                capacity: request.options.directoryPrefetchConcurrency
            )
            : nil
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
            // Fires the instant the task is cancelled, even mid-listing. The
            // scope is released after the bounded prefetch queue has joined;
            // no worker may keep reading after sandbox access is surrendered.
            token.cancel()
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

        // One bounded post-order pass over the tree the walk built, on the
        // walk's own thread, while nothing else can see it. It writes the
        // per-node counts the tree and inspector read in O(1) and hands back
        // the root totals the status line reads, so no pane ever walks a
        // subtree to answer a question about names.
        let visibleTotals = TreeCountFinalization.finalize(root)

        emitFinalProgress()
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
            visibleTotals: visibleTotals,
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
        defer { listingPrefetcher?.cancelAndWait() }
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
                discardPrefetchedListing(in: &stack[top])
                stack.removeLast()
                emitIfDue()
                continue
            }

            if !stack[top].listed, stack[top].summarizePackage,
               let summarizer = probe as? any PackageSummarizingProbe {
                currentPathTail = Self.pathTail(of: stack[top].url)
                let summary = summarizer.summarizePackage(
                    stack[top].url,
                    onVolume: rootVolume,
                    shouldStop: { [token] in token.isCancelled || Task.isCancelled }
                )

                if let summary {
                    attributePackageSummary(stack[top].node, summary)
                    diagnostics.exclude(.remoteOnlyCloud, count: summary.remoteOnlyItems)
                    diagnostics.exclude(
                        .crossedVolumeBoundary,
                        count: summary.crossedVolumeBoundaries
                    )
                    if !summary.isComplete {
                        recordIncompletePackageSummary(stack[top].node)
                    }
                    stack.removeLast()
                    emitIfDue()
                    continue
                }

                // `nil` normally means the lightweight facility was
                // unavailable, in which case accuracy wins and this package
                // falls back to the ordinary detailed walk. If cancellation
                // interrupted the aggregate pass, stop before doing that work
                // all over again.
                if isCancellationRequested {
                    stopAtCancellation(openFrames(stack, deferredMounts))
                    return true
                }
            }

            if !stack[top].listed {
                currentPathTail = Self.pathTail(of: stack[top].url)
                do {
                    var entries: [EntryMeta]
                    if let prefetched = stack[top].prefetchedListing {
                        stack[top].prefetchedListing = nil
                        if let identity = stack[top].identity {
                            prefetchedDirectoryIdentities.remove(identity)
                        }
                        entries = try prefetched.take()
                    } else {
                        entries = try probe.list(stack[top].url)
                    }
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
                    fillPrefetchWindow(in: &stack[top])
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
                    discardPrefetchedListing(in: &stack[top])
                    stack.removeLast()
                    emitIfDue()
                    continue
                }
            }

            // A consumed child future freed one global slot. Refill from this
            // directory before continuing its deterministic cursor.
            fillPrefetchWindow(in: &stack[top])

            var descended = false
            while stack[top].cursor < stack[top].entries.count {
                let entryIndex = stack[top].cursor
                let meta = stack[top].entries[entryIndex]
                let prefetched = stack[top].prefetchedChildren.removeValue(forKey: entryIndex)
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
                    } else {
                        let isMountPoint = mountPointPaths.contains(childURL.path)
                        let frame = Frame(
                            node: node,
                            url: childURL,
                            identity: meta.fileIdentity,
                            isMountPoint: isMountPoint,
                            summarizePackage: kind == .package
                                && request.options.packageScanMode == .summarized,
                            prefetchedListing: prefetched
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

            stack.removeLast()
            emitIfDue()
        }

        return false
    }

    /// Fills only the prefetcher's free slots, and only with directories the
    /// traversal will open promptly. Hidden entries and mount points can be
    /// deferred for most of a volume scan, while summarized packages take a
    /// different probe path, so none of those retain speculative listings.
    private func fillPrefetchWindow(in frame: inout Frame) {
        guard let listingPrefetcher else { return }
        var index = frame.cursor
        while index < frame.entries.count {
            defer { index += 1 }
            guard frame.prefetchedChildren[index] == nil else { continue }
            let meta = frame.entries[index]
            guard meta.cloudDownloadingStatus != .notDownloaded,
                  isOnRootVolume(meta),
                  !Self.isHidden(meta.name) else { continue }
            let kind = Self.kind(of: meta)
            guard kind == .directory || kind == .package else { continue }
            if kind == .package, request.options.packageScanMode == .summarized { continue }

            let childURL = frame.url.appendingPathComponent(meta.name)
            guard !mountPointPaths.contains(childURL.path),
                  !visitedDirectories.hasClaimed(meta.fileIdentity) else { continue }
            if let identity = meta.fileIdentity,
               prefetchedDirectoryIdentities.contains(identity) { continue }
            guard let future = listingPrefetcher.schedule(childURL) else { return }
            frame.prefetchedChildren[index] = future
            if let identity = meta.fileIdentity { prefetchedDirectoryIdentities.insert(identity) }
        }
    }

    private func discardPrefetchedListing(in frame: inout Frame) {
        guard let prefetched = frame.prefetchedListing else { return }
        frame.prefetchedListing = nil
        prefetched.discard()
        if let identity = frame.identity { prefetchedDirectoryIdentities.remove(identity) }
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
        }
    }

    // MARK: - Attribution

    private func attribute(_ node: ScanNode, _ meta: EntryMeta) {
        let isRegularFile = node.kind == .file
        if isRegularFile { filesSeen += 1 }

        var bytes: Int64 = 0
        var contentBytes: Int64 = 0
        if isRegularFile {
            // **The on-disk figure decides readability** (ticket 13). An entry
            // whose blocks cannot be read is Unreadable even when its content
            // length reads perfectly well, and is never given that length as a
            // substitute: the two are different quantities, and one of them is
            // not the measure.
            if let size = meta.diskSize {
                bytes = max(0, size)
                // Content length is only ever a figure carried beside the
                // measure. Where it could not be read, the node carries the
                // on-disk figure, so the inspector stays silent rather than
                // claiming a divergence nobody measured.
                contentBytes = max(0, meta.contentLength ?? size)
                if case .duplicate(let owner) = hardLinks.claim(meta, for: node) {
                    // Another in-scope name reached this inode first and
                    // already counted its bytes. This name stays visible and
                    // weightless, with the owner's path so the UI can say
                    // where the bytes went (spec §3.4). Both measures go to
                    // zero: the two names genuinely share one set of blocks
                    // and one set of contents.
                    bytes = 0
                    contentBytes = 0
                    node.markHardLinkElsewhere(owner: owner)
                }
            } else {
                // A size we could not read is never guessed (spec §3.5) — and
                // an entry with no size never enters the identity index, since
                // owning an inode whose length is unknown would zero out a
                // later name that *could* be read.
                recordUnreadable(node, category: .unreadableEntry, error: nil)
            }
        }

        node.attribute(diskBytes: bytes, contentBytes: contentBytes, isRegularFile: isRegularFile)
        attributedDiskBytes += bytes
    }

    private func attributePackageSummary(_ node: ScanNode, _ summary: PackageSummary) {
        var bytes = max(0, summary.diskBytes)
        var contentBytes = max(0, summary.contentBytes)
        for link in summary.hardLinks {
            if case .duplicate = hardLinks.claim(
                link.identity,
                ownerPath: node.pathComponents() + link.relativePath
            ) {
                bytes -= link.diskBytes
                contentBytes -= link.contentBytes
            }
        }
        node.attributePackageSummary(
            diskBytes: bytes,
            contentBytes: contentBytes,
            files: summary.fileCount,
            directories: summary.directoryCount
        )
        filesSeen += summary.fileCount
        directoriesSeen += Int64(summary.directoryCount)
        attributedDiskBytes += bytes
    }

    private func recordIncompletePackageSummary(_ node: ScanNode) {
        node.markIncomplete()
        diagnostics.recordError(
            .unreadableDirectory,
            at: node,
            message: "Some items inside this app could not be measured in fast mode."
        )
        var ancestor = node.parent
        while let current = ancestor {
            current.markIncomplete()
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

    private func throttledEmit() {
        entriesSinceClockRead += 1
        if progressInterval > 0 && entriesSinceClockRead < Self.clockReadInterval { return }
        entriesSinceClockRead = 0
        emitIfDue()
    }

    private func emitIfDue() {
        // An infinite interval means "only the final reading" — and without the
        // finiteness check the very first call would pass, because the last
        // emission starts at negative infinity.
        guard progressInterval.isFinite else { return }
        let now = clock.now
        guard now - lastProgressEmit >= progressInterval else { return }
        lastProgressEmit = now
        sink.emit(.progress(makeProgress(now: now)))
    }

    /// The last reading the card shows is always exact, whatever the interval.
    private func emitFinalProgress() {
        let now = clock.now
        lastProgressEmit = now
        currentPathTail = ""
        sink.emit(.progress(makeProgress(now: now, isFinal: true)))
    }

    private func makeProgress(now: TimeInterval, isFinal: Bool = false) -> ProgressSnapshot {
        progressSequence += 1
        let elapsed = max(0, now - startedAt)
        let bytes = attributedDiskBytes
        let items = filesSeen + directoriesSeen
        return ProgressSnapshot(
            attributedDiskBytes: bytes,
            filesSeen: filesSeen,
            directoriesSeen: directoriesSeen,
            currentPathTail: currentPathTail,
            elapsed: elapsed,
            // Items, not bytes: the scanner reads listings and never contents,
            // so a byte rate here would not be a disk speed even now that the
            // bytes are real (ticket 13).
            itemsPerSecond: elapsed > 0 ? Double(items) / elapsed : 0,
            approximateFraction: approximateFraction(attributedDiskBytes: bytes, isFinal: isFinal),
            sequence: progressSequence
        )
    }

    /// Volume scans only. Blocks counted over the volume's own used figure —
    /// the same quantity on both sides of the division since ticket 13, and on
    /// the field machine the two land within 0.3% of each other.
    ///
    /// It is still approximate, and it fails in two directions this guards
    /// against: it must never claim to be finished while it is running, so it
    /// is capped at 0.99 until the terminal snapshot; and once the counted
    /// total passes volume-used there is no honest denominator left, so the
    /// figure is **withdrawn for the rest of the scan** rather than pinned at
    /// its ceiling. A folder scan has nothing to divide by at all (spec §5.5).
    private func approximateFraction(attributedDiskBytes: Int64, isFinal: Bool) -> Double? {
        guard request.mode == .volumeRoot,
              let capacity = volumeCapacity,
              capacity.usedBytes > 0
        else { return nil }
        if attributedDiskBytes > capacity.usedBytes { fractionWithdrawn = true }
        guard !fractionWithdrawn else { return nil }
        let fraction = Double(attributedDiskBytes) / Double(capacity.usedBytes)
        return min(fraction, isFinal ? 1.0 : 0.99)
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
