import AppKit

/// The two read-only file actions, behind a seam so a test can prove which URL
/// was passed and that nothing else was ever called (spec §10, §9.3).
///
/// Read-only is **structural** here in exactly the way it is for
/// `ScanCore.DirectoryProbe`: the protocol has two methods and there is no
/// third one to call. Adding a mutating method would be a visible change to
/// this declaration, not a slip inside a view controller.
@MainActor
protocol WorkspaceActing: AnyObject {
    /// `NSWorkspace.open(_:)` — hands the URL to the system's default handler.
    func open(_ url: URL)
    /// `NSWorkspace.activateFileViewerSelecting(_:)` — selects it in Finder.
    func reveal(_ url: URL)
}

@MainActor
final class SystemWorkspaceActions: WorkspaceActing {
    func open(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// VoiceOver announcements, injectable for the same reason: §9.4 requires an
/// announcement when the shared selection changes, and a spy is the only way to
/// assert one was posted without driving VoiceOver itself.
@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ message: String)
}

@MainActor
final class SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    func announce(_ message: String) {
        guard let target = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

/// Putting the selected item's path on the pasteboard.
///
/// Deliberately *not* a third case in ``FileActionResponding``: that protocol's
/// guarantee is that the two file actions are all there are, and this does not
/// touch a file at all. It reads a path the app already displays and writes it
/// to the pasteboard — the same thing ⌘C does in any text field.
@MainActor
@objc
protocol PathCopying: AnyObject {
    @objc func copySelectedPath(_ sender: Any?)
}

/// Choosing what to scan, from the menu bar rather than the toolbar button.
@MainActor
@objc
protocol ScanSourceChoosing: AnyObject {
    @objc func chooseScanSource(_ sender: Any?)
    /// `sender.representedObject` carries the `URL` to scan.
    @objc func openRecentScan(_ sender: Any?)
    @objc func clearRecentScans(_ sender: Any?)
}

/// The one Help item. Named as its own contract for the same reason the
/// others are: what a menu can send is declared, not discovered.
@MainActor
@objc
protocol ScanHelpPresenting: AnyObject {
    @objc func showScanHelp(_ sender: Any?)
}

/// Showing and hiding the detail pane, which can be collapsed and — until this
/// existed — could not be brought back.
@MainActor
@objc
protocol DetailPaneToggling: AnyObject {
    @objc func toggleDetailPane(_ sender: Any?)
}
