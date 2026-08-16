import AppKit

/// The main menu, built in code because the lifecycle is programmatic (spec §4.1).
///
enum MainMenu {
    static func make() -> NSMenu {
        let applicationName = ProcessInfo.processInfo.processName

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About \(applicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        // The File menu carries the two read-only actions and nothing else
        // (§7.1): no Delete, no Move, no Clean — there is no mutation
        // affordance anywhere in this app, and a menu is the easiest place to
        // acquire one by accident.
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(
            title: FileActionMenu.openTitle,
            action: #selector(FileActionResponding.openSelectedItem(_:)),
            keyEquivalent: "o"
        )
        let reveal = NSMenuItem(
            title: FileActionMenu.revealTitle,
            action: #selector(FileActionResponding.revealSelectedItem(_:)),
            keyEquivalent: "r"
        )
        fileMenu.addItem(open)
        fileMenu.addItem(reveal)

        let fileMenuItem = NSMenuItem()
        fileMenuItem.title = "File"
        fileMenuItem.submenu = fileMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)
        return mainMenu
    }
}
