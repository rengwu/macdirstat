import Foundation
import XCTest
@testable import ScanCore
import ScanCoreTestSupport

// Shared scaffolding for the production-probe suite (spec §9.1, §9.2).
//
// Every case here runs against a real tree that this suite staged itself, in a
// uniquely owned child of the test temporary directory, and never against an
// existing user directory. The fixture restores permission bits and refuses to
// delete anything it cannot prove it owns.

/// A test case that stages the small real-filesystem fixture and disposes of it
/// however the test ends.
class RealFixtureTestCase: XCTestCase {
    private(set) var fixture: TemporaryFileSystemFixture!
    private(set) var manifest: RealFixtureManifest!

    /// The directory a scan is pointed at — a child of the owned directory, so
    /// the ownership sentinel and the out-of-scope hard link sit where a
    /// correct scan will never see them.
    var scanRoot: URL { manifest.scanRoot }

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try TemporaryFileSystemFixture(label: "fs-suite")
        manifest = try RealFilesystemFixture.build(in: fixture)
    }

    override func tearDownWithError() throws {
        // Restores the `chmod 000` directory before removing anything, and
        // refuses to remove a directory that is not provably this fixture's.
        try fixture?.cleanUp()
        fixture = nil
        manifest = nil
        try super.tearDownWithError()
    }
}

// MARK: - Running a scan against the real tree

/// Only the final, exact snapshots — every assertion here is about what a scan
/// *measured*, and cadence is the pure suite's subject.
let terminalSnapshotsOnly = ScanOptions(progressCadence: .terminalOnly, treeCadence: .terminalOnly)

func makeProductionRequest(
    root: URL,
    mode: ScanMode = .folder,
    probe: DirectoryProbe = FileManagerDirectoryProbe(),
    access: SecurityScopedAccess = SpySecurityScopedAccess(),
    options: ScanOptions = terminalSnapshotsOnly
) -> ScanRequest {
    ScanRequest(root: root, mode: mode, probe: probe, access: access, options: options)
}

func collectEvents(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
    var events: [ScanEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

/// Runs one scan of a real directory with the production probe and hands back
/// everything it emitted.
func runProductionScan(
    root: URL,
    mode: ScanMode = .folder,
    probe: DirectoryProbe = FileManagerDirectoryProbe(),
    access: SecurityScopedAccess = SpySecurityScopedAccess(),
    options: ScanOptions = terminalSnapshotsOnly
) async -> [ScanEvent] {
    let scanner = Scanner()
    let stream = await scanner.scan(
        makeProductionRequest(root: root, mode: mode, probe: probe, access: access, options: options)
    )
    return await collectEvents(stream)
}

extension Array where Element == ScanEvent {
    var progressSnapshots: [ProgressSnapshot] {
        compactMap { if case .progress(let snapshot) = $0 { return snapshot } else { return nil } }
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

// MARK: - Reading a node tree

/// Every node, depth-first, as a "/"-joined path relative to the root.
/// Iterative, because the fixture's chain is 64 levels deep.
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

/// How many levels of node lie below `root`, counted without recursion.
func depth(of root: ScanNode) -> Int {
    var deepest = 1
    var stack: [(node: ScanNode, level: Int)] = [(root, 1)]
    while let (node, level) = stack.popLast() {
        deepest = Swift.max(deepest, level)
        for child in node.children {
            stack.append((child, level + 1))
        }
    }
    return deepest
}

// MARK: - Probes that watch a real scan

/// The production probe with a hook on `list`, so a test can cancel or block at
/// an exact point of a real traversal. It adds no capability — every call goes
/// straight through to the adapter under test.
final class InterceptingProbe: DirectoryProbe, @unchecked Sendable {
    private let wrapped: DirectoryProbe
    private let onList: @Sendable (URL, Int) -> Void
    private let lock = NSLock()
    private var lists = 0

    init(_ wrapped: DirectoryProbe = FileManagerDirectoryProbe(),
         onList: @escaping @Sendable (URL, Int) -> Void) {
        self.wrapped = wrapped
        self.onList = onList
    }

    var listCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lists
    }

    func list(_ url: URL) throws -> [EntryMeta] {
        lock.lock()
        lists += 1
        let index = lists
        lock.unlock()
        onList(url, index)
        return try wrapped.list(url)
    }

    func metadata(of url: URL) throws -> EntryMeta { try wrapped.metadata(of: url) }
    func volumeInfo(for url: URL) throws -> VolumeInfo { try wrapped.volumeInfo(for: url) }
}

/// A lock-guarded log of the paths a scan asked to have listed.
final class SharedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ path: String) {
        lock.lock()
        recorded.append(path)
        lock.unlock()
    }
}

/// A one-way flag a test can poll without blocking its own thread.
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}

/// Waits for a flag without blocking, so a scan blocked on a semaphore cannot
/// deadlock against the test that is meant to release it.
func waitForFlag(_ flag: TestFlag, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !flag.isRaised, Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(flag.isRaised, "timed out waiting for the scan to reach its checkpoint", file: file, line: line)
}
