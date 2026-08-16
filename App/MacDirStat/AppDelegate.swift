import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let controller = MainWindowController()
        controller.showWindow(self)
        mainWindowController = controller

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A scan is a transient session, not a document: closing the one window
        // ends the app (spec §2 — not document-based, nothing persisted).
        true
    }
}
