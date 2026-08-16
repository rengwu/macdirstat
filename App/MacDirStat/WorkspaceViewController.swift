import AppKit
import ScanCore

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

@MainActor
final class DirectoryTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = NSOutlineView()
    private let formatter: DisplayFormatter
    private var root: ScanNode?
    private var sortColumn: TreeColumn = .size
    private var sortAscending = false

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
    }

    func setRoot(_ root: ScanNode?) {
        self.root = root
        outlineView.reloadData()
        if root != nil { outlineView.expandItem(root) }
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
            let parentBytes = node.parent?.subtreeBytes ?? node.subtreeBytes
            cell.configure(
                text: formatter.share(childBytes: node.subtreeBytes, parentBytes: parentBytes),
                fraction: parentBytes > 0 ? Double(node.subtreeBytes) / Double(parentBytes) : 0
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
            cell.textField?.stringValue = formatter.bytes(node.subtreeBytes)
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

    private func sortedChildren(of node: ScanNode) -> [ScanNode] {
        node.children.sorted { lhs, rhs in
            switch sortColumn {
            case .name:
                return sortAscending ? lhs.name < rhs.name : lhs.name > rhs.name
            case .size:
                if lhs.subtreeBytes == rhs.subtreeBytes { return lhs.name < rhs.name }
                return sortAscending ? lhs.subtreeBytes < rhs.subtreeBytes : lhs.subtreeBytes > rhs.subtreeBytes
            case .percent:
                if lhs.subtreeBytes == rhs.subtreeBytes { return lhs.name < rhs.name }
                return sortAscending ? lhs.subtreeBytes < rhs.subtreeBytes : lhs.subtreeBytes > rhs.subtreeBytes
            case .items:
                let left = VisibleTreeCounts.countItems(beneath: lhs)
                let right = VisibleTreeCounts.countItems(beneath: rhs)
                if left == right { return lhs.name < rhs.name }
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

@MainActor
final class TreemapPlaceholderViewController: NSViewController {
    let emptyState = EmptyStateView()
    let scanCard = ScanProgressCardView()
    private let placeholder = NSTextField(labelWithString: "Treemap")
    private var presentedPhase: ScanPhase = .empty

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 18, weight: .medium)

        [placeholder, emptyState, scanCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
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
        placeholder.isHidden = phase == .empty || phase == .failed
        if phase == .scanning { scanCard.update(progress: progress, formatter: formatter) }
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
    private let throughput = NSTextField(labelWithString: "0 bytes/s")
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
        measured.stringValue = formatter.bytes(progress.attributedBytes)
        files.stringValue = formatter.count(progress.filesSeen)
        folders.stringValue = formatter.count(progress.directoriesSeen)
        elapsed.stringValue = formatter.elapsed(progress.elapsed)
        throughput.stringValue = formatter.throughput(progress.bytesPerSecond)

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
final class InspectorPlaceholderViewController: NSViewController {
    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let label = NSTextField(wrappingLabelWithString: "Select an item to see its details.")
        label.alignment = .center
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -50),
        ])
        view = root
    }
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
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.translatesAutoresizingMaskIntoConstraints = false

        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.spacing = 8
        let entries: [(String, NSColor)] = [
            ("Media", .systemRed), ("Archives", .systemOrange), ("Apps", .systemYellow),
            ("Fonts", .systemGreen), ("Documents", .systemTeal),
            ("Data", NSColor(calibratedHue: 0.5, saturation: 0.55, brightness: 0.72, alpha: 1)),
            ("Code", .systemBlue), ("System", .systemIndigo), ("Images", .systemPurple),
            ("Audio", .systemPink), ("Video", .systemBrown), ("Other", .systemGray),
            ("Merged", .tertiaryLabelColor),
        ]
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

    func update(model: ScanPresentationModel) {
        let shouldShowLegend = (model.root?.subtreeBytes ?? 0) > 0
        if legend.isHidden == shouldShowLegend {
            legend.isHidden = !shouldShowLegend
            onHeightChange?(shouldShowLegend ? 52 : 26)
        }

        switch model.phase {
        case .empty:
            summary.stringValue = "Ready"
        case .scanning:
            let progress = model.progress
            summary.stringValue = "Scanning  ·  \(formatter.bytes(progress?.attributedBytes ?? 0))  ·  \(formatter.count(progress?.filesSeen ?? 0)) files  ·  \(formatter.count(progress?.directoriesSeen ?? 0)) folders"
        case .completed, .cancelled:
            guard let root = model.root else { return }
            let counts = VisibleTreeCounts.totals(in: root)
            var pieces = [
                formatter.bytes(root.subtreeBytes),
                "\(formatter.count(Int64(counts.files))) files",
                "\(formatter.count(Int64(counts.folders))) folders",
            ]
            if let capacity = model.volumeCapacity {
                pieces.append("Capacity \(formatter.bytes(capacity.totalBytes))")
                pieces.append("Free \(formatter.bytes(capacity.availableBytes))")
            }
            if let result = model.result, result.errors.total > 0 {
                pieces.append("\(formatter.count(Int64(result.errors.total))) errors")
            }
            if let result = model.result, result.exclusions.total > 0 {
                pieces.append("\(formatter.count(Int64(result.exclusions.total))) excluded")
            }
            if model.phase == .cancelled { pieces.insert("● Incomplete — scan cancelled", at: 0) }
            summary.stringValue = pieces.joined(separator: "  ·  ")
        case .failed:
            summary.stringValue = "The selected source could not be scanned."
        }
    }

    private func legendItem(name: String, color: NSColor) -> NSView {
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = 2
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

@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
    let treeViewController: DirectoryTreeViewController
    let treemapViewController = TreemapPlaceholderViewController()
    let inspectorViewController = InspectorPlaceholderViewController()
    let model: ScanPresentationModel
    let formatter: DisplayFormatter
    var onModelChange: (() -> Void)?
    var onChooseRequest: (() -> Void)?
    private var displayedRoot: ScanNode?

    convenience init(formatter: DisplayFormatter = DisplayFormatter()) {
        self.init(model: ScanPresentationModel(), formatter: formatter)
    }

    init(model: ScanPresentationModel, formatter: DisplayFormatter) {
        self.model = model
        self.formatter = formatter
        treeViewController = DirectoryTreeViewController(formatter: formatter)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true

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
        model.start(root: root, mode: mode)
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
        treemapViewController.show(model.phase, progress: model.progress, formatter: formatter)
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
