import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

// Shared scaffolding for the pure-scanner suite: a fixed root URL, an event
// collector, accessors over a recorded event stream, and an *independent*
// fold over the scripted manifest — deliberately a second implementation, so
// a bug in the engine's roll-up cannot also be the bug in the oracle.

let scanRootURL = URL(fileURLWithPath: "/scan-root", isDirectory: true)

func makeRequest(
    probe: DirectoryProbe,
    mode: ScanMode = .folder,
    access: SecurityScopedAccess = SpySecurityScopedAccess(),
    options: ScanOptions = ScanOptions(progressCadence: .everyChange, treeCadence: .everyChange)
) -> ScanRequest {
    ScanRequest(root: scanRootURL, mode: mode, probe: probe, access: access, options: options)
}

func collectEvents(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
    var events: [ScanEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

/// Runs one scan to its terminal event and hands back everything it emitted.
func runScan(
    _ probe: DirectoryProbe,
    mode: ScanMode = .folder,
    access: SecurityScopedAccess = SpySecurityScopedAccess(),
    options: ScanOptions = ScanOptions(progressCadence: .everyChange, treeCadence: .everyChange)
) async -> [ScanEvent] {
    let scanner = Scanner()
    let stream = await scanner.scan(makeRequest(probe: probe, mode: mode, access: access, options: options))
    return await collectEvents(stream)
}

extension Array where Element == ScanEvent {
    var startedEvents: [ScanEvent] {
        filter { if case .started = $0 { return true } else { return false } }
    }

    var progressSnapshots: [ProgressSnapshot] {
        compactMap { if case .progress(let snapshot) = $0 { return snapshot } else { return nil } }
    }

    var treeSnapshots: [TreeSnapshot] {
        compactMap { if case .tree(let snapshot) = $0 { return snapshot } else { return nil } }
    }

    var terminalEvents: [ScanEvent] {
        filter(\.isTerminal)
    }

    var result: ScanResult? {
        for event in self {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    var failure: ScanFailure? {
        for event in self {
            if case .failed(let failure) = event { return failure }
        }
        return nil
    }
}

// MARK: - Independent oracle over the scripted manifest

/// Sums the blocks a manifest *should* produce, by a recursion written from the
/// semantics rather than from the engine: symlinks contribute zero and are not
/// descended, a directory on another volume contributes nothing, an unreadable
/// directory contributes nothing, sizes that could not be read are not guessed.
func expectedBytes(_ entry: ScriptedEntry, rootVolume: FileSystemIdentity?) -> Int64 {
    if entry.meta.isSymbolicLink { return 0 }
    if entry.meta.isDirectory {
        if entry.listFailure != nil { return 0 }
        if let volume = entry.meta.volumeIdentifier, let root = rootVolume, volume != root { return 0 }
        return entry.children.reduce(0) { $0 + expectedBytes($1, rootVolume: rootVolume) }
    }
    if entry.meta.isRegularFile { return entry.meta.diskSize ?? 0 }
    return 0
}

func expectedFileCount(_ entry: ScriptedEntry, rootVolume: FileSystemIdentity?) -> Int64 {
    if entry.meta.isSymbolicLink { return 0 }
    if entry.meta.isDirectory {
        if entry.listFailure != nil { return 0 }
        if let volume = entry.meta.volumeIdentifier, let root = rootVolume, volume != root { return 0 }
        return entry.children.reduce(0) { $0 + expectedFileCount($1, rootVolume: rootVolume) }
    }
    return entry.meta.isRegularFile ? 1 : 0
}

// MARK: - Reading a node tree

/// Every node, depth-first, as a "/"-joined path relative to the root.
/// Iterative: the fixtures include chains deep enough to matter.
func flatten(_ root: ScanNode) -> [String] {
    var paths: [String] = []
    var stack: [(node: ScanNode, path: String)] = [(root, "")]
    while let (node, path) = stack.popLast() {
        paths.append(path)
        for child in node.children.reversed() {
            stack.append((child, path.isEmpty ? child.name : path + "/" + child.name))
        }
    }
    return paths
}

func node(_ root: ScanNode, at path: String) -> ScanNode? {
    var current = root
    guard !path.isEmpty else { return current }
    for component in path.split(separator: "/") {
        guard let next = current.children.first(where: { $0.name == String(component) }) else { return nil }
        current = next
    }
    return current
}

func subtreeTotals(_ root: ScanNode) -> [String: Int64] {
    var totals: [String: Int64] = [:]
    var stack: [(node: ScanNode, path: String)] = [(root, "")]
    while let (node, path) = stack.popLast() {
        totals[path] = node.subtreeDiskBytes
        for child in node.children {
            stack.append((child, path.isEmpty ? child.name : path + "/" + child.name))
        }
    }
    return totals
}

/// Sums the `ownDiskBytes` actually attributed to leaves in a tree — the check that
/// a directory's rolled-up total is the truth and not a running guess.
func foldOwnDiskBytes(_ root: ScanNode) -> Int64 {
    var total: Int64 = 0
    var stack: [ScanNode] = [root]
    while let node = stack.popLast() {
        total += node.ownDiskBytes
        stack.append(contentsOf: node.children)
    }
    return total
}

/// The same fold over the measure carried beside it, so a roll-up that drifts
/// in only one of the two is still caught.
func foldOwnContentBytes(_ root: ScanNode) -> Int64 {
    var total: Int64 = 0
    var stack: [ScanNode] = [root]
    while let node = stack.popLast() {
        total += node.ownContentBytes
        stack.append(contentsOf: node.children)
    }
    return total
}

/// A lock-guarded ordered log, for asserting that two scans did not overlap.
final class SharedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
