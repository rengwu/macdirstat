import AppKit

final class MainWindowController: NSWindowController {
    let workspaceViewController: WorkspaceSplitViewController
    let statusBarController: StatusBarViewController

    convenience init() {
        let formatter = DisplayFormatter()
        let workspace = WorkspaceSplitViewController(formatter: formatter)
        let status = StatusBarViewController(formatter: formatter)
        self.init(workspace: workspace, statusBar: status)
    }

    init(workspace: WorkspaceSplitViewController, statusBar: StatusBarViewController) {
        workspaceViewController = workspace
        statusBarController = statusBar
        let contentViewController = WorkspaceContainerViewController(workspace: workspace, statusBar: statusBar)

        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "MacDirStat"
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.setFrameAutosaveName("MacDirStatMainWindow")
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified

        super.init(window: window)
        window.toolbar = makeToolbar()
        workspace.onScanModelChange = { [weak statusBar, weak workspace] in
            guard let statusBar, let workspace else { return }
            statusBar.update(model: workspace.model)
        }
        workspace.onChooseRequest = { [weak self] in self?.showChooser() }
        statusBar.update(model: workspace.model)
    }

    required init?(coder: NSCoder) { nil }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MacDirStatToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        return toolbar
    }

    @objc private func showChooser() {
        guard let content = window?.contentViewController else { return }
        let facts = SourceChooserModel.mountedVolumeFacts()
        let chooser = SourceChooserViewController(choices: SourceChooserModel.visibleChoices(from: facts))
        chooser.onCancel = { [weak content, weak chooser] in
            guard let chooser else { return }
            content?.dismiss(chooser)
        }
        chooser.onSelect = { [weak self, weak content, weak chooser] choice in
            if let chooser { content?.dismiss(chooser) }
            self?.workspaceViewController.start(root: choice.url, mode: .volumeRoot)
        }
        chooser.onChooseFolder = { [weak self, weak content, weak chooser] in
            if let chooser { content?.dismiss(chooser) }
            DispatchQueue.main.async { self?.showFolderPanel() }
        }
        content.presentAsSheet(chooser)
    }

    private func showFolderPanel() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Scan"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.workspaceViewController.start(root: url, mode: .folder)
        }
    }
}

extension MainWindowController: NSToolbarDelegate {
    private static let chooseIdentifier = NSToolbarItem.Identifier("ChooseSource")
    static let openIdentifier = NSToolbarItem.Identifier("OpenSelection")
    static let revealIdentifier = NSToolbarItem.Identifier("RevealSelection")

    /// The toolbar's whole vocabulary: choose a source, and the two read-only
    /// actions (§7.1). There is nothing else to add here.
    private static var itemIdentifiers: [NSToolbarItem.Identifier] {
        [chooseIdentifier, .flexibleSpace, openIdentifier, revealIdentifier]
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
