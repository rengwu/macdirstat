import AppKit

/// The main menu, built in code because the lifecycle is programmatic (spec §4.1).
///
/// A programmatic menu bar is not just the app's own commands: the standard
/// menus are where macOS puts ⌘W, ⌘M, ⌘C and ⌘A, and an app that omits them
/// does not merely lack the menus — those keystrokes stop working everywhere,
/// including in the text fields of an `NSOpenPanel`. So Edit, View, Window and
/// Help are here for the key equivalents as much as for the items.
enum MainMenu {
    static let scanFolderTitle = "Open Folder…"
    static let openRecentTitle = "Open Recent"
    static let clearRecentTitle = "Clear Menu"
    static let copyPathTitle = "Copy Path"
    static let showDetailsTitle = "Show Details"
    static let hideDetailsTitle = "Hide Details"
    static let helpTitle = "MacDirStat Help"

    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(applicationMenu()))
        mainMenu.addItem(submenu(fileMenu()))
        mainMenu.addItem(submenu(editMenu()))
        mainMenu.addItem(submenu(viewMenu()))
        mainMenu.addItem(submenu(windowMenu()))
        mainMenu.addItem(submenu(helpMenu()))
        return mainMenu
    }

    // MARK: - Finding the menus AppKit has to be handed

    /// The submenu with `title`, for the hand-offs `AppDelegate` makes.
    static func menu(titled title: String, in mainMenu: NSMenu) -> NSMenu? {
        mainMenu.items.first { $0.title == title }?.submenu
    }

    static func servicesMenu(in mainMenu: NSMenu) -> NSMenu? {
        mainMenu.items.first?.submenu?.items.first { $0.title == "Services" }?.submenu
    }

    static func recentsMenu(in mainMenu: NSMenu) -> NSMenu? {
        menu(titled: "File", in: mainMenu)?.items.first { $0.title == openRecentTitle }?.submenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    // MARK: - Application

    private static func applicationMenu() -> NSMenu {
        let applicationName = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: applicationName)
        menu.addItem(
            withTitle: "About \(applicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        // Located by title in `AppDelegate`, which is how `NSApp.servicesMenu`
        // gets something to populate.
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Hide \(applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    // MARK: - File

    /// The File menu carries the scan source, the recents, and the two
    /// read-only actions and nothing else (§7.1): no Delete, no Move, no Clean —
    /// there is no mutation affordance anywhere in this app, and a menu is the
    /// easiest place to acquire one by accident.
    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")

        // The app's primary verb. It used to exist only as a toolbar button,
        // which left the one thing the app is for reachable by mouse alone.
        let scan = NSMenuItem(
            title: scanFolderTitle,
            action: #selector(ScanSourceChoosing.chooseScanSource(_:)),
            keyEquivalent: "o"
        )
        scan.keyEquivalentModifierMask = .command
        menu.addItem(scan)

        let recent = NSMenuItem(title: openRecentTitle, action: nil, keyEquivalent: "")
        recent.submenu = makeRecentsMenu()
        menu.addItem(recent)
        menu.addItem(.separator())

        // Opening a selected file remains available without taking the source
        // chooser’s keyboard shortcut.
        menu.addItem(
            NSMenuItem(
                title: FileActionMenu.openTitle,
                action: #selector(FileActionResponding.openSelectedItem(_:)),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: FileActionMenu.revealTitle,
                action: #selector(FileActionResponding.revealSelectedItem(_:)),
                keyEquivalent: "r"
            )
        )
        return menu
    }

    /// The Open Recent submenu, empty until its delegate fills it.
    ///
    /// It is rebuilt on open rather than at launch because a recent folder can
    /// be deleted or unmounted while the app is running, and an entry that
    /// scans nothing is worse than no entry.
    static func makeRecentsMenu() -> NSMenu {
        let menu = NSMenu(title: openRecentTitle)
        menu.autoenablesItems = false
        return menu
    }

    /// Fills `menu` with `urls`, most recent first, then Clear Menu.
    static func populateRecentsMenu(_ menu: NSMenu, with urls: [URL]) {
        menu.removeAllItems()
        for url in urls {
            let item = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(ScanSourceChoosing.openRecentScan(_:)),
                keyEquivalent: ""
            )
            item.representedObject = url
            item.toolTip = url.path
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.isEnabled = true
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(
            title: clearRecentTitle,
            action: #selector(ScanSourceChoosing.clearRecentScans(_:)),
            keyEquivalent: ""
        )
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    // MARK: - Edit

    /// Text editing, not file editing.
    ///
    /// Every item here acts on the pasteboard or on a text field's contents.
    /// The app owns no editable document, but `NSOpenPanel`'s fields and the
    /// inspector's selectable text both need these key equivalents, and
    /// without an Edit menu they simply do not fire.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(
            withTitle: "Undo",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        )
        let redo = NSMenuItem(
            title: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(.separator())

        // Finder's own shortcut for the same idea. The inspector shows the
        // full path and, until this existed, there was no way to get it out of
        // the app.
        let copyPath = NSMenuItem(
            title: copyPathTitle,
            action: #selector(PathCopying.copySelectedPath(_:)),
            keyEquivalent: "c"
        )
        copyPath.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(copyPath)
        return menu
    }

    // MARK: - View

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // The detail pane collapses; this is the keyboard counterpart to the
        // titlebar command that brings it back.
        let details = NSMenuItem(
            title: hideDetailsTitle,
            action: #selector(DetailPaneToggling.toggleDetailPane(_:)),
            keyEquivalent: "d"
        )
        details.keyEquivalentModifierMask = .command
        menu.addItem(details)
        menu.addItem(.separator())
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        return menu
    }

    // MARK: - Window

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    // MARK: - Help

    /// One item, and it explains the thing this app is most often misread on.
    ///
    /// There is no help book to open, and wiring `showHelp:` without one gets
    /// the user a system alert saying help is unavailable — worse than no menu.
    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(
            withTitle: helpTitle,
            action: #selector(ScanHelpPresenting.showScanHelp(_:)),
            keyEquivalent: "?"
        )
        return menu
    }
}
