import Foundation
import ScanCore

/// Security-scoped access, neutralized.
///
/// A generated workload has no filesystem behind it, so there is no scope to
/// start. Ticket 05 established that the real call's return value is not an
/// eligibility verdict in either direction — it reports only whether a stop is
/// owed — so answering `false` here is exactly right: nothing was started, and
/// nothing is owed. `ScanCoreFileSystemTests` owns the balance proof.
struct UnscopedAccess: SecurityScopedAccess {
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

/// One rung's run: the terminal result, what it cost the filesystem seam, and
/// what it cost the machine.
struct ScaleScanOutcome {
    var result: ScanResult
    var operations: ProbeOperationCounts
    var memory: PeakMemorySampler.Reading
    var treeSnapshots: Int
    var progressSnapshots: Int
    /// Diagnostic only (spec §8.2).
    var wallClockSeconds: TimeInterval

    var terminalStateDescription: String {
        switch result.reason {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        }
    }

    var completenessDescription: String {
        switch result.completeness {
        case .exact:
            return "exact"
        case .incomplete(let cancelled, let unreadable):
            return "incomplete(cancelled: \(cancelled), unreadable: \(unreadable))"
        }
    }
}

/// Runs a generated rung end to end.
///
/// Everything the suite measures goes through here, so that "peak footprint"
/// means the same thing in every record: sampling starts before the scan and
/// stops after the terminal event, on the same thread cadence, with the same
/// probe instrumentation attached.
enum ScaleScanDriver {
    /// A path that is deliberately not on any disk. The workload answers every
    /// listing, so the only thing the URL has to do is give the engine
    /// something to build child paths from and give the probe something to
    /// measure relative paths against.
    static func rootURL(for rung: String) -> URL {
        URL(fileURLWithPath: "/macdirstat-generated/\(rung)", isDirectory: true)
    }

    /// - Parameters:
    ///   - clockStep: seconds the stepping clock advances per directory
    ///     listing. `nil` uses the real monotonic clock, which is what the
    ///     memory rungs want — they should not pay for emissions the UI would
    ///     never have asked for.
    ///   - onEvent: called for every event, on the consuming task. Deliberately
    ///     not an accumulating array: at Large a suite that kept every snapshot
    ///     would be measuring itself.
    ///   - cancelAfterListings: calls `Scanner.cancel()` from inside the walk,
    ///     immediately before the given listing. This is the UI's cancel — the
    ///     one that keeps the partial result — not task cancellation.
    static func run(
        _ workload: ScaleWorkload,
        progressCadence: EmissionCadence = .progressDefault,
        treeCadence: EmissionCadence = .treeDefault,
        clockStep: TimeInterval? = nil,
        tracksListedPaths: Bool = false,
        cancelAfterListings: Int? = nil,
        beforeList: (@Sendable (Int) -> Void)? = nil,
        onEvent: ((ScanEvent) -> Void)? = nil
    ) async -> ScaleScanOutcome {
        let root = rootURL(for: workload.manifest.rung)
        let clock = clockStep.map(SteppingClock.init(step:))
        let scanner = Scanner()
        let hook: (@Sendable (Int) -> Void)? = {
            guard beforeList != nil || cancelAfterListings != nil else { return nil }
            return { ordinal in
                beforeList?(ordinal)
                if let cancelAfterListings, ordinal == cancelAfterListings {
                    scanner.cancel()
                }
            }
        }()
        let probe = CountingWorkloadProbe(
            rootURL: root,
            workload: workload,
            clock: clock,
            tracksListedPaths: tracksListedPaths,
            beforeList: hook
        )
        let request = ScanRequest(
            root: root,
            mode: .folder,
            probe: probe,
            access: UnscopedAccess(),
            options: ScanOptions(
                progressCadence: progressCadence,
                treeCadence: treeCadence,
                clock: clock ?? MonotonicClock()
            )
        )

        let sampler = PeakMemorySampler()
        sampler.start()
        let began = Date()

        var result: ScanResult?
        var failure: ScanFailure?
        var treeSnapshots = 0
        var progressSnapshots = 0

        for await event in await scanner.scan(request) {
            switch event {
            case .started:
                break
            case .progress:
                progressSnapshots += 1
            case .tree:
                treeSnapshots += 1
                // The moment a tree snapshot exists is the moment the spine
                // copy is live alongside the tree it copied, so it is worth a
                // forced reading rather than waiting for the sampler's tick.
                sampler.sample()
            case .finished(let finished):
                result = finished
            case .failed(let scanFailure):
                failure = scanFailure
            }
            onEvent?(event)
        }

        let elapsed = Date().timeIntervalSince(began)
        let reading = sampler.stop()

        guard let result else {
            // Pre-flight is the only way a scan fails, and a generated workload
            // cannot fail it — so this is a bug in the harness, not a result.
            fatalError("generated rung \(workload.manifest.rung) failed pre-flight: \(String(describing: failure))")
        }

        return ScaleScanOutcome(
            result: result,
            operations: probe.operationCounts,
            memory: reading,
            treeSnapshots: treeSnapshots,
            progressSnapshots: progressSnapshots,
            wallClockSeconds: elapsed
        )
    }

    /// Turns a finished rung into the record line the ticket asks for.
    static func record(
        _ outcome: ScaleScanOutcome,
        manifest: WorkloadManifest,
        hardLinkDuplicates: Int
    ) -> RungRecord {
        RungRecord(
            rung: manifest.rung,
            entryCount: manifest.entryCount,
            directoryCount: manifest.directoryCount,
            fileCount: manifest.fileCount,
            logicalBytes: manifest.logicalBytes,
            attributedDiskBytes: outcome.result.root.subtreeDiskBytes,
            maximumDepth: manifest.maximumDepth,
            listOperations: outcome.operations.listCount,
            metadataOperations: outcome.operations.metadataCount,
            volumeInfoOperations: outcome.operations.volumeInfoCount,
            totalOperations: outcome.operations.total,
            entriesReturned: outcome.operations.entriesReturned,
            peakFootprintBytes: outcome.memory.peak.physicalFootprint,
            peakResidentBytes: outcome.memory.peak.residentSize,
            baselineFootprintBytes: outcome.memory.baseline.physicalFootprint,
            footprintDeltaBytes: outcome.memory.footprintDelta,
            bytesOfFootprintPerEntry: Double(outcome.memory.footprintDelta) / Double(manifest.entryCount),
            memorySampleCount: outcome.memory.sampleCount,
            terminalState: outcome.terminalStateDescription,
            completeness: outcome.completenessDescription,
            errorTotal: outcome.result.errors.total,
            errorsTruncated: outcome.result.errors.truncated,
            exclusionTotal: outcome.result.exclusions.total,
            hardLinkDuplicates: hardLinkDuplicates,
            diagnosticElapsedSeconds: outcome.wallClockSeconds,
            diagnosticEntriesPerSecond: outcome.wallClockSeconds > 0
                ? Double(manifest.entryCount) / outcome.wallClockSeconds
                : 0
        )
    }
}

// MARK: - Walking a finished tree without recursing

extension ScanNode {
    /// Every node in this subtree, visited iteratively.
    ///
    /// Recursion would be wrong twice over here: the deep-chain rung is 64
    /// levels and a real disk can be deeper, and a suite that overflowed its
    /// own stack while proving the engine does not would be embarrassing. The
    /// visitor returns `false` to stop descending into a node.
    func walk(_ visit: (ScanNode) -> Bool) {
        var stack: [ScanNode] = [self]
        while let node = stack.popLast() {
            guard visit(node) else { continue }
            stack.append(contentsOf: node.children)
        }
    }

    /// Counts of what is actually in the tree, which is what the manifest's
    /// declared numbers are checked against.
    struct Census: Equatable {
        var directories = 0
        var files = 0
        var symbolicLinks = 0
        var other = 0
        var hardLinkDuplicates = 0
        var unreadable = 0
        var incomplete = 0
        /// Deepest node of any kind; the root is 0.
        var maximumDepth = 0
        /// Deepest *directory*, which is what a workload manifest declares —
        /// a file one level under the deepest directory is not another level
        /// of tree.
        var maximumDirectoryDepth = 0
        var entries: Int { directories + files + symbolicLinks + other }
    }

    func census() -> Census {
        var census = Census()
        var stack: [(node: ScanNode, depth: Int)] = [(self, 0)]
        while let (node, depth) = stack.popLast() {
            switch node.kind {
            case .directory, .package:
                census.directories += 1
                census.maximumDirectoryDepth = max(census.maximumDirectoryDepth, depth)
            case .file: census.files += 1
            case .symbolicLink: census.symbolicLinks += 1
            case .other: census.other += 1
            }
            if case .hardLinkElsewhere = node.attribution { census.hardLinkDuplicates += 1 }
            switch node.readState {
            case .unreadable: census.unreadable += 1
            case .incomplete: census.incomplete += 1
            case .complete: break
            }
            census.maximumDepth = max(census.maximumDepth, depth)
            for child in node.children {
                stack.append((child, depth + 1))
            }
        }
        return census
    }
}
