import Foundation
import ScanCore

/// Everything the app remembers between launches.
///
/// A scan is still a transient session — nothing about a *result* is persisted,
/// and relaunching never re-walks a disk on its own. What is kept is the shape
/// the user put the window in and the choices they already made: where the
/// dividers sit, how the tree is sorted, whether Fast mode was on, and which
/// folders they scanned. `NSSplitView` and `NSTableView` autosave their own
/// geometry; this holds the rest.
///
/// It is injectable so tests get a scratch store rather than the real domain:
/// a test that reorders the recents must not reorder the user's.

/// The handful of `UserDefaults` calls this needs, so a test can be handed a
/// store that keeps nothing.
@MainActor
protocol PreferenceStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// A store that forgets everything at process exit.
@MainActor
final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    init() {}

    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@MainActor
final class Preferences {
    /// Under `xctest` this is backed by memory, not by the user's defaults.
    ///
    /// Tests build a `MainWindowController` by the dozen, and several of them
    /// place dividers and start scans. Against the real domain they would
    /// reorder the user's recents and — because "the treemap has been placed
    /// once" is a persisted fact — pass on a clean machine and fail on the
    /// second run.
    static let shared = Preferences(store: isRunningTests ? InMemoryPreferenceStore() : UserDefaults.standard)

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private let defaults: PreferenceStore

    init(store: PreferenceStore) {
        self.defaults = store
    }

    private enum Key {
        static let summarizesPackages = "scan.fastMode"
        static let sortColumn = "tree.sortColumn"
        static let sortAscending = "tree.sortAscending"
        static let recentScans = "scan.recentPaths"
        static let hasPlacedTreemapDivider = "workspace.hasPlacedTreemapDivider"
        static let detailPaneCollapsed = "workspace.detailPaneCollapsed"
    }

    // MARK: - Fast mode

    /// Asked in two places — the source chooser and the folder panel — and
    /// until now remembered in neither.
    var packageScanMode: PackageScanMode {
        get { defaults.bool(forKey: Key.summarizesPackages) ? .summarized : .detailed }
        set { defaults.set(newValue == .summarized, forKey: Key.summarizesPackages) }
    }

    // MARK: - Tree sort

    /// `NSTableView`'s column autosave covers width and order and stops there,
    /// so the sort is kept here. `nil` means "never set", which is the only
    /// time the tree falls back to its default of size-descending.
    var treeSort: (column: TreeColumn, ascending: Bool)? {
        get {
            guard let raw = defaults.string(forKey: Key.sortColumn),
                  let column = TreeColumn(rawValue: raw) else { return nil }
            return (column, defaults.bool(forKey: Key.sortAscending))
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.sortColumn)
                defaults.removeObject(forKey: Key.sortAscending)
                return
            }
            defaults.set(newValue.column.rawValue, forKey: Key.sortColumn)
            defaults.set(newValue.ascending, forKey: Key.sortAscending)
        }
    }

    // MARK: - Recent scans

    static let recentScanLimit = 10

    /// Most recent first, and only the ones still on disk: a folder that has
    /// been unmounted or deleted is not something to offer to scan.
    var recentScans: [URL] {
        let paths = defaults.stringArray(forKey: Key.recentScans) ?? []
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// The one the empty state offers to pick up again.
    var lastScan: URL? { recentScans.first }

    /// Moves `url` to the front, deduplicating by path so scanning the same
    /// folder twice does not fill the menu with it.
    func rememberScan(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Key.recentScans) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(Self.recentScanLimit)), forKey: Key.recentScans)
    }

    func clearRecentScans() {
        defaults.removeObject(forKey: Key.recentScans)
    }

    // MARK: - Workspace geometry

    /// Whether the treemap has ever been opened at its band.
    ///
    /// The opening height is a *first run* courtesy, not a policy: once the
    /// split view's own autosave has a position to restore, placing the divider
    /// again would throw away the height the user chose.
    var hasPlacedTreemapDivider: Bool {
        get { defaults.bool(forKey: Key.hasPlacedTreemapDivider) }
        set { defaults.set(newValue, forKey: Key.hasPlacedTreemapDivider) }
    }

    /// Collapsing is the one split-view state `autosaveName` does not carry.
    var isDetailPaneCollapsed: Bool {
        get { defaults.bool(forKey: Key.detailPaneCollapsed) }
        set { defaults.set(newValue, forKey: Key.detailPaneCollapsed) }
    }
}
