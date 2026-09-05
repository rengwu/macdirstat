import AppKit
import ScanCore

enum SourceEligibility: Equatable {
    case eligible
    case ineligible(reason: String)
}

struct VolumeSourceFacts: Equatable {
    let url: URL
    let name: String
    var isLocal: Bool
    var isInternal: Bool
    var isRemovable: Bool
    var isUbiquitous: Bool
    var isDiskImage: Bool
    var totalCapacity: Int64?
    var availableCapacity: Int64?

    init(
        url: URL,
        name: String,
        isLocal: Bool,
        isInternal: Bool = false,
        isRemovable: Bool = false,
        isUbiquitous: Bool = false,
        isDiskImage: Bool = false,
        totalCapacity: Int64? = nil,
        availableCapacity: Int64? = nil
    ) {
        self.url = url
        self.name = name
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isUbiquitous = isUbiquitous
        self.isDiskImage = isDiskImage
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}

struct SourceChoice: Equatable {
    let url: URL
    let name: String
    let detail: String
    let eligibility: SourceEligibility
    let totalCapacity: Int64?
    let availableCapacity: Int64?
}

enum SourceChooserModel {
    static func classify(_ facts: VolumeSourceFacts) -> SourceChoice {
        let eligibility: SourceEligibility
        if !facts.isLocal {
            eligibility = .ineligible(reason: "Network volumes aren’t supported.")
        } else if facts.isUbiquitous {
            eligibility = .ineligible(reason: "Cloud storage roots aren’t supported.")
        } else if facts.isDiskImage {
            eligibility = .ineligible(reason: "Disk images aren’t supported.")
        } else {
            eligibility = .eligible
        }

        let detail: String
        if facts.isInternal {
            detail = "Internal disk"
        } else if facts.isLocal {
            detail = "External disk"
        } else {
            detail = "Network volume"
        }
        return SourceChoice(
            url: facts.url,
            name: facts.name,
            detail: detail,
            eligibility: eligibility,
            totalCapacity: facts.totalCapacity,
            availableCapacity: facts.availableCapacity
        )
    }

    /// The accepted prototype intentionally hides ineligible sources. Their
    /// classifications remain explicit and unit-testable at the model seam.
    static func visibleChoices(from candidates: [VolumeSourceFacts]) -> [SourceChoice] {
        candidates.map(classify).filter { $0.eligibility == .eligible }
    }

    static func mountedVolumeFacts(fileManager: FileManager = .default) -> [VolumeSourceFacts] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .isUbiquitousItemKey,
        ]
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return VolumeSourceFacts(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isLocal: values.volumeIsLocal ?? true,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isUbiquitous: values.isUbiquitousItem ?? false,
                // Big Sur has no reliable first-party resource key for a
                // directly selected disk-image volume; the accepted spec
                // records this residual gap instead of guessing.
                isDiskImage: false,
                totalCapacity: values.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values.volumeAvailableCapacity.map(Int64.init)
            )
        }
    }
}

@MainActor
final class SourceChooserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSearch: ((URL, ScanMode) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onCancel: (() -> Void)?

    private let choices: [SourceChoice]
    private var folderURL: URL?
    private let emptyLabel = NSTextField(labelWithString: "No eligible disks are mounted. Choose a folder below.")
    let sourceTable = NSTableView()
    let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let fastModeCheckbox = NSButton(
        checkboxWithTitle: "Fast mode",
        target: nil,
        action: nil
    )

    var packageScanMode: PackageScanMode {
        fastModeCheckbox.state == .on ? .summarized : .detailed
    }

    init(choices: [SourceChoice], packageScanMode: PackageScanMode = .detailed) {
        self.choices = choices
        super.init(nibName: nil, bundle: nil)
        fastModeCheckbox.state = packageScanMode == .summarized ? .on : .off
        preferredContentSize = NSSize(width: 520, height: 350)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Choose a Source")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Select a disk or folder, then click Search.")
        subtitle.textColor = .secondaryLabelColor

        let sourceList = NSBox()
        sourceList.boxType = .custom
        sourceList.titlePosition = .noTitle
        sourceList.cornerRadius = 10
        sourceList.borderColor = .separatorColor
        sourceList.borderWidth = 1
        sourceList.fillColor = .controlBackgroundColor
        sourceList.contentViewMargins = .zero
        let listContent = sourceList.contentView!

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        sourceTable.addTableColumn(column)
        sourceTable.headerView = nil
        sourceTable.style = .inset
        sourceTable.rowHeight = 56
        sourceTable.intercellSpacing = NSSize(width: 0, height: 4)
        sourceTable.backgroundColor = .clear
        sourceTable.allowsMultipleSelection = false
        sourceTable.allowsEmptySelection = true
        sourceTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sourceTable.dataSource = self
        sourceTable.delegate = self
        sourceTable.setAccessibilityLabel("Sources")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = sourceTable

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = !choices.isEmpty

        let divider = NSBox()
        divider.boxType = .separator
        let folder = NSButton(title: "  Choose Folder…", target: self, action: #selector(chooseFolder(_:)))
        folder.setAccessibilityLabel("Choose Folder…")
        folder.isBordered = false
        folder.alignment = .left
        folder.font = .systemFont(ofSize: 13, weight: .medium)
        folder.contentTintColor = .controlAccentColor
        folder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        folder.imagePosition = .imageLeading
        folder.imageHugsTitle = true
        folder.toolTip = "Add a folder to the sources above"

        [scrollView, emptyLabel, divider, folder].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            listContent.addSubview($0)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: listContent.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -4),
            scrollView.heightAnchor.constraint(equalToConstant: CGFloat(min(4, max(2, choices.count + 1))) * 60 + 24),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -12),
            folder.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            folder.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 16),
            folder.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -16),
            folder.heightAnchor.constraint(equalToConstant: 36),
            folder.bottomAnchor.constraint(equalTo: listContent.bottomAnchor, constant: -4),
        ])

        fastModeCheckbox.toolTip = "Measure each app as one item without building its internal file tree."
        let fastModeDetail = NSTextField(labelWithString: "Summarize app bundles without showing their contents.")
        fastModeDetail.font = .systemFont(ofSize: 11)
        fastModeDetail.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        searchButton.target = self
        searchButton.action = #selector(searchPressed(_:))
        searchButton.bezelStyle = .rounded
        searchButton.keyEquivalent = "\r"
        searchButton.isEnabled = false
        let buttons = NSStackView(views: [cancel, searchButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        [title, subtitle, sourceList, fastModeCheckbox, fastModeDetail, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sourceList.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            sourceList.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            sourceList.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            fastModeCheckbox.topAnchor.constraint(equalTo: sourceList.bottomAnchor, constant: 18),
            fastModeCheckbox.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            fastModeDetail.topAnchor.constraint(equalTo: fastModeCheckbox.bottomAnchor, constant: 2),
            fastModeDetail.leadingAnchor.constraint(equalTo: fastModeCheckbox.leadingAnchor, constant: 20),
            buttons.topAnchor.constraint(equalTo: fastModeDetail.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            searchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            root.widthAnchor.constraint(equalToConstant: preferredContentSize.width),
        ])
        view = root
        preferredContentSize = root.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(sourceTable)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        choices.count + (folderURL == nil ? 0 : 1)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isVolume = row < choices.count
        let url = isVolume ? choices[row].url : folderURL!
        let name = isVolume ? choices[row].name : FileManager.default.displayName(atPath: url.path)
        let detail = isVolume ? choices[row].detail : url.path
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        cell.imageView = icon
        cell.textField = title
        cell.toolTip = url.path
        [icon, title, subtitle].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        searchButton.isEnabled = sourceTable.selectedRow >= 0
    }

    /// Browsing only updates the selection. Search is the sole scan trigger.
    func selectFolder(_ url: URL) {
        loadViewIfNeeded()
        folderURL = url
        emptyLabel.isHidden = true
        sourceTable.reloadData()
        sourceTable.selectRowIndexes(IndexSet(integer: choices.count), byExtendingSelection: false)
        sourceTable.scrollRowToVisible(choices.count)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc private func searchPressed(_ sender: Any?) {
        let row = sourceTable.selectedRow
        guard row >= 0 else { return }
        if row < choices.count {
            onSearch?(choices[row].url, .volumeRoot)
        } else if let folderURL {
            onSearch?(folderURL, .folder)
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        onChooseFolder?()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        cancelOperation(sender)
    }
}
