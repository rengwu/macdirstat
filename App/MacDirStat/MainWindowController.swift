import AppKit
import ScanCore

final class MainWindowController: NSWindowController, ScanSourceChoosing, ScanHelpPresenting {
    let workspaceViewController: WorkspaceSplitViewController
    let statusBarController: StatusBarViewController
    let preferences: Preferences
    let scanNotifier: ScanCompletionNotifying
    private(set) var commandStripController: TitlebarCommandStripViewController?

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
        // A crisp boundary keeps the compact command strip separate from the
        // dense table immediately below it.
        window.titlebarSeparatorStyle = .line

        super.init(window: window)
        let commandStrip = TitlebarCommandStripViewController(chooseTarget: self)
        // Tahoe's titlebar floats over the adjacent scroll view. The automatic
        // edge treatment leaves dense outline rows recognizable through the
        // glass, so ask AppKit for its more opaque frosted cutoff. This keeps
        // the native Liquid Glass controls while protecting their legibility.
        if #available(macOS 26.1, *) {
            commandStrip.preferredScrollEdgeEffectStyle = .hard
        }
        commandStripController = commandStrip
        window.addTitlebarAccessoryViewController(commandStrip)
        workspace.selectionModel.addObserver { [weak commandStrip] change in
            commandStrip?.setFileActionsEnabled(change.selection?.node != nil)
        }
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
        chooser.onSearch = { [weak self, weak content, weak chooser] url, mode in
            let packageScanMode = chooser?.packageScanMode ?? .detailed
            if let chooser { content?.dismiss(chooser) }
            self?.beginScan(root: url, mode: mode, packageScanMode: packageScanMode)
        }
        chooser.onChooseFolder = { [weak self, weak chooser] in
            guard let chooser else { return }
            self?.showFolderPanel(for: chooser)
        }
        content.presentAsSheet(chooser)
    }

    private func showFolderPanel(for chooser: SourceChooserViewController) {
        guard let window = chooser.view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to add to your search sources."
        panel.beginSheetModal(for: window) { [weak chooser] response in
            guard response == .OK, let url = panel.url else { return }
            chooser?.selectFolder(url)
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

/// Three quiet, consistently padded titlebar buttons. Using a titlebar
/// accessory instead of `NSToolbar` is intentional on current macOS: the
/// latter mirrors an adjacent scroll view into its glass, which made directory
/// rows remain plainly visible behind the window controls as the list moved.
@MainActor
final class TitlebarCommandStripViewController: NSTitlebarAccessoryViewController {
    static let symbolPointSize: CGFloat = 12
    static let buttonSize = NSSize(width: 32, height: 26)
    static let stripSize = NSSize(width: 122, height: 28)

    let chooseButton: NSButton
    let revealButton: NSButton
    let detailsButton: NSButton

    var buttons: [NSButton] { [chooseButton, revealButton, detailsButton] }

    init(chooseTarget: AnyObject) {
        chooseButton = Self.makeButton(
            symbol: "folder",
            label: MainMenu.scanFolderTitle,
            toolTip: "Open Folder… (⌘O)",
            target: chooseTarget,
            action: #selector(MainWindowController.chooseScanSource(_:))
        )
        revealButton = Self.makeButton(
            symbol: "magnifyingglass",
            label: FileActionMenu.revealTitle,
            toolTip: "Reveal in Finder",
            target: nil,
            action: #selector(FileActionResponding.revealSelectedItem(_:))
        )
        detailsButton = Self.makeButton(
            symbol: "sidebar.trailing",
            label: "Details",
            toolTip: "Show or hide the detail pane (⌘D)",
            target: nil,
            action: #selector(DetailPaneToggling.toggleDetailPane(_:))
        )
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        setFileActionsEnabled(false)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 14),
        ])

        let stack = NSStackView(views: [chooseButton, divider, revealButton, detailsButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 8)
        // Titlebar accessories begin life under an autoresizing-mask width
        // constraint, so give AppKit the strip's intrinsic opening size before
        // it installs the view in the titlebar hierarchy.
        stack.frame = NSRect(origin: .zero, size: Self.stripSize)
        view = stack
    }

    func setFileActionsEnabled(_ enabled: Bool) {
        revealButton.isEnabled = enabled
    }

    private static func makeButton(
        symbol: String,
        label: String,
        toolTip: String,
        target: AnyObject?,
        action: Selector
    ) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.title = ""
        button.bezelStyle = .toolbar
        button.controlSize = .small
        // A permanent bezel makes three small commands look like a row of
        // cramped form buttons. Keep the native toolbar hover and pressed
        // treatment, but let the symbols sit quietly in the titlebar at rest.
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = .labelColor
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = toolTip
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: buttonSize.width),
            button.heightAnchor.constraint(equalToConstant: buttonSize.height),
        ])
        return button
    }
}
