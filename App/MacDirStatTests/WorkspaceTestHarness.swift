import AppKit
import ScanCore
import XCTest
@testable import MacDirStat

/// A real scan of a disposable temporary tree.
///
/// `ScanNode` is deliberately not constructible from outside `ScanCore` — the
/// engine owns the freeze discipline that makes a node safe to share — and
/// `ScanCoreTestSupport` is a package-internal target with no product, so the
/// app's tests cannot borrow the scripted probe either. Both facts point the
/// same way: the app layer is tested against trees the production probe
/// actually produced, which is also the only way its URL reconstruction can be
/// checked against a path that exists.
///
/// Every fixture lives under the test temporary directory and is removed on
/// teardown; nothing here touches a user directory (spec §9.2).
@MainActor
final class ScannedFixture {
    let root: URL
    let rootNode: ScanNode
    let model: ScanPresentationModel

    private init(root: URL, rootNode: ScanNode, model: ScanPresentationModel) {
        self.root = root
        self.rootNode = rootNode
        self.model = model
    }

    static func make(
        in testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ build: (URL) throws -> Void
    ) async throws -> ScannedFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDirStat-Ticket08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        testCase.addTeardownBlock {
            // Restore anything a chmod-000 case made undeletable before
            // removing the tree, so one failing test cannot leak a fixture.
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try build(root)

        let model = ScanPresentationModel()
        let finished = testCase.expectation(description: "scan finished")
        model.onChange = {
            if model.phase == .completed || model.phase == .cancelled || model.phase == .failed {
                finished.fulfill()
            }
        }
        model.start(root: root, mode: .folder)
        await testCase.fulfillment(of: [finished], timeout: 20)
        guard let rootNode = model.root else {
            XCTFail("fixture scan produced no tree", file: file, line: line)
            throw CocoaError(.fileReadUnknown)
        }
        model.onChange = nil
        return ScannedFixture(root: root, rootNode: rootNode, model: model)
    }

    /// The first descendant with this name, searched depth-first.
    func node(named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> ScanNode {
        var stack = [rootNode]
        while let current = stack.popLast() {
            if current.name == name { return current }
            stack.append(contentsOf: current.children)
        }
        XCTFail("no node named \(name) in the fixture", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    /// A workspace wired to this fixture's already-finished scan, with spies in
    /// place of `NSWorkspace` and the VoiceOver announcer.
    /// Every fixture workspace gets a store of its own: the persisted facts —
    /// the sort, the divider, the recents — are per installation, and a test
    /// that shares them with the next test is a test that depends on order.
    func makeWorkspace(
        locale: Locale = Locale(identifier: "en_US"),
        preferences: Preferences? = nil
    ) -> (WorkspaceSplitViewController, WorkspaceActionSpy, AnnouncementSpy) {
        let actions = WorkspaceActionSpy()
        let announcer = AnnouncementSpy()
        let workspace = WorkspaceSplitViewController(
            model: model,
            formatter: DisplayFormatter(locale: locale),
            workspaceActions: actions,
            announcer: announcer,
            preferences: preferences ?? Preferences(store: InMemoryPreferenceStore())
        )
        // Force the whole three-pane hierarchy to load and settle, then hand it
        // the finished scan the way a live scan's terminal event would. The
        // treemap's viewport is pinned afterwards so the geometry a test
        // asserts on is the geometry it asked for.
        _ = workspace.view
        workspace.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        workspace.view.layoutSubtreeIfNeeded()
        // Layout inline, so a test that asks for geometry has it in the same
        // turn. Production lays out in the background (ticket 14); the geometry
        // is identical either way — `LayoutCoordinatorTests` asserts that
        // directly — and `TreemapViewTests` covers the background path's own
        // behaviour separately.
        workspace.treemapViewController.treemapView.layoutExecution = .immediate
        workspace.treemapViewController.treemapView.frame = NSRect(x: 0, y: 0, width: 520, height: 390)
        workspace.treeViewController.setRoot(model.root)
        workspace.treemapViewController.treemapView.context = workspace.selectionContext
        workspace.treemapViewController.treemapView.setRoot(model.root)
        return (workspace, actions, announcer)
    }
}

/// Writes a file of exactly `bytes` bytes of content.
///
/// What it *occupies* is a different number, and the volume decides it: since
/// ticket 13 the app measures blocks on disk, and a 300-byte file is a whole
/// block. Tests that need the figure the app will show read it back with
/// ``onDiskBytes(of:)`` rather than predicting it, because a block size is not
/// ours to assume.
func writeFile(_ name: String, bytes: Int, in directory: URL) throws {
    try Data(repeating: 0x2A, count: bytes).write(to: directory.appendingPathComponent(name))
}

/// Writes a file with `length` bytes of content occupying no blocks at all —
/// the sparse case, where the two measures part company by gigabytes.
func writeSparseFile(_ name: String, length: Int64, in directory: URL) throws {
    let path = directory.appendingPathComponent(name).path
    let descriptor = open(path, O_CREAT | O_RDWR | O_EXCL, 0o644)
    guard descriptor >= 0, ftruncate(descriptor, off_t(length)) == 0 else {
        close(descriptor)
        throw CocoaError(.fileWriteUnknown)
    }
    close(descriptor)
}

/// Stages a file that **occupies** `bytes` on disk without writing any of them.
///
/// `F_PREALLOCATE` reserves real blocks — they are counted in `st_blocks` and
/// reported by `fileAllocatedSizeKey` — so a fixture can hold a half-gigabyte
/// file in a millisecond. It is the mirror of ``writeSparseFile(_:length:in:)``,
/// and it is what makes the merge bucket stageable at all now that the app
/// measures blocks: every real file occupies at least one, so a tail folds into
/// an aggregate only beside something genuinely enormous (ticket 13).
func writeAllocatedFile(_ name: String, bytes: Int64, in directory: URL) throws {
    let path = directory.appendingPathComponent(name).path
    let descriptor = open(path, O_CREAT | O_RDWR | O_EXCL, 0o644)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    var request = fstore_t(
        fst_flags: UInt32(F_ALLOCATEALL),
        fst_posmode: F_PEOFPOSMODE,
        fst_offset: 0,
        fst_length: off_t(bytes),
        fst_bytesalloc: 0
    )
    guard fcntl(descriptor, F_PREALLOCATE, &request) == 0,
          ftruncate(descriptor, off_t(bytes)) == 0
    else { throw CocoaError(.fileWriteUnknown) }
}

/// What a staged file actually occupies, read from the filesystem.
///
/// The oracle for every size the app now shows. Read rather than predicted: how
/// many blocks a 300-byte file costs is the host volume's business, and a test
/// that hard-codes 4,096 is asserting the machine it was written on.
func onDiskBytes(of url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey])
    guard let allocated = values.fileAllocatedSize else { throw CocoaError(.fileReadUnknown) }
    return Int64(allocated)
}

/// The sum of what several staged files occupy.
func onDiskBytes(of names: [String], in directory: URL) throws -> Int64 {
    try names.reduce(0) { try $0 + onDiskBytes(of: directory.appendingPathComponent($1)) }
}

/// A byte count grouped the way the inspector writes it, so a test can assert a
/// literal string against a figure the volume decided.
func groupedBytesText(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) bytes"
}

func makeDirectory(_ name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

/// The `NSWorkspace` seam, recording instead of acting (spec §9.3).
@MainActor
final class WorkspaceActionSpy: WorkspaceActing {
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []

    var callCount: Int { opened.count + revealed.count }

    func open(_ url: URL) { opened.append(url) }
    func reveal(_ url: URL) { revealed.append(url) }
}

@MainActor
final class AnnouncementSpy: AccessibilityAnnouncing {
    private(set) var messages: [String] = []

    func announce(_ message: String) { messages.append(message) }
}

/// Every verb this app must never offer, in menus, context menus, the command strip
/// or the accessibility tree (§7.1).
let mutationVerbs = [
    "Delete", "Remove", "Trash", "Clean", "Move", "Rename", "Copy",
    "Compress", "Erase", "Empty", "Download", "Write", "Save",
]

/// Labels that contain a mutation verb and are nonetheless known not to touch
/// a file.
///
/// Matched **exactly**, never as a substring, which is the point: "Copy" and
/// "Copy Path" are on the list, and "Copy to Folder…" could never join them by
/// accident. Everything here writes to the pasteboard or to a text field, and
/// the pasteboard is not the disk.
let clipboardLabels: Set<String> = ["Copy", "Cut", "Paste", "Copy Path"]

func assertNoMutationAffordance(
    in labels: [String],
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for label in labels where !clipboardLabels.contains(label) {
        for verb in mutationVerbs {
            XCTAssertFalse(
                label.localizedCaseInsensitiveContains(verb),
                "\(context) offers “\(label)”, which reads as the mutation verb “\(verb)”",
                file: file,
                line: line
            )
        }
    }
}
