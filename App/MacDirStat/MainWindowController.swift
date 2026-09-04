import AppKit
import ScanCore

final class MainWindowController: NSWindowController, ScanSourceChoosing, ScanHelpPresenting {
    let workspaceViewController: WorkspaceSplitViewController
    let statusBarController: StatusBarViewController
    let preferences: Preferences
    let scanNotifier: ScanCompletionNotifying

    convenience init() {
        self.init(preferences: .shared)
    }

    /// A window with a store of its own.
    ///
    /// The persisted facts here — that the treemap has been placed once, which
    /// folders were scanned — are per *installation*, so a test that wants a
    /// first run has to be given one rather than sharing the process's.
    convenience init(preferences: Preferences) {
        let formatter = DisplayFormatter()
        let workspace = WorkspaceSplitViewController(formatter: formatter, preferences: preferences)
        let status = StatusBarViewController(formatter: formatter)
        self.init(workspace: workspace, statusBar: status, preferences: preferences)
    }

    init(
        workspace: WorkspaceSplitViewController,
        statusBar: StatusBarViewController,
        preferences: Preferences? = nil,
        scanNotifier: ScanCompletionNotifying? = nil
    ) {
        let preferences = preferences ?? .shared
        workspaceViewController = workspace
        statusBarController = statusBar
        self.preferences = preferences
        // Constructed here rather than in a default argument: a default
        // argument is evaluated outside the actor, and this is `@MainActor`.
        self.scanNotifier = scanNotifier ?? SystemScanCompletionNotifier()
        let contentViewController = WorkspaceContainerViewController(workspace: workspace, statusBar: statusBar)

        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "MacDirStat"
        // Wide and tall enough for every pane at its own minimum. A window
        // smaller than the split views' minimums added up to is a window no
        // arrangement of the panes satisfies — and the dividers stop moving,
        // because there is nothing left to move them into.
        window.minSize = NSSize(
            width: max(720, WorkspaceSplitViewController.minimumWorkspaceWidth),
            height: max(480, WorkspaceSplitViewController.minimumWorkspaceHeight)
        )
        window.center()
        window.setFrameAutosaveName("MacDirStatMainWindow")
        // The frame was already remembered; the dividers inside it were not.
        workspace.splitView.autosaveName = "MacDirStatWorkspaceSplit"
        workspace.listDetailViewController.splitView.autosaveName = "MacDirStatListDetailSplit"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified

        super.init(window: window)
        window.toolbar = makeToolbar()
        workspace.onScanModelChange = { [weak self, weak statusBar, weak workspace] in
            guard let statusBar, let workspace else { return }
            statusBar.update(model: workspace.model)
            self?.announceIfScanFinished(workspace.model)
        }
        workspace.onChooseRequest = { [weak self] in self?.showChooser() }
        workspace.onRescanRequest = { [weak self] url in
            self?.beginScan(root: url, mode: .folder)
        }
        workspace.lastScannedSource = preferences.lastScan
        statusBar.update(model: workspace.model)
    }

    required init?(coder: NSCoder) { nil }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MacDirStatToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        return toolbar
    }

    // MARK: - Starting a scan

    /// The one place a scan starts, so "remember what was scanned" and
    /// "remember how it was scanned" cannot be forgotten at one of the callers.
    func beginScan(root url: URL, mode: ScanMode, packageScanMode: PackageScanMode? = nil) {
        let packageScanMode = packageScanMode ?? preferences.packageScanMode
        preferences.packageScanMode = packageScanMode
        preferences.rememberScan(url)
        workspaceViewController.lastScannedSource = preferences.lastScan
        workspaceViewController.start(root: url, mode: mode, packageScanMode: packageScanMode)
    }

    @objc func chooseScanSource(_ sender: Any?) { showChooser() }

    @objc func openRecentScan(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        beginScan(root: url, mode: .folder)
    }

    @objc func clearRecentScans(_ sender: Any?) {
        preferences.clearRecentScans()
        workspaceViewController.lastScannedSource = nil
    }

    @objc func showScanHelp(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "What MacDirStat measures"
        // The one thing the app is most often misread on, in the vocabulary
        // `CONTEXT.md` settles.
        alert.informativeText = """
            On-disk size is the blocks an entry occupies, and it is the measure: \
            it drives the treemap's area, the Size column and every total.

            Content length is how many bytes the content is. It is carried \
            beside on-disk size and drives nothing, so the detail pane can \
            explain the visible figure where the two diverge — a sparse disk \
            image, a compressed binary, a cloud placeholder.

            Fast mode measures each app bundle as one item without building its \
            internal file tree. The total is the same; the tree stops at the app.

            MacDirStat is read-only. Open and Reveal in Finder are the only \
            things it does to a file.
            """
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }

    @objc private func showChooser() {
        guard let content = window?.contentViewController else { return }
        let facts = SourceChooserModel.mountedVolumeFacts()
        let chooser = SourceChooserViewController(
            choices: SourceChooserModel.visibleChoices(from: facts),
            packageScanMode: preferences.packageScanMode
        )
        chooser.onCancel = { [weak content, weak chooser] in
            guard let chooser else { return }
            content?.dismiss(chooser)
        }
        chooser.onSelect = { [weak self, weak content, weak chooser] choice in
            let packageScanMode = chooser?.packageScanMode ?? .detailed
            if let chooser { content?.dismiss(chooser) }
            self?.beginScan(root: choice.url, mode: .volumeRoot, packageScanMode: packageScanMode)
        }
        chooser.onChooseFolder = { [weak self, weak content, weak chooser] in
            let packageScanMode = chooser?.packageScanMode ?? .detailed
            if let chooser { content?.dismiss(chooser) }
            DispatchQueue.main.async { self?.showFolderPanel(packageScanMode: packageScanMode) }
        }
        content.presentAsSheet(chooser)
    }

    private func showFolderPanel(packageScanMode: PackageScanMode? = nil) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Scan"
        let fastModeCheckbox = NSButton(
            checkboxWithTitle: "Fast mode — summarize app bundles",
            target: nil,
            action: nil
        )
        fastModeCheckbox.state = (packageScanMode ?? preferences.packageScanMode) == .summarized ? .on : .off
        fastModeCheckbox.toolTip =
            "Measure each app as one item without building its internal file tree."
        panel.accessoryView = fastModeCheckbox
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.beginScan(
                root: url,
                mode: .folder,
                packageScanMode: fastModeCheckbox.state == .on ? .summarized : .detailed
            )
        }
    }

    // MARK: - Finished-scan notification

    private var lastNotifiedPhase: ScanPhase = .empty

    /// Whether the app is frontmost, behind a seam: whether an `xctest` host
    /// happens to be activated is not something a test should depend on.
    var isApplicationActive: () -> Bool = { NSApp.isActive }

    /// A volume scan runs for minutes; the person who started it has usually
    /// gone somewhere else by the time it lands. Nothing is posted while the
    /// app is frontmost — the status line is right there.
    private func announceIfScanFinished(_ model: ScanPresentationModel) {
        defer { lastNotifiedPhase = model.phase }
        guard model.phase != lastNotifiedPhase, model.phase == .completed else { return }
        guard !isApplicationActive() else { return }
        let name = model.rootURL?.lastPathComponent ?? "the selected folder"
        let total = statusBarController.summaryText
        scanNotifier.notifyScanFinished(title: "Finished scanning \(name)", body: total)
    }
}

extension MainWindowController: NSMenuDelegate {
    /// Open Recent is filled the moment it opens, not at launch: a folder can
    /// be deleted or a volume unmounted while the app is running.
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainMenu.populateRecentsMenu(menu, with: preferences.recentScans)
    }
}

extension MainWindowController: NSToolbarDelegate {
    private static let chooseIdentifier = NSToolbarItem.Identifier("ChooseSource")
    static let openIdentifier = NSToolbarItem.Identifier("OpenSelection")
    static let revealIdentifier = NSToolbarItem.Identifier("RevealSelection")
    static let trackingSeparatorIdentifier = NSToolbarItem.Identifier("ListDetailSeparator")
    static let toggleDetailIdentifier = NSToolbarItem.Identifier("ToggleDetail")

    /// The toolbar's whole vocabulary: choose a source, the two read-only
    /// actions (§7.1), and the detail pane's toggle. No fourth verb.
    ///
    /// The tracking separator sits where the list/detail divider sits, so the
    /// toolbar reads as two regions over the two panes instead of one bar
    /// floating above a seam it ignores. Everything after it belongs to the
    /// detail pane.
    private static var itemIdentifiers: [NSToolbarItem.Identifier] {
        [
            chooseIdentifier,
            .flexibleSpace,
            trackingSeparatorIdentifier,
            openIdentifier,
            revealIdentifier,
            toggleDetailIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.chooseIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Choose…"
            item.paletteLabel = "Choose Source"
            item.toolTip = "Choose a folder or disk to scan"
            item.image = NSImage(named: NSImage.folderName)
            item.target = self
            item.action = #selector(showChooser)
            return item
        case Self.openIdentifier:
            return actionItem(
                identifier: itemIdentifier,
                label: FileActionMenu.openTitle,
                toolTip: "Open the selected item (⌘O)",
                imageName: NSImage.quickLookTemplateName,
                action: #selector(FileActionResponding.openSelectedItem(_:))
            )
        case Self.trackingSeparatorIdentifier:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: workspaceViewController.listDetailViewController.splitView,
                dividerIndex: 0
            )
        case Self.toggleDetailIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Details"
            item.paletteLabel = "Show or Hide Details"
            item.toolTip = "Show or hide the detail pane (⌥⌘I)"
            item.image = NSImage(
                systemSymbolName: "sidebar.trailing",
                accessibilityDescription: "Show or hide the detail pane"
            )
            item.target = nil
            item.action = #selector(DetailPaneToggling.toggleDetailPane(_:))
            return item
        case Self.revealIdentifier:
            return actionItem(
                identifier: itemIdentifier,
                label: FileActionMenu.revealTitle,
                toolTip: "Reveal the selected item in Finder (⌘R)",
                imageName: NSImage.revealFreestandingTemplateName,
                action: #selector(FileActionResponding.revealSelectedItem(_:))
            )
        default:
            return nil
        }
    }

    private func actionItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        toolTip: String,
        imageName: NSImage.Name,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(named: imageName)
        // Target nil sends it down the responder chain to the workspace, which
        // is also what validates it against the current selection.
        item.target = nil
        item.action = action
        return item
    }
}
