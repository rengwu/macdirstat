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

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        return mainMenu
    }
}
