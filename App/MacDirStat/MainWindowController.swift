import AppKit

/// The single main window.
///
/// Scaffold (ticket 02): an empty content view. Ticket 07 replaces the content
/// view controller with the three-pane `NSSplitViewController` (tree, treemap,
/// inspector) and the unified toolbar.
final class MainWindowController: NSWindowController {
    convenience init() {
        // The content view controller drives the window's size, so the view
        // carries the intended frame: assigning an unsized view collapses the
        // window to `minSize` instead.
        let contentViewController = NSViewController()
        contentViewController.view = NSView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 700))

        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "MacDirStat"
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.setFrameAutosaveName("MacDirStatMainWindow")

        self.init(window: window)
    }
}
