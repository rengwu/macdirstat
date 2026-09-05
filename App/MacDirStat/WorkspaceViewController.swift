import AppKit
import ScanCore
import TreemapLayout

enum TreeColumn: String, Sendable {
    case name
    case size
    case percent
    case items

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .percent: return "%"
        case .items: return "Items"
        }
    }
}

/// A frozen outline sort that is safe to carry to a background task. The
/// controller used to close over its main-actor fields, making a wide sibling
/// sort inseparable from the UI thread.
struct TreeSort: Sendable {
    let column: TreeColumn
    let ascending: Bool

    func precedes(_ lhs: ScanNode, _ rhs: ScanNode) -> Bool {
        switch column {
        case .name:
            return ascending
                ? NameOrder.precedes(lhs.name, rhs.name)
                : NameOrder.precedes(rhs.name, lhs.name)
        case .size, .percent:
            if lhs.subtreeDiskBytes == rhs.subtreeDiskBytes {
                return NameOrder.precedes(lhs.name, rhs.name)
            }
            return ascending
                ? lhs.subtreeDiskBytes < rhs.subtreeDiskBytes
                : lhs.subtreeDiskBytes > rhs.subtreeDiskBytes
        case .items:
            let left = lhs.presentedDescendantCount
            let right = rhs.presentedDescendantCount
            if left == right { return NameOrder.precedes(lhs.name, rhs.name) }
            return ascending ? left < right : left > right
        }
    }
}

/// The `NSOutlineView` the tree pane uses, with the two behaviours a stock one
/// does not have: Return activates the row (expand, or open a file), and a
/// right-click selects the row it points at before showing the read-only menu
/// (§7.2; ticket 01, decision 3).
@MainActor
final class WorkspaceOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onContextMenuRow: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        onContextMenuRow?(clickedRow)
        return FileActionMenu.make()
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.command) {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The sorted child arrays the outline view is currently asking about,
/// memoised per node.
///
/// **Why this can exist at all.** The scan tree is published once, with the
/// terminal event, and is immutable from that moment. A sorted array of a
/// node's children can therefore be computed once and handed back for as long
/// as the root and the sort descriptor stand.
///
/// **Why it has to.** `NSOutlineView` asks for children one index at a time, so
/// a directory with `N` children used to pay `N` complete `O(N log N)` sorts
/// while its rows were materialised — and the count query paid another one just
/// to read `.count`.
///
/// Only nodes AppKit actually asks about get an entry: nothing pre-sorts or
/// pre-caches the tree. Entries key on node identity and are dropped wholesale
/// when the root or the sort descriptor changes, so a cached array can never
/// outlive the tree it came from.
@MainActor
final class SortedChildrenCache {
    private var entries: [ObjectIdentifier: [ScanNode]] = [:]
    /// How many arrays this cache has actually sorted.
    ///
    /// A diagnostic, and the only honest way to test the claim: "each requested
    /// node is sorted at most once per sort configuration" is a statement about
    /// work done, and asserting it with a stopwatch would be flaky on every
    /// machine but the one it was written on. Monotonic — invalidation does not
    /// reset it — so a test can prove a *re*-sort happened.
    private(set) var misses = 0

    /// Nodes currently held. Zero after an invalidation, which is what "does
    /// not retain an obsolete root" means in practice.
    var entryCount: Int { entries.count }

    func contains(_ node: ScanNode) -> Bool {
        entries[ObjectIdentifier(node)] != nil
    }

    func children(of node: ScanNode, orderedBy precedes: (ScanNode, ScanNode) -> Bool) -> [ScanNode] {
        let key = ObjectIdentifier(node)
        if let cached = entries[key] { return cached }
        misses += 1
        let sorted = node.children.sorted(by: precedes)
        entries[key] = sorted
        return sorted
    }

    /// Installs work already performed off the main actor.
    func insert(_ children: [ScanNode], for node: ScanNode) {
        let key = ObjectIdentifier(node)
        guard entries[key] == nil else { return }
        misses += 1
        entries[key] = children
    }

    func removeAll() {
        entries.removeAll()
    }
}

@MainActor
final class DirectoryTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Below this, dispatch overhead costs more than the sort. Above it, even a
    /// few milliseconds is visible as a stuck disclosure triangle or header.
    static let backgroundSortThreshold = 1_024
    /// The four columns, in order, with the width each opens at and the width
    /// it will not go below.
    ///
    /// The pane is sized from this table rather than the other way round —
    /// see ``minimumPaneWidth`` and ``designPaneWidth`` — so the tree pane
    /// shows all four columns at every width it can be dragged to. Columns
    /// wider than the pane they live in are columns nobody can read.
    static let columnLayout: [(column: TreeColumn, width: CGFloat, minWidth: CGFloat)] = [
        (.name, 190, 100),
        (.size, 78, 66),
        (.percent, 82, 72),
        (.items, 62, 50),
    ]

    /// A dense row, from the prototype's 24 px `.trow` minus the padding a
    /// table draws for itself. The pane's job is to fit as many rows on screen
    /// as it can; nothing in a row needs more than this.
    static let rowHeight: CGFloat = 20
    static let intercellWidth: CGFloat = 4

    /// What the table spends beside its columns: one intercell gap per column,
    /// and the edge inset the full-width style draws inside. Measured from a
    /// laid-out table, and held to it by
    /// `test_atItsFloorTheTreeStillShowsEveryColumn` — a pane sized from a
    /// guess is a pane with a column hanging off its right edge.
    static let tableChromeWidth: CGFloat = intercellWidth * CGFloat(columnLayout.count) + 8

    private static func paneWidth(for widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + tableChromeWidth
    }

    /// The narrowest pane that still shows every column.
    ///
    /// Only the name column follows the pane (`firstColumnOnlyAutoresizing`),
    /// so the floor is the name at *its* minimum with the three numeric
    /// columns still at the width their figures need. Squeeze past this and
    /// the table stops shrinking and starts scrolling sideways, which is how
    /// the Items column ends up off the edge.
    static var minimumPaneWidth: CGFloat {
        paneWidth(for: columnLayout.map { $0.column == .name ? $0.minWidth : $0.width })
    }

    /// The width the columns are designed at, and so the width the pane opens
    /// at.
    static var designPaneWidth: CGFloat { paneWidth(for: columnLayout.map(\.width)) }

    let outlineView = WorkspaceOutlineView()
    private let formatter: DisplayFormatter
    private var root: ScanNode?
    private var sortColumn: TreeColumn = .size
    private var sortAscending = false
    /// The sorted child arrays AppKit is currently asking about. Internal so
    /// the tests can read its miss counter; nothing outside this target has a
    /// reason to touch it.
    let childOrder = SortedChildrenCache()
    private var isApplyingSharedSelection = false
    private var sortGeneration = 0
    private var descriptorSortTask: Task<Void, Never>?
    private var expansionSortTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// The one shared selection (spec §7.2). The tree writes it when a row is
    /// picked and follows it — expanding ancestors and scrolling — when another
    /// pane writes it.
    var selectionModel: SelectionModel? {
        didSet { observeSelection() }
    }

    /// Told when a **package** row expands or collapses, because that is the
    /// one tree state the treemap shares: drilling into a package subdivides
    /// its box (ticket 01, decision 2). Ordinary folders always subdivide, so
    /// their disclosure triangles change nothing in the map.
    var onPackageExpansionChange: ((ScanNode, Bool) -> Void)?
    var onRowActivated: ((ScanNode) -> Void)?

    /// What the pane remembers between launches: its column layout is
    /// `NSOutlineView`'s own business, its sort order is not.
    let preferences: Preferences

    init(formatter: DisplayFormatter, preferences: Preferences? = nil) {
        self.formatter = formatter
        self.preferences = preferences ?? .shared
        super.init(nibName: nil, bundle: nil)
        title = "Directory Tree"
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        // A four-column table with a header, not a source list: the source
        // list style is built for a short list of destinations, and spends the
        // row height and the inset that costs on rows that are neither.
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = Self.rowHeight
        outlineView.intercellSpacing = NSSize(width: Self.intercellWidth, height: 0)
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.headerView = NSTableHeaderView()
        // Column widths and order are remembered; which rows were open is not.
        // The tree is rebuilt from a fresh scan every time, so a remembered
        // expansion refers to nodes that no longer exist.
        outlineView.autosaveName = "MacDirStatDirectoryTree"
        outlineView.autosaveTableColumns = true
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 12
        // The name column absorbs every point the pane gains or loses, and
        // keeps that width across a disclosure: the stock behaviour widens the
        // outline column on every expand, which walks the three numeric
        // columns off the right edge one folder at a time.
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self

        for entry in Self.columnLayout {
            addColumn(entry.column, width: entry.width, minWidth: entry.minWidth)
        }
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(TreeColumn.name.rawValue))
        // Column autosave covers width and order and stops short of the sort,
        // so the sort is restored by hand. Size-descending is the fallback,
        // and the only order a first run has ever wanted.
        let sort = preferences.treeSort ?? (column: .size, ascending: false)
        outlineView.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)]

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // The pane is opaque (the prototype's `--sidebar-bg`), not the
        // vibrant material an AppKit sidebar puts behind its rows: a dense
        // table reads badly over whatever happens to be behind the window.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        outlineView.backgroundColor = .controlBackgroundColor
        scrollView.documentView = outlineView
        view = scrollView

        outlineView.onReturn = { [weak self] in self?.activateSelectedRow() }
        outlineView.onContextMenuRow = { [weak self] row in self?.selectRow(row) }
    }

    func setRoot(_ root: ScanNode?) {
        descriptorSortTask?.cancel()
        descriptorSortTask = nil
        for task in expansionSortTasks.values { task.cancel() }
        expansionSortTasks.removeAll()
        sortGeneration += 1
        self.root = root
        // Every cached array holds children of the tree that is going away.
        // Nothing may outlive the root it was sorted from.
        childOrder.removeAll()
        outlineView.reloadData()
        if root != nil { outlineView.expandItem(root) }
        reapplySharedSelection()
    }

    // MARK: - Shared selection

    private func observeSelection() {
        selectionModel?.addObserver { [weak self] change in
            guard let self, change.source != .tree else { return }
            self.apply(change.selection)
        }
    }

    private func reapplySharedSelection() {
        apply(selectionModel?.selection)
    }

    /// Follows a selection written by another pane: a node scrolls its row into
    /// view, an aggregate leaves the tree with no row selected, because §7.2
    /// forbids inventing an individual node to stand for the bucket.
    private func apply(_ selection: WorkspaceSelection?) {
        guard isViewLoaded else { return }
        isApplyingSharedSelection = true
        defer { isApplyingSharedSelection = false }

        guard let node = selection?.node else {
            outlineView.deselectAll(nil)
            return
        }
        expandAncestors(of: node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func expandAncestors(of node: ScanNode) {
        var chain: [ScanNode] = []
        var ancestor = node.parent
        while let current = ancestor {
            chain.append(current)
            ancestor = current.parent
        }
        for item in chain.reversed() {
            outlineView.expandItem(item)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSharedSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ScanNode else { return }
        selectionModel?.select(.node(node), source: .tree)
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < outlineView.numberOfRows else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Return = expand/open (§7.2): a directory-like row toggles its disclosure
    /// triangle, anything else is opened.
    func activateSelectedRow() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ScanNode else { return }
        if node.isDirectoryLike, !node.children.isEmpty {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
            return
        }
        onRowActivated?(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ScanNode, node.kind == .package else { return }
        onPackageExpansionChange?(node, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ScanNode, node.kind == .package else { return }
        onPackageExpansionChange?(node, false)
    }

    private func addColumn(_ column: TreeColumn, width: CGFloat, minWidth: CGFloat) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = column.title
        tableColumn.width = width
        tableColumn.minWidth = minWidth
        // Only the name column follows the pane; the numeric three keep the
        // width they were given so their figures stay in one place.
        tableColumn.resizingMask = column == .name
            ? [.autoresizingMask, .userResizingMask]
            : [.userResizingMask]
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .size)
        outlineView.addTableColumn(tableColumn)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return root == nil ? 0 : 1 }
        guard let node = item as? ScanNode else { return 0 }
        // How many children a node has does not depend on the order they are
        // in, and this is asked once per directory the outline view opens.
        // Sorting to read `.count` was a whole `O(N log N)` for a number the
        // array already knows.
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return root as Any }
        return childOrder.children(of: item as! ScanNode, orderedBy: precedes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ScanNode)?.children.isEmpty == false
    }

    /// A very wide folder is sorted before AppKit asks for child 0, 1, 2… .
    /// Returning false leaves the disclosure responsive; the requested expand
    /// is replayed when its order is ready.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? ScanNode,
              node.children.count >= Self.backgroundSortThreshold,
              !childOrder.contains(node) else { return true }
        prepareExpansion(of: node)
        return false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? ScanNode, let tableColumn,
              let column = TreeColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

        if column == .name {
            let identifier = NSUserInterfaceItemIdentifier("NameCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NameTableCellView)
                ?? NameTableCellView(identifier: identifier)
            cell.configure(
                name: node.name,
                icon: icon(for: node),
                badge: badge(for: node),
                spokenName: presentedName(node)
            )
            return cell
        }

        if column == .percent {
            let identifier = NSUserInterfaceItemIdentifier("PercentCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? PercentTableCellView)
                ?? PercentTableCellView(identifier: identifier)
            let parentBytes = node.parent?.subtreeDiskBytes ?? node.subtreeDiskBytes
            cell.configure(
                text: formatter.share(childBytes: node.subtreeDiskBytes, parentBytes: parentBytes),
                fraction: parentBytes > 0 ? Double(node.subtreeDiskBytes) / Double(parentBytes) : 0
            )
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("TextCell-\(column.rawValue)")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeTextCell(identifier: identifier, column: column)
        switch column {
        case .name, .percent:
            break // Both have their own cell, returned above.
        case .size:
            cell.textField?.stringValue = formatter.bytes(node.subtreeDiskBytes)
        case .items:
            // Read, not walked. The count was folded once on the scan's own
            // thread before the tree was published, so a wide folder paints its
            // rows without re-counting a subtree for each of them.
            cell.textField?.stringValue = node.isDirectoryLike
                ? formatter.count(Int64(node.presentedDescendantCount))
                : "—"
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if let descriptor = outlineView.sortDescriptors.first,
           let column = descriptor.key.flatMap(TreeColumn.init(rawValue:)) {
            preferences.treeSort = (column, descriptor.ascending)
        }
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key,
              let column = TreeColumn(rawValue: key) else { return }
        sortColumn = column
        sortAscending = descriptor.ascending
        // Every cached order was computed for the descriptor that just went
        // away. One cache for the controller's current descriptor is smaller
        // and simpler than keying every entry by (node, column, direction),
        // and the user changes sort far less often than the outline view asks
        // for a row.
        resortVisibleTree()
    }

    /// The row order for the active column and direction.
    ///
    /// Names are compared with ``NameOrder/precedes(_:_:)`` — the engine's own
    /// order, and the treemap's (spec §6.1) — rather than with `String <`, so a
    /// row and the box it is selected with never disagree about which of two
    /// siblings comes first. That is also why every other column falls back to
    /// it on a tie instead of to a localized comparison.
    private func precedes(_ lhs: ScanNode, _ rhs: ScanNode) -> Bool {
        TreeSort(column: sortColumn, ascending: sortAscending).precedes(lhs, rhs)
    }

    /// Sorts the root and every currently-open wide directory away from the
    /// event loop, then swaps all orders and reloads once. Existing rows stay
    /// usable while this runs instead of disappearing behind a busy header.
    private func resortVisibleTree() {
        descriptorSortTask?.cancel()
        for task in expansionSortTasks.values { task.cancel() }
        expansionSortTasks.removeAll()
        sortGeneration += 1
        let generation = sortGeneration
        let sort = TreeSort(column: sortColumn, ascending: sortAscending)

        var expanded: [ScanNode] = []
        if let root { expanded.append(root) }
        if outlineView.numberOfRows > 0 {
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? ScanNode,
                      outlineView.isItemExpanded(node),
                      !expanded.contains(where: { $0 === node }) else { continue }
                expanded.append(node)
            }
        }
        let wide = expanded.filter { $0.children.count >= Self.backgroundSortThreshold }
        guard !wide.isEmpty else {
            childOrder.removeAll()
            outlineView.reloadData()
            reapplySharedSelection()
            return
        }

        descriptorSortTask = Task.detached(priority: .userInitiated) { [weak self] in
            var prepared: [(ScanNode, [ScanNode])] = []
            prepared.reserveCapacity(wide.count)
            for node in wide {
                guard !Task.isCancelled else { return }
                prepared.append((node, node.children.sorted(by: sort.precedes)))
            }
            guard !Task.isCancelled else { return }
            await self?.applyPreparedSorts(prepared, expanded: expanded, generation: generation)
        }
    }

    private func applyPreparedSorts(
        _ prepared: [(ScanNode, [ScanNode])],
        expanded: [ScanNode],
        generation: Int
    ) {
        guard generation == sortGeneration else { return }
        descriptorSortTask = nil
        childOrder.removeAll()
        for (node, children) in prepared { childOrder.insert(children, for: node) }
        outlineView.reloadData()
        for node in expanded { outlineView.expandItem(node) }
        reapplySharedSelection()
    }

    private func prepareExpansion(of node: ScanNode) {
        let identifier = ObjectIdentifier(node)
        guard expansionSortTasks[identifier] == nil else { return }
        let generation = sortGeneration
        let sort = TreeSort(column: sortColumn, ascending: sortAscending)
        expansionSortTasks[identifier] = Task.detached(priority: .userInitiated) { [weak self] in
            let children = node.children.sorted(by: sort.precedes)
            guard !Task.isCancelled else { return }
            await self?.finishExpansionSort(
                children, node: node, identifier: identifier, generation: generation
            )
        }
    }

    private func finishExpansionSort(
        _ children: [ScanNode],
        node: ScanNode,
        identifier: ObjectIdentifier,
        generation: Int
    ) {
        expansionSortTasks[identifier] = nil
        guard generation == sortGeneration else { return }
        childOrder.insert(children, for: node)
        outlineView.expandItem(node)
    }

    /// A numeric cell: right-aligned, one line, and in the tabular face, so a
    /// column of figures lines up on its digits.
    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier, column: TreeColumn) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = TreeRowMetrics.valueFont
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        text.alignment = .right
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The row's read state as a tag, or `nil` when there is nothing to say.
    ///
    /// This used to be two spaces and a word glued onto the name. It read as
    /// part of the filename, it was the first thing the middle-truncation ate,
    /// and it pushed the name itself out of a column that has no width to
    /// spare (`core-workspace-prototype.html`, `.tag`).
    private func badge(for node: ScanNode) -> TreeRowBadge? {
        switch node.readState {
        case .complete:
            return node.kind == .package ? TreeRowBadge(title: "Package", tint: .controlAccentColor) : nil
        case .incomplete:
            return TreeRowBadge(title: "Incomplete", tint: .systemYellow)
        case .unreadable:
            return TreeRowBadge(title: "Unreadable", tint: .systemRed)
        }
    }

    /// The name as VoiceOver hears it. The badge is a colour and a corner
    /// radius to a sighted reader and nothing at all to anyone else, so the
    /// state stays in the spoken label.
    private func presentedName(_ node: ScanNode) -> String {
        guard let badge = badge(for: node) else { return node.name }
        return "\(node.name), \(badge.title)"
    }

    private func icon(for node: ScanNode) -> NSImage? {
        switch node.kind {
        case .directory: return NSImage(named: NSImage.folderName)
        case .package: return NSImage(named: NSImage.applicationIconName)
        case .symbolicLink: return NSImage(named: NSImage.followLinkFreestandingTemplateName)
        case .file, .other: return NSImage(named: NSImage.multipleDocumentsName)
        }
    }
}

/// The type sizes a tree row is drawn at. Smaller than the system default on
/// purpose: this pane is a table of figures, and the row it lives in is 20 pt.
enum TreeRowMetrics {
    static let nameFont = NSFont.systemFont(ofSize: 12)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let iconSide: CGFloat = 14
}

struct TreeRowBadge {
    let title: String
    let tint: NSColor
}

/// The prototype's `.tag`: a word in a tinted, rounded chip.
@MainActor
private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = TreeRowMetrics.badgeFont
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 14),
        ])
        // The chip is never what gives way: a name too long for the column is
        // truncated, and the tag beside it stays whole.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
    }

    /// The tint is a dynamic colour, so it is resolved when the layer is drawn
    /// rather than stored as a `CGColor` that would keep one appearance's value
    /// after the user switches to the other.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(_ badge: TreeRowBadge) {
        label.stringValue = badge.title
        label.textColor = badge.tint
        tint = badge.tint
        needsDisplay = true
    }
}

/// The name cell: icon, name, and — only when there is something to say — the
/// read-state tag.
@MainActor
private final class NameTableCellView: NSTableCellView {
    private let icon = NSImageView()
    private let badge = BadgeView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleProportionallyDown
        let text = NSTextField(labelWithString: "")
        text.font = TreeRowMetrics.nameFont
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.usesSingleLineMode = true
        textField = text
        imageView = icon

        let stack = NSStackView(views: [icon, text, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TreeRowMetrics.iconSide),
            icon.heightAnchor.constraint(equalToConstant: TreeRowMetrics.iconSide),
        ])
        // The name is the one part of the row that stretches and the one part
        // that is allowed to be cut short.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, icon image: NSImage?, badge model: TreeRowBadge?, spokenName: String) {
        textField?.stringValue = name
        imageView?.image = image
        // A hidden arranged subview is dropped from the stack's layout, gap
        // and all, so an unbadged row spends none of the column on it.
        badge.isHidden = model == nil
        if let model { badge.configure(model) }
        toolTip = spokenName
        setAccessibilityLabel(spokenName)
    }
}

@MainActor
private final class PercentTableCellView: NSTableCellView {
    private let bar = NSProgressIndicator()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        bar.controlSize = .small
        let text = NSTextField(labelWithString: "")
        text.font = TreeRowMetrics.valueFont
        text.textColor = .secondaryLabelColor
        text.alignment = .right
        text.lineBreakMode = .byClipping
        text.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        textField = text
        addSubview(bar)
        addSubview(text)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 30),
            bar.heightAnchor.constraint(equalToConstant: 5),
            text.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, fraction: Double) {
        textField?.stringValue = text
        bar.doubleValue = min(1, max(0, fraction))
    }
}

/// The center pane: the treemap itself, with the lifecycle overlays (empty
/// state, progress card) floating over it.
///
/// The map stays in the hierarchy while a scan runs — it is fed the incremental
/// tree behind the card, which is what "tree and treemap populate incrementally
/// behind it" means in §7.1.
@MainActor
final class TreemapPaneViewController: NSViewController {
    let emptyState = EmptyStateView()
    let scanCard = ScanProgressCardView()
    let treemapView = TreemapView(frame: NSRect(x: 0, y: 0, width: 520, height: 390))
    /// Shown when the selected entry has zero attributed bytes: it has no
    /// rectangle by design, and saying so is better than an empty map (§6.2).
    private let noRectangleNote = NSTextField(labelWithString: "")
    private var presentedPhase: ScanPhase = .empty

    override func loadView() {
        let root = BackgroundView(color: .windowBackgroundColor)

        noRectangleNote.font = .systemFont(ofSize: 11)
        noRectangleNote.textColor = .secondaryLabelColor
        noRectangleNote.lineBreakMode = .byTruncatingTail
        noRectangleNote.isHidden = true

        [treemapView, noRectangleNote, emptyState, scanCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            treemapView.topAnchor.constraint(equalTo: root.topAnchor),
            treemapView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            treemapView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            treemapView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            noRectangleNote.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            noRectangleNote.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            noRectangleNote.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.85),
            scanCard.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scanCard.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            scanCard.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.84),
            {
                let constraint = scanCard.widthAnchor.constraint(equalToConstant: 540)
                constraint.priority = .defaultHigh
                return constraint
            }(),
        ])
        scanCard.isHidden = true
        view = root
    }

    func show(_ phase: ScanPhase, progress: ProgressSnapshot?, formatter: DisplayFormatter) {
        if phase == .scanning, presentedPhase != .scanning { scanCard.reset() }
        presentedPhase = phase
        emptyState.isHidden = phase != .empty && phase != .failed
        scanCard.isHidden = phase != .scanning
        treemapView.isHidden = phase == .empty || phase == .failed
        if phase == .scanning { scanCard.update(progress: progress, formatter: formatter) }
    }

    func showNoRectangleNote(for selection: WorkspaceSelection?) {
        guard let node = selection?.node, node.subtreeDiskBytes == 0 else {
            noRectangleNote.isHidden = true
            return
        }
        noRectangleNote.stringValue =
            "“\(node.name)” has no rectangle — 0 attributed bytes. It stays listed and selectable in the tree."
        noRectangleNote.isHidden = false
    }
}

@MainActor
final class EmptyStateView: NSStackView {
    var onChoose: (() -> Void)?
    var onRescan: ((URL) -> Void)?

    /// The folder the app scanned last, offered as a second button.
    ///
    /// Relaunching never re-walks a disk on its own — a volume scan is minutes
    /// of work nobody asked for twice — but making the user find the same
    /// folder again through two sheets is the other extreme.
    var lastScannedSource: URL? {
        didSet {
            rescanButton.isHidden = lastScannedSource == nil
            guard let url = lastScannedSource else { return }
            rescanButton.title = "Scan “\(url.lastPathComponent)” Again"
            rescanButton.toolTip = url.path
        }
    }

    private let rescanButton = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 7
        let image = NSImageView(image: NSImage(named: NSImage.folderSmartName) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        let title = NSTextField(labelWithString: "See what’s using space")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Choose a folder or disk to scan.")
        subtitle.textColor = .secondaryLabelColor
        let button = NSButton(title: "Choose…", target: self, action: #selector(choose(_:)))
        button.bezelStyle = .rounded
        rescanButton.bezelStyle = .accessoryBarAction
        rescanButton.target = self
        rescanButton.action = #selector(rescan(_:))
        rescanButton.isHidden = true
        addArrangedSubview(image)
        addArrangedSubview(title)
        addArrangedSubview(subtitle)
        addArrangedSubview(button)
        addArrangedSubview(rescanButton)
        setCustomSpacing(14, after: subtitle)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func choose(_ sender: Any?) { onChoose?() }

    @objc private func rescan(_ sender: Any?) {
        guard let url = lastScannedSource else { return }
        onRescan?(url)
    }
}

@MainActor
final class ScanProgressCardView: NSVisualEffectView {
    var onCancel: (() -> Void)?
    private let currentPath = NSTextField(labelWithString: "Preparing…")
    private let progressBar = NSProgressIndicator()
    private let approximation = NSTextField(labelWithString: "")
    private let measured = NSTextField(labelWithString: "0 bytes")
    private let files = NSTextField(labelWithString: "0")
    private let folders = NSTextField(labelWithString: "0")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let throughput = NSTextField(labelWithString: "0 items/s")
    private var lastPathRefreshElapsed: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Scanning…")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        currentPath.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        currentPath.textColor = .secondaryLabelColor
        currentPath.lineBreakMode = .byTruncatingHead
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        approximation.font = .systemFont(ofSize: 11)
        approximation.textColor = .tertiaryLabelColor

        let telemetry = NSGridView(views: [[
            telemetryColumn("MEASURED", measured), telemetryColumn("FILES", files),
            telemetryColumn("FOLDERS", folders), telemetryColumn("ELAPSED", elapsed),
            telemetryColumn("THROUGHPUT", throughput),
        ]])
        telemetry.row(at: 0).height = 48

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.contentTintColor = .systemRed
        let actionRow = NSStackView(views: [NSView(), cancel])
        actionRow.orientation = .horizontal

        let stack = NSStackView(views: [title, currentPath, progressBar, approximation, telemetry, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        [currentPath, progressBar, approximation, telemetry, actionRow].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(progress: ProgressSnapshot?, formatter: DisplayFormatter) {
        guard let progress else { return }
        if lastPathRefreshElapsed == nil || progress.elapsed - (lastPathRefreshElapsed ?? 0) >= 0.25 {
            currentPath.stringValue = progress.currentPathTail
            lastPathRefreshElapsed = progress.elapsed
        }
        measured.stringValue = formatter.bytes(progress.attributedDiskBytes)
        files.stringValue = formatter.count(progress.filesSeen)
        folders.stringValue = formatter.count(progress.directoriesSeen)
        elapsed.stringValue = formatter.elapsed(progress.elapsed)
        throughput.stringValue = formatter.throughput(progress.itemsPerSecond)

        if let fraction = progress.approximateFraction {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.minValue = 0
            progressBar.maxValue = 1
            progressBar.doubleValue = fraction
            approximation.stringValue = "About \(Int((fraction * 100).rounded()))% of used space"
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            approximation.stringValue = ""
        }
    }

    func reset() {
        lastPathRefreshElapsed = nil
        currentPath.stringValue = "Preparing…"
        approximation.stringValue = ""
    }

    private func telemetryColumn(_ label: String, _ value: NSTextField) -> NSView {
        let heading = NSTextField(labelWithString: label)
        heading.font = .systemFont(ofSize: 9.5, weight: .medium)
        heading.textColor = .tertiaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [heading, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    @objc private func cancel(_ sender: Any?) { onCancel?() }
}

@MainActor
final class StatusBarViewController: NSViewController {
    private let formatter: DisplayFormatter
    private let summary = NSTextField(labelWithString: "Ready")
    private let legend = WrappingRowView()
    private var legendHeight: NSLayoutConstraint!
    var onHeightChange: ((CGFloat) -> Void)?

    init(formatter: DisplayFormatter) {
        self.formatter = formatter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = BackgroundView(color: .windowBackgroundColor)
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.translatesAutoresizingMaskIntoConstraints = false

        // The settled palette itself, so the swatch and the rectangle it
        // explains can never be two different colours (§6.3). Twelve kind
        // groups plus the merge bucket (ticket 01, decision 6).
        var entries: [(String, NSColor)] = TreemapKindGroup.allCases.map {
            ($0.displayName, TreemapChrome.legendColor(for: $0))
        }
        entries.append(("Merged", TreemapChrome.legendMergedColor))
        legend.setItems(entries.map { legendItem(name: $0.0, color: $0.1) })
        legend.translatesAutoresizingMaskIntoConstraints = false
        legend.isHidden = true
        legendHeight = legend.heightAnchor.constraint(equalToConstant: 0)

        root.addSubview(summary)
        root.addSubview(legend)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            summary.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            legend.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            // Pinned to the trailing edge, not merely kept inside it: the
            // width is what the wrap is computed from.
            legend.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            legend.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 7),
            legendHeight,
        ])
        view = root
    }

    /// What the status bar is showing, for tests and for the accessibility tree.
    var summaryText: String { summary.stringValue }

    /// The bar with the summary line and nothing else.
    static let summaryOnlyHeight: CGFloat = 26
    /// Between the summary line and the first legend row.
    private static let legendGap: CGFloat = 7

    private var showsLegend = false
    private var reportedHeight: CGFloat = summaryOnlyHeight

    /// The legend wraps, so its height depends on how wide the window is.
    override func viewDidLayout() {
        super.viewDidLayout()
        refreshHeight()
    }

    /// Reports a new height only when it actually changed: this runs from
    /// `viewDidLayout` and changes a constraint, which lays out again.
    private func refreshHeight() {
        let height: CGFloat
        if showsLegend {
            let available = max(0, view.bounds.width - 24)
            let rows = legend.height(forWidth: available)
            // Before the first layout there is no width to wrap into, and a
            // zero-height legend would report a bar with no room for it.
            guard rows > 0 else { return }
            legendHeight.constant = rows
            height = Self.summaryOnlyHeight + Self.legendGap + rows
        } else {
            legendHeight.constant = 0
            height = Self.summaryOnlyHeight
        }
        guard height != reportedHeight else { return }
        reportedHeight = height
        onHeightChange?(height)
    }

    func update(model: ScanPresentationModel) {
        let shouldShowLegend = (model.root?.subtreeDiskBytes ?? 0) > 0
        if showsLegend != shouldShowLegend {
            showsLegend = shouldShowLegend
            legend.isHidden = !shouldShowLegend
            refreshHeight()
        }

        summary.stringValue = Self.text(
            phase: model.phase,
            progress: model.progress,
            result: model.result,
            volumeCapacity: model.volumeCapacity,
            formatter: formatter
        ) ?? summary.stringValue
    }

    /// The status line as data, so what it says about a finished volume scan is
    /// a unit test rather than a screenshot. `nil` means "leave what is there" —
    /// a terminal phase with no result yet.
    ///
    /// A terminal phase is described entirely by its ``ScanResult``: the tree it
    /// carries, and the file and folder tallies the scan folded before handing
    /// it over. `volumeCapacity` stays a parameter of its own because it is a
    /// fact about the volume rather than about the scan, and the app holds it
    /// from `.started` onward.
    static func text(
        phase: ScanPhase,
        progress: ProgressSnapshot?,
        result: ScanResult?,
        volumeCapacity: VolumeCapacity?,
        formatter: DisplayFormatter
    ) -> String? {
        switch phase {
        case .empty:
            return "Ready"
        case .scanning:
            return "Scanning  ·  \(formatter.bytes(progress?.attributedDiskBytes ?? 0))  ·  \(formatter.count(progress?.filesSeen ?? 0)) files  ·  \(formatter.count(progress?.directoriesSeen ?? 0)) folders"
        case .completed, .cancelled:
            // Production always has one here: the phase is set from the
            // terminal event that carries the result.
            guard let result = result else { return nil }
            let root = result.root
            // Read, not walked. These were folded on the scan's own thread; the
            // status line is rebuilt whenever the presentation model changes,
            // and a whole-tree walk per rebuild is not something the main actor
            // can afford at two million nodes.
            let counts = result.visibleTotals
            // **The reconciliation line** (ticket 13), and it lives here rather
            // than in the inspector because it is a statement about the scan
            // and not about the item the user happens to have selected. It is
            // shown whenever a finished volume scan has a used figure to
            // compare against, including — especially — when the two agree:
            // agreement at a third of a percent is the evidence that the
            // picture is real, and it can only be read as evidence if it is
            // there every time. When they *disagree* it is because something
            // could not be read or was skipped, which is exactly when the user
            // needs to know the map is incomplete.
            var pieces: [String] = []
            if let capacity = volumeCapacity {
                pieces.append("\(formatter.bytes(root.subtreeDiskBytes)) counted")
                pieces.append("\(formatter.bytes(capacity.usedBytes)) used")
            } else {
                pieces.append(formatter.bytes(root.subtreeDiskBytes))
            }
            pieces.append("\(formatter.count(Int64(counts.files))) files")
            pieces.append("\(formatter.count(Int64(counts.folders))) folders")
            if let capacity = volumeCapacity {
                pieces.append("Capacity \(formatter.bytes(capacity.totalBytes))")
                pieces.append("Free \(formatter.bytes(capacity.availableBytes))")
            }
            if result.errors.total > 0 {
                pieces.append("\(formatter.count(Int64(result.errors.total))) errors")
            }
            if result.exclusions.total > 0 {
                pieces.append("\(formatter.count(Int64(result.exclusions.total))) excluded")
            }
            if phase == .cancelled { pieces.insert("● Incomplete — scan cancelled", at: 0) }
            return pieces.joined(separator: "  ·  ")
        case .failed:
            return "The selected source could not be scanned."
        }
    }

    private func legendItem(name: String, color: NSColor) -> NSView {
        let swatch = BackgroundView(color: color, cornerRadius: 2)
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 9),
            swatch.heightAnchor.constraint(equalToConstant: 9),
        ])
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [swatch, label])
        stack.orientation = .horizontal
        stack.spacing = 3
        return stack
    }
}

/// Lays its subviews out left to right and wraps to a new row when the next
/// one will not fit.
///
/// The legend is thirteen swatches wide. In a horizontal `NSStackView` pinned
/// with a `lessThanOrEqualTo` trailing constraint, the ones past the window's
/// edge were simply not drawn — no ellipsis, no scroll, nothing to say that a
/// colour the treemap is using has no key. Wrapping shows all of them and
/// costs the status bar a second row when it needs one.
@MainActor
final class WrappingRowView: NSView {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 4

    private var items: [NSView] = []

    /// Top-down, so the first row is the top row.
    override var isFlipped: Bool { true }

    func setItems(_ views: [NSView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        for view in views {
            // These items are framed manually in `layout()`. Leaving the
            // autoresizing mask enabled gives a freshly-created stack a
            // required zero-width constraint while `fittingSize` is solving
            // its 9 pt swatch and label, producing thousands of false layout
            // conflicts in the app test log.
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layOut(inWidth: bounds.width, placing: true)
    }

    /// The height the current items need at `width`, without moving anything.
    func height(forWidth width: CGFloat) -> CGFloat {
        layOut(inWidth: width, placing: false)
    }

    @discardableResult
    private func layOut(inWidth width: CGFloat, placing: Bool) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for item in items {
            let size = item.fittingSize
            // Never wrap the first item of a row: an item wider than the whole
            // view has to overflow somewhere, and a blank row helps nobody.
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if placing { item.frame = NSRect(x: x, y: y, width: size.width, height: size.height) }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}

/// A view that paints one colour, following the appearance.
///
/// Layer-backed on purpose. `layer.backgroundColor` takes a *resolved*
/// `CGColor`, so setting it once freezes a dynamic `NSColor` to whichever
/// appearance was current at the time — a light window under a dark system
/// paints a dark bar behind light text. Resolving it in ``updateLayer()``
/// instead re-resolves on every appearance change.
///
/// It must **not** do this by overriding `draw(_:)`: a custom-drawing
/// background view in this window's content hierarchy stops the whole split
/// view from painting — the panes lay out correctly and answer accessibility
/// queries, and the window renders empty. Measured, reproducible, and the
/// reason this is a layer and not a fill.
@MainActor
final class BackgroundView: NSView {
    private let color: NSColor
    private let cornerRadius: CGFloat

    init(color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A workspace split view, with the two things a stock one leaves to chance on
/// a dark, custom-drawn workspace: a divider you can *see*, and a resize cursor
/// over the whole band you can actually grab it by.
///
/// A 1 pt hairline over a treemap is invisible, and a divider nobody can find
/// is a divider nobody believes drags — which is exactly the report this
/// answers. The cursor rects are the same band
/// ``GrabbableSplitViewController/grabBand(forDividerAt:)`` hit-tests, so what
/// the pointer promises and what the click does are one measurement.
@MainActor
final class WorkspaceSplitView: NSSplitView {
    override var dividerColor: NSColor { .separatorColor }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let controller = delegate as? GrabbableSplitViewController else { return }
        let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        for divider in 0..<max(0, arrangedSubviews.count - 1) {
            let band = controller.grabBand(forDividerAt: divider)
            guard !band.isEmpty else { continue }
            addCursorRect(band, cursor: cursor)
        }
    }
}

/// A split view controller whose dividers can be caught by a band wider than
/// the hairline they are drawn as — in either orientation, because the
/// workspace now stacks one split view inside another (§7.2, "every split
/// divider drags").
@MainActor
class GrabbableSplitViewController: NSSplitViewController {
    /// A hairline divider is 1 pt wide, which is not a thing a pointer can
    /// reliably catch. The prototype gave every divider a few points of slop on
    /// each side (`core-workspace-prototype.html`, `.divider::after`); this is
    /// that slop, in the split view's own coordinates.
    static let dividerGrabSlop: CGFloat = 8

    /// The holding priority for the pane that keeps the size it is given while
    /// the other one takes the slack.
    ///
    /// It is one point above `.defaultLow`, which is where AppKit expects it —
    /// sidebars use exactly this. It is emphatically *not* `.defaultHigh`:
    /// holding priority is the priority of the constraint pinning the pane's
    /// thickness, and AppKit drags a divider with a constraint of its own at
    /// `.dragThatCannotResizeWindow` (492). A pane held at `.defaultHigh` (750)
    /// therefore outranks the drag and simply refuses to move — the divider
    /// looks alive, takes the cursor, and goes nowhere. It also pins the pane
    /// to its `minimumThickness` and makes `setPosition` a no-op, which is what
    /// the opening height used to be fought for.
    static let holdsItsSize = NSLayoutConstraint.Priority(260)

    override func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        grabBand(forDividerAt: dividerIndex)
    }

    /// The band the pointer may grab this divider by: the hairline, plus a few
    /// points of slop on each side. Empty when there is no divider to grab.
    func grabBand(forDividerAt dividerIndex: Int) -> NSRect {
        let divider = dividerRect(at: dividerIndex)
        guard !divider.isEmpty else { return .zero }
        return splitView.isVertical
            ? divider.insetBy(dx: -Self.dividerGrabSlop, dy: 0)
            : divider.insetBy(dx: 0, dy: -Self.dividerGrabSlop)
    }

    /// The divider's own rect. The arranged subviews abut — the hairline is
    /// drawn over their shared edge rather than in a gap between them — so the
    /// divider is `dividerThickness` centred on that edge. The edge is read off
    /// the two panes rather than assumed, so one piece of arithmetic serves a
    /// split view laid out leading-to-trailing and one laid out top-to-bottom.
    /// A collapsed pane has no divider to widen, and returns an empty rect
    /// rather than a band lying over its neighbour's content.
    private func dividerRect(at dividerIndex: Int) -> NSRect {
        let panes = splitView.arrangedSubviews
        guard dividerIndex >= 0, dividerIndex + 1 < panes.count else { return .zero }
        guard !splitViewItems[dividerIndex].isCollapsed,
              !splitViewItems[dividerIndex + 1].isCollapsed else { return .zero }
        let thickness = splitView.dividerThickness
        let first = panes[dividerIndex].frame
        let second = panes[dividerIndex + 1].frame
        if splitView.isVertical {
            let edge = (max(first.minX, second.minX) + min(first.maxX, second.maxX)) / 2
            return NSRect(
                x: edge - thickness / 2,
                y: splitView.bounds.minY,
                width: thickness,
                height: splitView.bounds.height
            )
        }
        let edge = (max(first.minY, second.minY) + min(first.maxY, second.maxY)) / 2
        return NSRect(
            x: splitView.bounds.minX,
            y: edge - thickness / 2,
            width: splitView.bounds.width,
            height: thickness
        )
    }
}

/// The workspace's top row: the file list, with the detail for whatever is
/// selected in it alongside on the right.
///
/// These two are one reading of the tree — a row, and what that row *is* — so
/// they share a row and a divider. The treemap is a different reading of the
/// same tree, and it is below them with the full width of the window to be
/// read in, because area is the only thing it has to say anything with.
@MainActor
final class ListDetailSplitViewController: GrabbableSplitViewController {
    let treeViewController: DirectoryTreeViewController
    let inspectorViewController: InspectorViewController

    init(tree: DirectoryTreeViewController, inspector: InspectorViewController) {
        treeViewController = tree
        inspectorViewController = inspector
        super.init(nibName: nil, bundle: nil)
        splitView = WorkspaceSplitView()
        splitView.isVertical = true

        // A plain pane, not an AppKit sidebar. The sidebar behaviour put a
        // vibrant material behind a dense table of figures and handed AppKit
        // its own opinion of how wide the pane should be; the tree is a
        // four-column table with a header, and it is sized by its columns.
        //
        // It is also the pane that *grows*: every point the window gains across
        // this row goes to the file names, not to a detail pane that has a
        // fixed amount to say. That is what the low holding priority buys, and
        // it is why this pane needs no opening width of its own — unlike the
        // three-across arrangement this replaced, where the map took the slack
        // and the list opened at its floor.
        let list = NSSplitViewItem(viewController: tree)
        list.minimumThickness = WorkspaceSplitViewController.treeMinimumThickness
        // Collapsing it would leave nothing to drag it back with: there is no
        // titlebar toggle for this pane, unlike the inspector.
        list.canCollapse = false
        list.holdingPriority = .defaultLow

        let detail = NSSplitViewItem(inspectorWithViewController: inspector)
        detail.minimumThickness = WorkspaceSplitViewController.inspectorMinimumThickness
        detail.maximumThickness = WorkspaceSplitViewController.inspectorMaximumThickness
        detail.preferredThicknessFraction = 300.0 / 1_100.0
        detail.canCollapse = true
        // An inspector otherwise prefers to keep its sibling fixed when it is
        // shown, which makes AppKit widen (and sometimes move) the window by
        // the inspector's width. Showing details must consume space inside the
        // existing split view instead.
        detail.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        detail.holdingPriority = GrabbableSplitViewController.holdsItsSize

        addSplitViewItem(list)
        addSplitViewItem(detail)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class WorkspaceSplitViewController: GrabbableSplitViewController,
    FileActionResponding, PathCopying, DetailPaneToggling, NSMenuItemValidation {
    let listDetailViewController: ListDetailSplitViewController
    let treeViewController: DirectoryTreeViewController
    let treemapViewController: TreemapPaneViewController
    let inspectorViewController: InspectorViewController
    let model: ScanPresentationModel
    let formatter: DisplayFormatter
    let selectionModel = SelectionModel()
    let workspaceActions: WorkspaceActing
    private let contentBuilder: InspectorContentBuilder
    /// Fired when the **scan presentation model** changes — a new phase, a new
    /// tree, new progress. Deliberately *not* fired for a selection: nothing
    /// the status bar shows depends on which row is picked, and calling it from
    /// `selectionDidChange` is what used to rebuild the whole status line on
    /// every click.
    var onScanModelChange: (() -> Void)?
    var onChooseRequest: (() -> Void)?
    /// Asked to pick the last scan up again, from the empty state.
    var onRescanRequest: ((URL) -> Void)?
    /// The folder the empty state offers to scan again, or `nil` on a machine
    /// that has never scanned anything.
    var lastScannedSource: URL? {
        didSet { treemapViewController.emptyState.lastScannedSource = lastScannedSource }
    }
    /// What this window remembers between launches, shared with its tree.
    let preferences: Preferences
    private var displayedRoot: ScanNode?
    /// What the pasteboard is written through, so a test can read it back
    /// without touching the user's clipboard.
    var pasteboard: NSPasteboard = .general

    convenience init(
        formatter: DisplayFormatter = DisplayFormatter(),
        preferences: Preferences? = nil
    ) {
        self.init(model: ScanPresentationModel(), formatter: formatter, preferences: preferences)
    }

    /// The two seams default to the real thing, constructed here rather than in
    /// a default argument: a default argument is evaluated outside the actor,
    /// and both of these are `@MainActor`.
    init(
        model: ScanPresentationModel,
        formatter: DisplayFormatter,
        workspaceActions: WorkspaceActing? = nil,
        announcer: AccessibilityAnnouncing? = nil,
        preferences: Preferences? = nil
    ) {
        let announcer = announcer ?? SystemAccessibilityAnnouncer()
        // One store for the whole window, handed down rather than looked up,
        // so a test that wants a first run gets one everywhere at once.
        let preferences = preferences ?? .shared
        self.preferences = preferences
        let tree = DirectoryTreeViewController(formatter: formatter, preferences: preferences)
        let inspector = InspectorViewController()
        let treemap = TreemapPaneViewController()
        self.model = model
        self.formatter = formatter
        self.workspaceActions = workspaceActions ?? SystemWorkspaceActions()
        contentBuilder = InspectorContentBuilder(formatter: formatter)
        treeViewController = tree
        inspectorViewController = inspector
        treemapViewController = treemap
        listDetailViewController = ListDetailSplitViewController(tree: tree, inspector: inspector)
        super.init(nibName: nil, bundle: nil)
        splitView = WorkspaceSplitView()
        // The workspace stacks: list and detail across the top, treemap across
        // the whole width below them.
        splitView.isVertical = false

        treemap.treemapView.selectionModel = selectionModel
        // Return in the map opens the selection, the same as Return on a row.
        treemap.treemapView.onActivate = { [weak self] in self?.openSelection() }
        treemap.treemapView.contentBuilder = contentBuilder
        treemap.treemapView.announcer = announcer
        tree.selectionModel = selectionModel
        tree.onPackageExpansionChange = { [weak self] node, expanded in
            self?.treemapViewController.treemapView.setPackage(node, expanded: expanded)
        }
        tree.onRowActivated = { [weak self] _ in self?.openSelection() }
        inspector.onOpen = { [weak self] in self?.openSelection() }
        inspector.onReveal = { [weak self] in self?.revealSelection() }
        selectionModel.addObserver { [weak self] change in
            self?.selectionDidChange(change)
        }

        let top = NSSplitViewItem(viewController: listDetailViewController)
        top.minimumThickness = Self.listDetailMinimumHeight
        // Neither half of the workspace collapses: there is no titlebar toggle
        // to bring either back, and a window showing only one of the two
        // readings is not the workspace §7.1 describes.
        top.canCollapse = false
        // A treemap says what it has to say with area, and says it at any size;
        // a list says it one row at a time. So the map keeps the height it is
        // given and the list takes what a taller window offers.
        top.holdingPriority = .defaultLow

        let bottom = NSSplitViewItem(viewController: treemap)
        bottom.minimumThickness = Self.treemapMinimumHeight
        bottom.canCollapse = false
        bottom.holdingPriority = Self.holdsItsSize

        addSplitViewItem(top)
        addSplitViewItem(bottom)

        model.onChange = { [weak self] in self?.refresh() }
        treemap.emptyState.onChoose = { [weak self] in self?.onChooseRequest?() }
        treemap.emptyState.onRescan = { [weak self] url in self?.onRescanRequest?(url) }
        treemap.scanCard.onCancel = { [weak model] in model?.cancel() }
        treemap.show(.empty, progress: nil, formatter: formatter)
    }

    required init?(coder: NSCoder) { nil }

    /// The file list's drag range (§7.2, "every split divider drags").
    ///
    /// The floor is the width its columns need, not a round number: a pane
    /// narrower than ``DirectoryTreeViewController/minimumPaneWidth`` is one
    /// with columns hidden off its right edge, which is what dragging this
    /// divider left used to do. There is no ceiling: the list is the pane that
    /// takes the slack, and what stops the drag right is the detail pane
    /// reaching *its* floor.
    static let treeMinimumThickness: CGFloat = DirectoryTreeViewController.minimumPaneWidth

    static let inspectorMinimumThickness: CGFloat = 260
    static let inspectorMaximumThickness: CGFloat = 360

    /// The treemap spans the window now, so its floor is a width no arrangement
    /// of the row above it can push past — the row's own two minimums added up
    /// are wider than this — and it is kept only so the constant means
    /// something if the columns above ever shrink.
    static let treemapMinimumWidth: CGFloat = 320

    /// The narrowest window the two panes of the top row both fit in at once,
    /// their divider included, and never narrower than the map below them
    /// wants. The window's minimum size is held at or above this: below it the
    /// split view has less room than its own minimums demand, and the pane that
    /// loses the argument is squeezed to nothing.
    static var minimumWorkspaceWidth: CGFloat {
        max(treeMinimumThickness + inspectorMinimumThickness + 1, treemapMinimumWidth)
    }

    /// A file list shorter than this is a handful of rows and a header, and a
    /// treemap shorter than this is a band of stripes: neither is worth the
    /// pane it is in.
    static let listDetailMinimumHeight: CGFloat = 200
    static let treemapMinimumHeight: CGFloat = 200

    /// The shortest window that holds both rows at their own minimums, with
    /// the divider between them.
    static var minimumWorkspaceHeight: CGFloat {
        listDetailMinimumHeight + treemapMinimumHeight + 12
    }

    /// The height the treemap opens at — a little under half of the window the
    /// app opens in, which is the proportion the layout sketch draws.
    static let treemapOpeningHeight: CGFloat = 320

    /// Whether the treemap has been opened at ``treemapOpeningHeight`` yet.
    ///
    /// Persisted, because the opening height is a first-run courtesy: once the
    /// split view's own autosave has a divider position to restore, placing it
    /// again would throw away the height the user chose.
    var hasPlacedTreemapDivider: Bool {
        get { preferences.hasPlacedTreemapDivider }
        set { preferences.hasPlacedTreemapDivider = newValue }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        placeTreemapDivider()
        restoreDetailPaneState()
    }

    /// Collapsing is the one split-view state `autosaveName` does not carry,
    /// so a pane hidden before quitting comes back visible without this.
    private func restoreDetailPaneState() {
        guard !hasRestoredDetailPaneState else { return }
        hasRestoredDetailPaneState = true
        listDetailViewController.splitViewItems[1].isCollapsed = preferences.isDetailPaneCollapsed
    }

    private var hasRestoredDetailPaneState = false

    /// Opens the treemap at its band, once, the first time the workspace has a
    /// height to divide.
    ///
    /// A split view controller gives the holding pane whatever its constraints
    /// say, which at first layout is its `minimumThickness` — a 200 pt strip is
    /// not a treemap. `setPosition` is what moves it, and it only moves it
    /// because the map is held at ``holdsItsSize`` rather than at
    /// `.defaultHigh`; see that constant for why the difference is the whole
    /// story. Once placed, the map keeps this height and the row above takes
    /// what a taller window offers.
    func placeTreemapDivider() {
        guard !hasPlacedTreemapDivider, splitView.bounds.height > 0 else { return }
        hasPlacedTreemapDivider = true
        splitView.setPosition(
            splitView.bounds.height - Self.treemapOpeningHeight - splitView.dividerThickness,
            ofDividerAt: 0
        )
    }

    func start(
        root: URL,
        mode: ScanMode,
        packageScanMode: PackageScanMode = .detailed
    ) {
        // A new scan invalidates every node identity the selection could name.
        selectionModel.clear()
        treemapViewController.treemapView.resetPackageExpansion()
        model.start(root: root, mode: mode, packageScanMode: packageScanMode)
    }

    /// The facts a selection is described against. `nil` until a scan has a
    /// root, which is exactly when nothing is selectable.
    var selectionContext: SelectionContext? {
        guard let rootURL = model.rootURL, let rootNode = model.root else { return nil }
        return SelectionContext(
            rootURL: rootURL,
            rootNode: rootNode,
            volumeCapacity: model.volumeCapacity,
            isVolumeScan: model.mode == .volumeRoot
        )
    }

    /// The absolute URL for the current selection, rebuilt from the node's
    /// parent chain on demand (spec §5.2, §10). An aggregate has no URL: it is
    /// not a file.
    var selectedURL: URL? {
        guard let node = selectionModel.selection?.node, let rootURL = model.rootURL else { return nil }
        return node.url(root: rootURL)
    }

    func openSelection() {
        guard let url = selectedURL else { return }
        workspaceActions.open(url)
    }

    func revealSelection() {
        guard let url = selectedURL else { return }
        workspaceActions.reveal(url)
    }

    @objc func openSelectedItem(_ sender: Any?) { openSelection() }

    @objc func revealSelectedItem(_ sender: Any?) { revealSelection() }

    /// Puts the selected item's path on the pasteboard.
    ///
    /// The detail pane has always shown the full path and there was no way to
    /// get it out of the app. This writes a string; it does not touch the file.
    @objc func copySelectedPath(_ sender: Any?) {
        guard let url = selectedURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    /// Shows or hides the detail pane.
    ///
    /// The pane collapses, and until this existed nothing brought it back:
    /// there is no disclosure control on a collapsed split view item.
    @objc func toggleDetailPane(_ sender: Any?) {
        let item = listDetailViewController.splitViewItems[1]
        let collapsed = !item.isCollapsed
        let window = view.window
        let frame = window?.frame
        // `collapseBehavior` on the item makes this redistribute only the
        // space inside the split view. Preserve the frame as an absolute
        // boundary as well: some AppKit versions still apply the inspector's
        // standard window expansion before resolving the split constraints.
        item.isCollapsed = collapsed
        if let window, let frame, window.frame != frame {
            window.setFrame(frame, display: false)
        }
        preferences.isDetailPaneCollapsed = collapsed
    }

    var isDetailPaneCollapsed: Bool {
        listDetailViewController.splitViewItems[1].isCollapsed
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSelectedItem(_:)), #selector(revealSelectedItem(_:)),
             #selector(copySelectedPath(_:)):
            // Nothing to act on is the only reason any of them is ever
            // disabled; there is no state in which a mutating command becomes
            // available. An aggregate is not a file, so it has no path either.
            return selectedURL != nil
        case #selector(toggleDetailPane(_:)):
            // Always available, and says which way it will go.
            menuItem.title = isDetailPaneCollapsed
                ? MainMenu.showDetailsTitle
                : MainMenu.hideDetailsTitle
            return true
        default:
            return true
        }
    }

    private func selectionDidChange(_ change: SelectionChange) {
        refreshInspector()
        treemapViewController.showNoRectangleNote(for: change.selection)
    }

    private func refreshInspector() {
        guard let context = selectionContext else {
            inspectorViewController.content = nil
            return
        }
        guard let selection = selectionModel.selection else {
            // Nothing selected — the state the window is in the moment a scan
            // finishes. If that scan left anything unread or skipped, this is
            // where the status bar's counts get their names.
            inspectorViewController.content = model.result.flatMap {
                contentBuilder.scanSummary(result: $0, in: context)
            }
            return
        }
        inspectorViewController.content = contentBuilder.content(for: selection, in: context)
    }

    private func refresh() {
        if let root = model.root {
            if displayedRoot !== root {
                displayedRoot = root
                treeViewController.setRoot(root)
            }
        } else if displayedRoot != nil {
            displayedRoot = nil
            treeViewController.setRoot(nil)
        }
        // The treemap is fed the same tree the outline view is, so the two
        // panes are never describing different trees.
        treemapViewController.treemapView.context = selectionContext
        treemapViewController.treemapView.setRoot(model.root)
        treemapViewController.show(model.phase, progress: model.progress, formatter: formatter)
        refreshInspector()
        onScanModelChange?()
    }
}

@MainActor
final class WorkspaceContainerViewController: NSViewController {
    /// A scroll view touching the content edge is mirrored into the floating
    /// titlebar on Tahoe. A physical one-point boundary opts the dense table
    /// out of that edge-to-edge treatment while remaining visually covered by
    /// the window's native separator.
    static let titlebarContentSeparation: CGFloat = 1

    let workspace: WorkspaceSplitViewController
    let statusBar: StatusBarViewController
    private var statusHeight: NSLayoutConstraint!

    init(workspace: WorkspaceSplitViewController, statusBar: StatusBarViewController) {
        self.workspace = workspace
        self.statusBar = statusBar
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 700))
        addChild(workspace)
        addChild(statusBar)
        let split = workspace.view
        let status = statusBar.view
        split.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        root.addSubview(status)
        statusHeight = status.heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: Self.titlebarContentSeparation
            ),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusHeight,
        ])
        statusBar.onHeightChange = { [weak self] height in
            self?.statusHeight.constant = height
        }
        view = root
    }
}
