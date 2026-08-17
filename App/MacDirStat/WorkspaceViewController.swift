import AppKit
import ScanCore
import TreemapLayout

enum TreeColumn: String {
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

@MainActor
final class DirectoryTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = WorkspaceOutlineView()
    private let formatter: DisplayFormatter
    private var root: ScanNode?
    private var sortColumn: TreeColumn = .size
    private var sortAscending = false
    private var isApplyingSharedSelection = false

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

    init(formatter: DisplayFormatter) {
        self.formatter = formatter
        super.init(nibName: nil, bundle: nil)
        title = "Directory Tree"
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.headerView = NSTableHeaderView()
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self

        addColumn(.name, width: 220, minWidth: 150)
        addColumn(.size, width: 90, minWidth: 76)
        addColumn(.percent, width: 116, minWidth: 96)
        addColumn(.items, width: 72, minWidth: 62)
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(TreeColumn.name.rawValue))
        outlineView.sortDescriptors = [NSSortDescriptor(key: TreeColumn.size.rawValue, ascending: false)]

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = outlineView
        view = scrollView

        outlineView.onReturn = { [weak self] in self?.activateSelectedRow() }
        outlineView.onContextMenuRow = { [weak self] row in self?.selectRow(row) }
    }

    func setRoot(_ root: ScanNode?) {
        self.root = root
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
        tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .size)
        outlineView.addTableColumn(tableColumn)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return root == nil ? 0 : 1 }
        guard let node = item as? ScanNode else { return 0 }
        return sortedChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return root as Any }
        return sortedChildren(of: item as! ScanNode)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ScanNode)?.children.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? ScanNode, let tableColumn,
              let column = TreeColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

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
        case .name:
            cell.textField?.stringValue = presentedName(node)
            cell.imageView?.image = icon(for: node)
        case .size:
            cell.textField?.stringValue = formatter.bytes(node.subtreeDiskBytes)
        case .items:
            cell.textField?.stringValue = node.isDirectoryLike
                ? formatter.count(Int64(VisibleTreeCounts.countItems(beneath: node)))
                : "—"
        case .percent:
            break
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key,
              let column = TreeColumn(rawValue: key) else { return }
        sortColumn = column
        sortAscending = descriptor.ascending
        outlineView.reloadData()
    }

    /// Names are compared with ``NameOrder/precedes(_:_:)`` — the engine's own
    /// order, and the treemap's (spec §6.1) — rather than with `String <`, so a
    /// row and the box it is selected with never disagree about which of two
    /// siblings comes first.
    private func sortedChildren(of node: ScanNode) -> [ScanNode] {
        node.children.sorted { lhs, rhs in
            switch sortColumn {
            case .name:
                return sortAscending
                    ? NameOrder.precedes(lhs.name, rhs.name)
                    : NameOrder.precedes(rhs.name, lhs.name)
            case .size:
                if lhs.subtreeDiskBytes == rhs.subtreeDiskBytes { return NameOrder.precedes(lhs.name, rhs.name) }
                return sortAscending ? lhs.subtreeDiskBytes < rhs.subtreeDiskBytes : lhs.subtreeDiskBytes > rhs.subtreeDiskBytes
            case .percent:
                if lhs.subtreeDiskBytes == rhs.subtreeDiskBytes { return NameOrder.precedes(lhs.name, rhs.name) }
                return sortAscending ? lhs.subtreeDiskBytes < rhs.subtreeDiskBytes : lhs.subtreeDiskBytes > rhs.subtreeDiskBytes
            case .items:
                let left = VisibleTreeCounts.countItems(beneath: lhs)
                let right = VisibleTreeCounts.countItems(beneath: rhs)
                if left == right { return NameOrder.precedes(lhs.name, rhs.name) }
                return sortAscending ? left < right : left > right
            }
        }
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier, column: TreeColumn) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.alignment = column == .name ? .left : .right
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text
        cell.addSubview(text)

        if column == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.imageView = image
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    private func presentedName(_ node: ScanNode) -> String {
        switch node.readState {
        case .complete:
            return node.kind == .package ? "\(node.name)  Package" : node.name
        case .incomplete:
            return "\(node.name)  Incomplete"
        case .unreadable:
            return "\(node.name)  Unreadable"
        }
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
        text.alignment = .right
        text.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        textField = text
        addSubview(bar)
        addSubview(text)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 42),
            bar.heightAnchor.constraint(equalToConstant: 6),
            text.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 5),
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

enum VisibleTreeCounts {
    static func countItems(beneath node: ScanNode) -> Int {
        var count = 0
        var stack = node.children
        while let current = stack.popLast() {
            count += 1
            if current.kind != .package { stack.append(contentsOf: current.children) }
        }
        return count
    }

    static func totals(in root: ScanNode) -> (files: Int, folders: Int) {
        var files = 0
        var folders = 0
        var stack = root.children
        while let current = stack.popLast() {
            switch current.kind {
            case .directory:
                folders += 1
                stack.append(contentsOf: current.children)
            case .package, .file, .symbolicLink, .other:
                files += 1
                if current.kind != .package { stack.append(contentsOf: current.children) }
            }
        }
        return (files, folders)
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
        addArrangedSubview(image)
        addArrangedSubview(title)
        addArrangedSubview(subtitle)
        addArrangedSubview(button)
        setCustomSpacing(14, after: subtitle)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func choose(_ sender: Any?) { onChoose?() }
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
    private let legend = NSStackView()
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

        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.spacing = 8
        // The settled palette itself, so the swatch and the rectangle it
        // explains can never be two different colours (§6.3). Twelve kind
        // groups plus the merge bucket (ticket 01, decision 6).
        var entries: [(String, NSColor)] = TreemapKindGroup.allCases.map {
            ($0.displayName, TreemapChrome.legendColor(for: $0))
        }
        entries.append(("Merged", TreemapChrome.legendMergedColor))
        entries.forEach { legend.addArrangedSubview(legendItem(name: $0.0, color: $0.1)) }
        legend.translatesAutoresizingMaskIntoConstraints = false
        legend.isHidden = true

        root.addSubview(summary)
        root.addSubview(legend)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            summary.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            legend.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            legend.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 7),
        ])
        view = root
    }

    /// What the status bar is showing, for tests and for the accessibility tree.
    var summaryText: String { summary.stringValue }

    func update(model: ScanPresentationModel) {
        let shouldShowLegend = (model.root?.subtreeDiskBytes ?? 0) > 0
        if legend.isHidden == shouldShowLegend {
            legend.isHidden = !shouldShowLegend
            onHeightChange?(shouldShowLegend ? 52 : 26)
        }

        summary.stringValue = Self.text(
            phase: model.phase,
            root: model.root,
            progress: model.progress,
            result: model.result,
            volumeCapacity: model.volumeCapacity,
            formatter: formatter
        ) ?? summary.stringValue
    }

    /// The status line as data, so what it says about a finished volume scan is
    /// a unit test rather than a screenshot. `nil` means "leave what is there" —
    /// a terminal phase with no tree yet.
    static func text(
        phase: ScanPhase,
        root: ScanNode?,
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
            guard let root = root else { return nil }
            let counts = VisibleTreeCounts.totals(in: root)
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
            if let result = result, result.errors.total > 0 {
                pieces.append("\(formatter.count(Int64(result.errors.total))) errors")
            }
            if let result = result, result.exclusions.total > 0 {
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

@MainActor
final class WorkspaceSplitViewController: NSSplitViewController, FileActionResponding, NSMenuItemValidation {
    let treeViewController: DirectoryTreeViewController
    let treemapViewController = TreemapPaneViewController()
    let inspectorViewController = InspectorViewController()
    let model: ScanPresentationModel
    let formatter: DisplayFormatter
    let selectionModel = SelectionModel()
    let workspaceActions: WorkspaceActing
    private let contentBuilder: InspectorContentBuilder
    var onModelChange: (() -> Void)?
    var onChooseRequest: (() -> Void)?
    private var displayedRoot: ScanNode?

    convenience init(formatter: DisplayFormatter = DisplayFormatter()) {
        self.init(model: ScanPresentationModel(), formatter: formatter)
    }

    /// The two seams default to the real thing, constructed here rather than in
    /// a default argument: a default argument is evaluated outside the actor,
    /// and both of these are `@MainActor`.
    init(
        model: ScanPresentationModel,
        formatter: DisplayFormatter,
        workspaceActions: WorkspaceActing? = nil,
        announcer: AccessibilityAnnouncing? = nil
    ) {
        let announcer = announcer ?? SystemAccessibilityAnnouncer()
        self.model = model
        self.formatter = formatter
        self.workspaceActions = workspaceActions ?? SystemWorkspaceActions()
        contentBuilder = InspectorContentBuilder(formatter: formatter)
        treeViewController = DirectoryTreeViewController(formatter: formatter)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true

        treemapViewController.treemapView.selectionModel = selectionModel
        treemapViewController.treemapView.contentBuilder = contentBuilder
        treemapViewController.treemapView.announcer = announcer
        treeViewController.selectionModel = selectionModel
        treeViewController.onPackageExpansionChange = { [weak self] node, expanded in
            self?.treemapViewController.treemapView.setPackage(node, expanded: expanded)
        }
        treeViewController.onRowActivated = { [weak self] _ in self?.openSelection() }
        inspectorViewController.onOpen = { [weak self] in self?.openSelection() }
        inspectorViewController.onReveal = { [weak self] in self?.revealSelection() }
        selectionModel.addObserver { [weak self] change in
            self?.selectionDidChange(change)
        }

        let left = NSSplitViewItem(sidebarWithViewController: treeViewController)
        left.minimumThickness = 240
        left.maximumThickness = 520
        left.holdingPriority = .defaultHigh

        let center = NSSplitViewItem(viewController: treemapViewController)
        center.minimumThickness = 320
        center.canCollapse = false
        center.holdingPriority = .defaultLow

        let right = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        right.minimumThickness = 260
        right.maximumThickness = 360
        right.preferredThicknessFraction = 300.0 / 1_100.0
        right.canCollapse = true
        right.holdingPriority = .defaultHigh

        addSplitViewItem(left)
        addSplitViewItem(center)
        addSplitViewItem(right)

        model.onChange = { [weak self] in self?.refresh() }
        treemapViewController.emptyState.onChoose = { [weak self] in self?.onChooseRequest?() }
        treemapViewController.scanCard.onCancel = { [weak model] in model?.cancel() }
        treemapViewController.show(.empty, progress: nil, formatter: formatter)
    }

    required init?(coder: NSCoder) { nil }

    func start(root: URL, mode: ScanMode) {
        // A new scan invalidates every node identity the selection could name.
        selectionModel.clear()
        treemapViewController.treemapView.resetPackageExpansion()
        model.start(root: root, mode: mode)
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSelectedItem(_:)), #selector(revealSelectedItem(_:)):
            // Nothing to act on is the only reason either is ever disabled;
            // there is no state in which a third command becomes available.
            return selectedURL != nil
        default:
            return true
        }
    }

    private func selectionDidChange(_ change: SelectionChange) {
        refreshInspector()
        treemapViewController.showNoRectangleNote(for: change.selection)
        onModelChange?()
    }

    private func refreshInspector() {
        guard let selection = selectionModel.selection, let context = selectionContext else {
            inspectorViewController.content = nil
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
        // The treemap is fed the same frozen snapshot the tree is, so the two
        // panes are never describing different trees.
        treemapViewController.treemapView.context = selectionContext
        treemapViewController.treemapView.setRoot(model.root)
        treemapViewController.show(model.phase, progress: model.progress, formatter: formatter)
        refreshInspector()
        onModelChange?()
    }
}

@MainActor
final class WorkspaceContainerViewController: NSViewController {
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
            split.topAnchor.constraint(equalTo: root.topAnchor),
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
