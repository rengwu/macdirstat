import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        // These three are hand-offs, not decorations: AppKit fills the Services
        // submenu itself, and keeps the Window menu's list of open windows,
        // only once it has been told which menus they are.
        NSApp.servicesMenu = MainMenu.servicesMenu(in: menu)
        NSApp.windowsMenu = MainMenu.menu(titled: "Window", in: menu)
        NSApp.helpMenu = MainMenu.menu(titled: "Help", in: menu)

        let controller = MainWindowController()
        controller.showWindow(self)
        mainWindowController = controller

        // Open Recent is rebuilt each time it opens, from the folders that are
        // still there to scan.
        MainMenu.recentsMenu(in: menu)?.delegate = controller

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A scan is a transient session, not a document: closing the one window
        // ends the app (spec §2 — the *result* is never persisted; what the
        // window remembers is its own shape, see `Preferences`).
        true
    }
}
