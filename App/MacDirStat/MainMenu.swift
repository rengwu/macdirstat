import AppKit

/// The main menu, built in code because the lifecycle is programmatic (spec §4.1).
///
/// Scaffold (ticket 02): only the application menu, so a launched app can be
/// quit and hidden. Scan commands, view commands and the Open/Reveal items —
/// the only file actions this app will ever have (spec §2) — land with tickets
/// 07–09.
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
